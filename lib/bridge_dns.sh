#!/usr/bin/env bash
# Bridge DNS — dnsmasq install/config + whitelist file rendering.
# Sourced by the dispatcher; do not execute directly.
#
# dnsmasq binds to wg0 via `interface=wg0 + bind-dynamic`, upstreams to
# Cloudflare/Google, and translates the user-editable whitelist files
# into ipset= directives that fill the vpn_domains ipset at resolve
# time. bind-dynamic *should* attach to wg0 lazily, but on Debian /
# dnsmasq 2.91 we observed it silently failing to attach when dnsmasq
# starts before wg0 has its address — _bridge_dnsmasq_restart_verify
# guards against that.

readonly BRIDGE_DNSMASQ_CUSTOM_CONF='/etc/dnsmasq.d/50-custom.conf'
readonly BRIDGE_DNSMASQ_OPENCCK_CONF='/etc/dnsmasq.d/00-opencck.conf'
readonly BRIDGE_DEFAULT_OPENCCK_URL='https://russia.iplist.opencck.org/?format=text&data=domains'

# Read wg0 server IP from /etc/groxy/bridge/wg0/server.env. Echoes the IP
# on stdout or returns non-zero if server.env is missing.
_bridge_dns_wg0_ip() {
    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    [[ -f "${cfg_dir}/server.env" ]] || return 1
    local SUBNET=''
    # shellcheck source=/dev/null
    source "${cfg_dir}/server.env"
    [[ -n "${SUBNET}" ]] || return 1
    _bridge_wg0_server_ip "${SUBNET}"
}

# Wait until wg0 carries the server.env IP. 5s timeout. Used before
# starting dnsmasq at init — apt's dnsmasq postinst may otherwise start
# the daemon before wg0 has its address.
_bridge_wait_for_wg0_address() {
    local want_ip
    want_ip=$(_bridge_dns_wg0_ip) || die "wg0 server.env missing — bridge_init_wg0 didn't run?"
    local i
    for ((i = 0; i < 50; i++)); do
        ip -4 -o addr show dev wg0 2>/dev/null | grep -qw "${want_ip}" && return 0
        sleep 0.1
    done
    die "wg0 didn't get address ${want_ip} within 5s — check wg-quick@wg0"
}

# True iff dnsmasq is listening on <ip>:53.
_bridge_dnsmasq_bound_to() {
    local ip="$1"
    ss -uln 2>/dev/null | grep -qE "[[:space:]]${ip//./\\.}:53[[:space:]]"
}

# Restart dnsmasq and verify it actually binds to wg0's server IP. On
# Debian / dnsmasq 2.91 we've seen `bind-dynamic` race during bridge
# init: apt's postinst starts dnsmasq before wg0 has its address, the
# subsequent `systemctl restart` then sometimes leaves the daemon bound
# only to loopback (interface=wg0 silently ignored) even though the
# config is correct. We work around it by polling ss for the wg0:53 bind
# and retrying once. Callers in init paths should call
# `_bridge_wait_for_wg0_address` first so the interface is definitely up.
_bridge_dnsmasq_restart_verify() {
    # Предохранитель перед каждым перезапуском. Фид скачивается ежедневно и не
    # аутентифицирован, а теперь он управляет ещё и выбором резолвера — битый
    # конфиг положил бы DNS целиком, включая российские сайты, у всех клиентов.
    # Проверка стоит копейки и ловит это до того, как демон уйдёт в down.
    if ! dnsmasq --test -C "${GROXY_DNSMASQ_CONF}" >/dev/null 2>&1; then
        dnsmasq --test -C "${GROXY_DNSMASQ_CONF}" 2>&1 | tail -5 >&2
        die "${GROXY_DNSMASQ_CONF} не проходит проверку синтаксиса — перезапуск отменён"
    fi

    local want_ip
    want_ip=$(_bridge_dns_wg0_ip) || {
        # Bridge isn't initialised — fall back to a plain restart.
        systemctl restart dnsmasq
        return
    }

    systemctl restart dnsmasq

    local i
    for ((i = 0; i < 30; i++)); do
        _bridge_dnsmasq_bound_to "${want_ip}" && return 0
        sleep 0.1
    done

    log "warning: dnsmasq не подцепил ${want_ip}:53 за 3s — повторяю restart"
    systemctl restart dnsmasq
    for ((i = 0; i < 30; i++)); do
        _bridge_dnsmasq_bound_to "${want_ip}" && return 0
        sleep 0.1
    done
    die "dnsmasq так и не слушает ${want_ip}:53 — конфликт на :53 (systemd-resolved?) или wg0 не поднят"
}

# Render /etc/dnsmasq.conf — single source-of-truth for the dnsmasq
# instance groxy runs.
# Российские зоны верхнего уровня. Их домены обязаны резолвиться локально
# всегда, даже когда фида ещё нет.
readonly BRIDGE_DNS_RU_ZONES='ru su xn--p1ai moscow tatar'

# Резолверы. Cloudflare уводится в туннель host-маршрутами (см. PostUp wg1),
# Google остаётся на прямом пути — отсюда и разделение географии.
readonly BRIDGE_DNS_FOREIGN='1.1.1.1 1.0.0.1'
readonly BRIDGE_DNS_LOCAL='8.8.8.8 8.8.4.4'

# Извлечь домен из строки списка. Пустая строка означает «здесь домена нет»:
# комментарий, пустая строка или мусор.
#
# Правила намеренно повторяют _bridge_dns_emit_ipset_directives: множество
# доменов, попадающих в server=, обязано совпадать с множеством, попадающим в
# ipset=, иначе часть carve-out'а поедет резолвиться не с той стороны.
_bridge_dns_domain_from_line() {
    local line="$1" domain
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]]     && return 0
    [[ "${line}" == \#* ]] && return 0
    if [[ "${line}" == ipset=* ]]; then
        domain="${line#ipset=/}"
        domain="${domain%%/*}"
    else
        domain="${line#\*.}"
    fi
    # В фиде встречаются строки вида «домен:443» — порт отсекаем.
    domain="${domain%%:*}"
    [[ -z "${domain}" ]] && return 0
    [[ "${domain}" == *[[:space:]]* ]] && return 0
    printf '%s\n' "${domain}"
}

# Свернуть не-российские домены whitelist'а до регистрируемых суффиксов.
#
# Зачем сворачивать: в фиде около 3200 доменов вне российских зон, и выписывать
# server= на каждый значило бы утроить конфиг. Суффиксов из них получается
# около 120, и покрытие при этом полное — проверено на живом фиде.
_bridge_dns_ru_suffixes() {
    local src line domain
    local ru_re='\.('"${BRIDGE_DNS_RU_ZONES// /|}"')$'
    # Публичные суффиксы второго уровня: под ними регистрируют на третьем, и
    # свёртка до двух меток захватила бы чужую зону целиком.
    local multi='com\.ua|co\.uk|com\.tr|co\.il|com\.br|com\.au|com\.cn|co\.jp|com\.tw|com\.hk|com\.sg|co\.kr|com\.mx|com\.ar|co\.nz|com\.pl|com\.ge|com\.am|co\.za|org\.uk|net\.ua|org\.ua|com\.cy|com\.mt'

    for src in "${GROXY_DIR}/bridge/whitelist/opencck.txt" \
               "${GROXY_DIR}/bridge/whitelist/custom.txt"; do
        [[ -f "${src}" ]] || continue
        while IFS= read -r line || [[ -n "${line}" ]]; do
            domain=$(_bridge_dns_domain_from_line "${line}")
            [[ -n "${domain}" ]] || continue
            [[ "${domain}" =~ ${ru_re} ]] && continue
            printf '%s\n' "${domain}"
        done < "${src}"
    done | awk -v multi="${multi}" '
        {
            n = split($0, p, ".")
            if (n < 2) next
            two = p[n-1] "." p[n]
            if (two ~ "^(" multi ")$" && n >= 3)
                print p[n-2] "." two
            else
                print two
        }' | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
           | sort -u
}

# Render /etc/dnsmasq.conf.
#
# Разделение резолверов по географии — вот ради чего эта функция стала
# нетривиальной. dnsmasq стоит на бридже в России, а зарубежный трафик выходит
# из Нидерландов; CDN выбирает узел выдачи по расположению резолвера, и Akamai
# отдавал Steam узел в 138 мс от портала вместо 4 мс. Разбор и замеры — в
# docs/DIAG-SLOW-STEAM.md и docs/DNS-BASELINE.md.
#
# Поэтому: всё по умолчанию идёт на Cloudflare, который host-маршрутами уведён
# в туннель и потому отвечает «из Нидерландов», а российские зоны и российские
# сервисы в чужих зонах пиннятся на Google по прямому пути и отвечают «из
# России». Обратное разделение сломало бы российские CDN.
bridge_render_dnsmasq_conf() {
    local suffixes zone resolver
    suffixes=$(_bridge_dns_ru_suffixes)

    if [[ -z "${suffixes}" ]]; then
        log "warning: whitelist feed empty or missing — only the Russian TLDs" \
            "will resolve locally; Russian services in .com/.net will not"
    fi

    {
        cat <<EOF
# Managed by groxy ${GROXY_VERSION}. Do not edit by hand.
interface=wg0
bind-dynamic
no-resolv
cache-size=10000
# Короткий минимум TTL: ответы CDN живут секунды, и без него кэш почти не
# работает, а каждый промах теперь стоит плечо до портала.
min-cache-ttl=20
conf-dir=/etc/dnsmasq.d/,*.conf

# Зарубежные домены — через резолвер, уведённый в туннель.
EOF
        for resolver in ${BRIDGE_DNS_FOREIGN}; do
            printf 'server=%s\n' "${resolver}"
        done

        printf '\n# Российские зоны — прямым путём, чтобы CDN видел российский резолвер.\n'
        for zone in ${BRIDGE_DNS_RU_ZONES}; do
            for resolver in ${BRIDGE_DNS_LOCAL}; do
                printf 'server=/%s/%s\n' "${zone}" "${resolver}"
            done
        done

        if [[ -n "${suffixes}" ]]; then
            printf '\n# Российские сервисы в чужих зонах — тоже прямым путём.\n'
            while IFS= read -r zone; do
                for resolver in ${BRIDGE_DNS_LOCAL}; do
                    printf 'server=/%s/%s\n' "${zone}" "${resolver}"
                done
            done <<<"${suffixes}"
        fi
    } | write_atomic "${GROXY_DNSMASQ_CONF}" 644
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
    if [[ ! -f "${dir}/source-url" ]]; then
        printf '%s\n' "${BRIDGE_DEFAULT_OPENCCK_URL}" > "${dir}/source-url"
        log "seeded ${dir}/source-url with default opencck URL"
    fi
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
        # Pass through already-formatted dnsmasq ipset= directives
        # (opencck format=ipset emits this form directly).
        if [[ "${line}" == ipset=* ]]; then
            printf '%s\n' "${line}"
            continue
        fi
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
Description=groxy — refresh DNS whitelist + GeoIP feeds
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${groxy_bin} bridge whitelist update
ExecStart=${groxy_bin} bridge geoip update
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
    bridge_ensure_geoip_dir
    bridge_ensure_settings
    bridge_render_dnsmasq_conf

    # Ensure wg0 actually has its address before (re)starting dnsmasq —
    # see _bridge_dnsmasq_restart_verify for why this matters.
    _bridge_wait_for_wg0_address

    systemctl enable dnsmasq >/dev/null 2>&1
    _bridge_dnsmasq_restart_verify

    bridge_install_whitelist_timer

    # Первый прогон обоих feed'ов — наполняет ipset'ы и opencck.txt сразу,
    # чтобы не ждать суточный таймер (он сработает только на следующих :00
    # + ≤15min jitter).
    log "first whitelist (opencck) feed refresh"
    bridge_whitelist_update
    log "first GeoIP feed refresh"
    bridge_geoip_update

    # Применяем settings: рендерим dnsmasq.d-файлы и заполняем ipset
    # согласно текущим тоггалам.
    bridge_apply_settings
}

# `groxy bridge whitelist reload` — re-render 50-custom.conf and
# 00-opencck.conf from their sources, restart dnsmasq.
bridge_whitelist_reload() {
    require_root
    acquire_state_lock
    local dir="${GROXY_DIR}/bridge/whitelist"
    [[ -d "${dir}" ]] || die "whitelist not initialised — run 'groxy init bridge' first"
    log "applying settings (respects opencck/custom/geoip toggles)"
    bridge_apply_settings
}

# `groxy bridge whitelist set-source <url>` — persist the opencck-style
# source URL. Doesn't fetch — call `whitelist update` to refresh.
bridge_whitelist_set_source() {
    require_root
    acquire_state_lock
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
# opencck.txt atomically, re-render 00-opencck.conf, flush + rebuild the
# vpn_domains carve-out, restart dnsmasq.
#
# Why the flush: vpn_domains is hash:ip with no per-entry timeout, and
# dnsmasq only ever *adds* IPs to it (at resolve time, via the ipset=
# directives). Nothing removes them, so the set is effectively append-only
# and grows without bound — stale entries and false-positives (e.g. a
# whitelisted RU domain that once resolved onto a shared CDN/foreign IP
# also used by a service we want via the portal) linger forever, wrongly
# carving that foreign service direct out the RU bridge IP. Flushing on
# each daily refresh makes the set rebuild from *live* resolutions, the
# same way ru_cidrs is rebuilt wholesale from the GeoIP feed. The flush is
# done only after a successful fetch+render (a failed fetch returns early,
# leaving the set intact) and is paired with the dnsmasq restart below,
# whose cache-clear forces clients to re-resolve and repopulate.
#
# Treats fetch failures as soft: keeps previous list intact, logs warning.
bridge_whitelist_update() {
    require_root
    # Запускается ежедневно по таймеру, то есть может совпасть с чем угодно.
    # Перестраивает ru_cidrs через общий временный набор, и одновременный
    # `groxy apply` получал ошибку на его удалении.
    acquire_state_lock
    local dir="${GROXY_DIR}/bridge/whitelist"
    [[ -d "${dir}" ]] || die "whitelist not initialised — run 'groxy init bridge' first"

    local WHITELIST_OPENCCK WHITELIST_CUSTOM WHITELIST_GEOIP
    bridge_settings_load
    if [[ "${WHITELIST_OPENCCK}" != 'on' ]]; then
        log "WHITELIST_OPENCCK=off; skipping opencck fetch"
        return 0
    fi

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

    # Clean rebuild: drop accumulated/stale carve-outs so the set is
    # repopulated from live resolutions after the restart below. See the
    # function header for the rationale. Brief window: active connections
    # to vpn_domains-only IPs (RU domains on non-RU IPs not covered by
    # ru_cidrs) reroute direct→portal until re-resolved; ru_cidrs-covered
    # traffic and portal traffic are unaffected.
    log "flushing vpn_domains for clean rebuild (clears stale carve-outs)"
    ipset flush vpn_domains 2>/dev/null || true

    log "restarting dnsmasq"
    _bridge_dnsmasq_restart_verify
}
