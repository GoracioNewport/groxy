#!/usr/bin/env bash
# Bridge DNS — dnsmasq install/config + whitelist file rendering.
# Sourced by the dispatcher; do not execute directly.
#
# dnsmasq binds to wg0 (bind-dynamic — works even if wg0 not yet up),
# upstreams to Cloudflare/Google, and translates the user-editable
# whitelist files into ipset= directives that fill the vpn_domains ipset
# at resolve time.

readonly BRIDGE_DNSMASQ_CUSTOM_CONF='/etc/dnsmasq.d/50-custom.conf'
readonly BRIDGE_DNSMASQ_OPENCCK_CONF='/etc/dnsmasq.d/00-opencck.conf'

# Render /etc/dnsmasq.conf — single source-of-truth for the dnsmasq
# instance groxy runs.
bridge_render_dnsmasq_conf() {
    write_atomic /etc/dnsmasq.conf 644 <<'EOF'
# Managed by groxy. Do not edit by hand.
interface=wg0
bind-dynamic
no-resolv
server=1.1.1.1
server=8.8.8.8
cache-size=10000
conf-dir=/etc/dnsmasq.d/,*.conf
EOF
}

# Ensure the whitelist directory exists. Seeds custom.txt with the default
# entry '*.ru' on first init — won't touch user edits afterwards.
bridge_ensure_whitelist_dir() {
    local dir="${GROXY_DIR}/bridge/whitelist"
    mkdir -p "${dir}"
    chmod 700 "${dir}"
    if [[ ! -f "${dir}/custom.txt" ]]; then
        cat > "${dir}/custom.txt" <<'EOF'
# groxy — custom domain whitelist (route direct, not through portal).
# One entry per line. Both 'foo.tld' and '*.foo.tld' match the domain
# plus all its subdomains (that's how dnsmasq's ipset= directive works).
# Lines starting with '#' and blank lines are ignored.
*.ru
EOF
        chmod 600 "${dir}/custom.txt"
        log "seeded ${dir}/custom.txt with default '*.ru'"
    fi
    [[ -f "${dir}/source-url" ]] || : > "${dir}/source-url"
    [[ -f "${dir}/opencck.txt" ]] || : > "${dir}/opencck.txt"
    chmod 600 "${dir}/source-url" "${dir}/opencck.txt"
}

# Read a domain-list file (one entry per line, '*.' prefix optional, '#'
# comments + blank lines skipped, trailing whitespace stripped) and emit
# 'ipset=/<domain>/vpn_domains' lines to stdout.
_bridge_dns_emit_ipset_directives() {
    local src="$1"
    local line domain
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]]      && continue
        [[ "${line}" == \#* ]]  && continue
        domain="${line#\*.}"
        printf 'ipset=/%s/vpn_domains\n' "${domain}"
    done < "${src}"
}

# Render 50-custom.conf from custom.txt.
bridge_render_custom_conf() {
    local src="${GROXY_DIR}/bridge/whitelist/custom.txt"
    [[ -f "${src}" ]] || die "custom whitelist file missing: ${src}"
    {
        printf '# Managed by groxy — generated from %s\n' "${src}"
        _bridge_dns_emit_ipset_directives "${src}"
    } | write_atomic "${BRIDGE_DNSMASQ_CUSTOM_CONF}" 644
}

# Render 00-opencck.conf from opencck.txt (fetched feed). Prefix 00- so it
# loads before 50-custom.conf — both ipsets fill the same vpn_domains, so
# load order doesn't really matter, but a stable ordering helps debugging.
bridge_render_opencck_conf() {
    local src="${GROXY_DIR}/bridge/whitelist/opencck.txt"
    [[ -f "${src}" ]] || die "opencck whitelist file missing: ${src}"
    {
        printf '# Managed by groxy — generated from %s\n' "${src}"
        _bridge_dns_emit_ipset_directives "${src}"
    } | write_atomic "${BRIDGE_DNSMASQ_OPENCCK_CONF}" 644
}

# Install/enable the daily timer for `groxy bridge whitelist update`.
bridge_install_whitelist_timer() {
    local groxy_bin="${SCRIPT_DIR}/groxy"
    cat > /etc/systemd/system/groxy-whitelist-update.service <<EOF
[Unit]
Description=groxy — refresh opencck-style domain whitelist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${groxy_bin} bridge whitelist update
EOF

    cat > /etc/systemd/system/groxy-whitelist-update.timer <<'EOF'
[Unit]
Description=Daily refresh of groxy whitelist

[Timer]
OnCalendar=daily
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable groxy-whitelist-update.timer >/dev/null 2>&1
    systemctl start groxy-whitelist-update.timer
}

# Top-level: install dnsmasq, write its config, scaffold the whitelist
# directory and default custom.txt, render configs, enable + (re)start
# the service, install daily refresh timer. Idempotent.
bridge_init_dns() {
    apt_install dnsmasq
    bridge_ensure_whitelist_dir
    bridge_render_dnsmasq_conf
    bridge_render_custom_conf
    bridge_render_opencck_conf

    systemctl enable dnsmasq >/dev/null 2>&1
    if systemctl is-active --quiet dnsmasq; then
        systemctl restart dnsmasq
    else
        systemctl start dnsmasq
    fi

    bridge_install_whitelist_timer
}

# `groxy bridge whitelist reload` — re-render 50-custom.conf and
# 00-opencck.conf from their sources, restart dnsmasq.
bridge_whitelist_reload() {
    require_root
    local dir="${GROXY_DIR}/bridge/whitelist"
    [[ -d "${dir}" ]] || die "whitelist not initialised — run 'groxy init bridge' first"
    log "rendering ${BRIDGE_DNSMASQ_CUSTOM_CONF} from custom.txt"
    bridge_render_custom_conf
    log "rendering ${BRIDGE_DNSMASQ_OPENCCK_CONF} from opencck.txt"
    bridge_render_opencck_conf
    # systemctl reload (SIGHUP) НЕ всегда сбрасывает DNS-кэш в dnsmasq 2.91:
    # ранее закэшированный домен (например запрошенный до добавления в whitelist)
    # продолжит резолвиться без триггера ipset= директивы. Restart гарантирует
    # чистую таблицу.
    log "restarting dnsmasq (flushes cache)"
    systemctl restart dnsmasq
}

# `groxy bridge whitelist set-source <url>` — persist the opencck-style
# source URL. Doesn't fetch — call `whitelist update` to refresh.
bridge_whitelist_set_source() {
    require_root
    local arg url=''
    for arg in "$@"; do
        case "${arg}" in
            http://*|https://*)
                [[ -z "${url}" ]] || die "set-source: extra argument '${arg}'"
                url="${arg}"
                ;;
            *) die "set-source: expected an http(s) URL, got '${arg}'" ;;
        esac
    done
    [[ -n "${url}" ]] || die "usage: groxy bridge whitelist set-source <http(s)-url>"

    local dst="${GROXY_DIR}/bridge/whitelist/source-url"
    mkdir -p "$(dirname "${dst}")"
    printf '%s\n' "${url}" | write_atomic "${dst}" 600
    log "set opencck source URL: ${url}"
}

# `groxy bridge whitelist update` — fetch from the configured URL, replace
# opencck.txt atomically, re-render 00-opencck.conf, restart dnsmasq.
# Treats fetch failures as soft: keeps previous list intact, logs warning.
bridge_whitelist_update() {
    require_root
    local dir="${GROXY_DIR}/bridge/whitelist"
    [[ -d "${dir}" ]] || die "whitelist not initialised — run 'groxy init bridge' first"

    local url=''
    [[ -f "${dir}/source-url" ]] && url=$(<"${dir}/source-url")
    url="${url//[$'\n\r']/}"
    if [[ -z "${url}" ]]; then
        log "no opencck source URL set (use 'bridge whitelist set-source <url>'); skipping"
        return 0
    fi

    log "fetching opencck list from ${url}"
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL --max-time 30 "${url}" -o "${tmp}"; then
        rm -f "${tmp}"
        log "warning: fetch failed, keeping previous list (${dir}/opencck.txt)"
        return 0
    fi
    if [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}"
        log "warning: fetched list is empty, keeping previous"
        return 0
    fi

    local lines
    lines=$(wc -l < "${tmp}")
    log "fetched ${lines} lines"

    chmod 600 "${tmp}"
    mv -f "${tmp}" "${dir}/opencck.txt"

    log "rendering ${BRIDGE_DNSMASQ_OPENCCK_CONF}"
    bridge_render_opencck_conf

    log "restarting dnsmasq"
    systemctl restart dnsmasq
}
