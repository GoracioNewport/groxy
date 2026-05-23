#!/usr/bin/env bash
# Bridge DNS — dnsmasq install/config + whitelist file rendering.
# Sourced by the dispatcher; do not execute directly.
#
# dnsmasq binds to wg0 (bind-dynamic — works even if wg0 not yet up),
# upstreams to Cloudflare/Google, and translates the user-editable
# whitelist files into ipset= directives that fill the vpn_domains ipset
# at resolve time.

readonly BRIDGE_DNSMASQ_CUSTOM_CONF='/etc/dnsmasq.d/50-custom.conf'

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
}

# Render /etc/dnsmasq.d/50-custom.conf from custom.txt. Treats '*.foo' as
# equivalent to 'foo' — dnsmasq's ipset= matches the bare domain plus all
# subdomains either way.
bridge_render_custom_conf() {
    local src="${GROXY_DIR}/bridge/whitelist/custom.txt"
    [[ -f "${src}" ]] || die "custom whitelist file missing: ${src}"
    {
        printf '# Managed by groxy — generated from %s\n' "${src}"
        local line domain
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" ]]      && continue
            [[ "${line}" == \#* ]]  && continue
            domain="${line#\*.}"
            printf 'ipset=/%s/vpn_domains\n' "${domain}"
        done < "${src}"
    } | write_atomic "${BRIDGE_DNSMASQ_CUSTOM_CONF}" 644
}

# Top-level: install dnsmasq, write its config, scaffold the whitelist
# directory and default custom.txt, render 50-custom.conf, enable +
# (re)start the service. Idempotent.
bridge_init_dns() {
    apt_install dnsmasq
    bridge_ensure_whitelist_dir
    bridge_render_dnsmasq_conf
    bridge_render_custom_conf

    systemctl enable dnsmasq >/dev/null 2>&1
    if systemctl is-active --quiet dnsmasq; then
        systemctl restart dnsmasq
    else
        systemctl start dnsmasq
    fi
}

# `groxy bridge whitelist reload` — re-render 50-custom.conf from
# custom.txt and reload dnsmasq.
bridge_whitelist_reload() {
    require_root
    local dir="${GROXY_DIR}/bridge/whitelist"
    [[ -d "${dir}" ]] || die "whitelist not initialised — run 'groxy init bridge' first"
    log "rendering ${BRIDGE_DNSMASQ_CUSTOM_CONF} from custom.txt"
    bridge_render_custom_conf
    log "reloading dnsmasq"
    systemctl reload dnsmasq
}
