#!/usr/bin/env bash
# Read-only diagnostic — single 'groxy status' command for both roles.
# Sourced by the dispatcher; do not execute directly.

# Threshold above which a "latest handshake" is flagged as stale.
readonly STATUS_HANDSHAKE_STALE_SECONDS=180

# Print "Ns ago" / "Nm ago" / "Nh ago" / "Nd ago" for a past epoch.
# Empty input → "never".
_status_fmt_age() {
    local epoch="${1:-0}"
    if [[ -z "${epoch}" || "${epoch}" == '0' ]]; then
        printf 'never'
        return
    fi
    local now delta
    now=$(date +%s)
    delta=$((now - epoch))
    if (( delta < 60 ));     then printf '%ds ago' "${delta}"
    elif (( delta < 3600 )); then printf '%dm ago' "$((delta / 60))"
    elif (( delta < 86400 ));then printf '%dh ago' "$((delta / 3600))"
    else                          printf '%dd ago' "$((delta / 86400))"
    fi
}

# Mark for `[OK]`/`[WARN]`/`[FAIL]` columns.
_status_mark() {
    case "$1" in
        ok)   printf '[ OK ]' ;;
        warn) printf '[WARN]' ;;
        fail) printf '[FAIL]' ;;
    esac
}

# Print a one-line status row for a systemd unit. is-enabled is informational —
# we only mark FAIL if the unit isn't active.
_status_service() {
    local unit="$1" extra="${2:-}"
    local active mark
    active=$(systemctl is-active "${unit}" 2>/dev/null || true)
    case "${active}" in
        active)             mark=ok ;;
        activating|reloading) mark=warn ;;
        *)                  mark=fail ;;
    esac
    printf '  %s  %-32s %-10s %s\n' "$(_status_mark "${mark}")" "${unit}" "${active}" "${extra}"
}

# Print a single key=value setting row.
_status_setting_row() {
    local key="$1" value="$2" detail="${3:-}"
    printf '  %-9s %-5s %s\n' "${key}" "${value}" "${detail}"
}

# Print the count of entries currently loaded in an ipset.
_status_ipset_count() {
    local set="$1"
    ipset list "${set}" 2>/dev/null | awk -F': ' '/^Number of entries:/ {print $2; exit}'
}

# Print 'Mon DD HH:MM' for the mtime of a file, or '(never)' if absent.
_status_file_mtime() {
    local path="$1"
    [[ -f "${path}" ]] || { printf '(never)'; return; }
    date -d "@$(stat -c '%Y' "${path}")" '+%Y-%m-%d %H:%M'
}

# Print the latest-handshake epoch (seconds) for a given peer pubkey on iface.
# Empty/0 if no handshake recorded.
_status_handshake_epoch() {
    local iface="$1" pubkey="$2"
    wg show "${iface}" latest-handshakes 2>/dev/null \
        | awk -v k="${pubkey}" '$1 == k {print $2; exit}'
}

# --------------------------------------------------------------------------
# Portal status
# --------------------------------------------------------------------------

status_portal() {
    local cfg_dir="${GROXY_DIR}/portal"
    local PUBLIC_IP='' LISTEN_PORT='' TUNNEL_SUBNET='' EGRESS_IFACE=''
    if [[ -f "${cfg_dir}/server.env" ]]; then
        # shellcheck source=/dev/null
        source "${cfg_dir}/server.env"
    fi
    local version=''
    [[ -f "${GROXY_DIR}/version" ]] && version=$(<"${GROXY_DIR}/version")

    printf 'groxy %s — portal\n' "${version:-?}"
    printf '  Endpoint:      %s:%s\n' "${PUBLIC_IP:-?}" "${LISTEN_PORT:-?}"
    printf '  Tunnel subnet: %s\n'    "${TUNNEL_SUBNET:-?}"
    printf '  Egress iface:  %s\n'    "${EGRESS_IFACE:-?}"
    printf '\n'

    printf 'Services:\n'
    local listen_extra=''
    [[ -n "${LISTEN_PORT}" ]] && listen_extra="listening UDP/${LISTEN_PORT}"
    _status_service wg-quick@wg0 "${listen_extra}"
    printf '\n'

    printf 'Bridges:\n'
    if [[ ! -d "${cfg_dir}/bridges" ]] \
        || ! compgen -G "${cfg_dir}/bridges/*.peer" >/dev/null; then
        printf '  (none registered)\n'
        return
    fi
    printf '  %-20s %-15s %-10s %s\n' 'NAME' 'BRIDGE_IP' 'STATUS' 'LAST_HANDSHAKE'
    local peer_file name PSK BRIDGE_IP PUBLIC_KEY epoch age status
    for peer_file in "${cfg_dir}"/bridges/*.peer; do
        [[ -e "${peer_file}" ]] || continue
        name=$(basename "${peer_file}" .peer)
        PSK=''; BRIDGE_IP=''; PUBLIC_KEY=''
        # shellcheck source=/dev/null
        source "${peer_file}"
        if [[ -z "${PUBLIC_KEY}" ]]; then
            status='pending'
            age='-'
        else
            status='active'
            epoch=$(_status_handshake_epoch wg0 "${PUBLIC_KEY}")
            age=$(_status_fmt_age "${epoch}")
        fi
        printf '  %-20s %-15s %-10s %s\n' "${name}" "${BRIDGE_IP}" "${status}" "${age}"
    done
}

# --------------------------------------------------------------------------
# Bridge status
# --------------------------------------------------------------------------

status_bridge() {
    local cfg_dir="${GROXY_DIR}/bridge"
    local version=''
    [[ -f "${GROXY_DIR}/version" ]] && version=$(<"${GROXY_DIR}/version")

    # Portal context
    local portal_name='' PORTAL_ENDPOINT='' PORTAL_PORT='' PORTAL_PUBKEY=''
    local TUNNEL_PORTAL_IP='' TUNNEL_BRIDGE_IP=''
    if [[ -f "${cfg_dir}/current-portal" ]]; then
        portal_name=$(<"${cfg_dir}/current-portal")
        if [[ -f "${cfg_dir}/portals/${portal_name}/portal.env" ]]; then
            # shellcheck source=/dev/null
            source "${cfg_dir}/portals/${portal_name}/portal.env"
        fi
    fi

    local wg1_handshake_age='?'
    if [[ -n "${PORTAL_PUBKEY}" ]]; then
        wg1_handshake_age=$(_status_fmt_age "$(_status_handshake_epoch wg1 "${PORTAL_PUBKEY}")")
    fi

    # wg0 server context
    local WG0_SUBNET='' WG0_LISTEN_PORT='' WG0_PUBLIC_IP=''
    if [[ -f "${cfg_dir}/wg0/server.env" ]]; then
        local SUBNET='' LISTEN_PORT='' PUBLIC_IP=''
        # shellcheck source=/dev/null
        source "${cfg_dir}/wg0/server.env"
        WG0_SUBNET="${SUBNET}"
        WG0_LISTEN_PORT="${LISTEN_PORT}"
        WG0_PUBLIC_IP="${PUBLIC_IP}"
    fi

    printf 'groxy %s — bridge\n' "${version:-?}"
    printf '  Active portal: %s\n' "${portal_name:-?}"
    [[ -n "${PORTAL_ENDPOINT}" ]] \
        && printf '  Portal endpoint: %s:%s\n' "${PORTAL_ENDPOINT}" "${PORTAL_PORT}"
    [[ -n "${TUNNEL_BRIDGE_IP}" ]] \
        && printf '  Tunnel: %s (bridge) ↔ %s (portal), handshake %s\n' \
               "${TUNNEL_BRIDGE_IP}" "${TUNNEL_PORTAL_IP}" "${wg1_handshake_age}"
    [[ -n "${WG0_PUBLIC_IP}" ]] \
        && printf '  Client endpoint: %s:%s\n' "${WG0_PUBLIC_IP}" "${WG0_LISTEN_PORT}"
    [[ -n "${WG0_SUBNET}" ]] \
        && printf '  Client subnet: %s\n' "${WG0_SUBNET}"
    printf '\n'

    printf 'Services:\n'
    _status_service wg-quick@wg0   "UDP/${WG0_LISTEN_PORT:-?}"
    _status_service wg-quick@wg1   "handshake ${wg1_handshake_age}"
    _status_service dnsmasq        "DNS on ${WG0_SUBNET%%/*}.1:53"
    _status_service ipset-restore.service
    _status_service groxy-whitelist-update.timer \
        "$(systemctl list-timers groxy-whitelist-update.timer --no-pager 2>/dev/null \
            | awk 'NR==2 {print "next " $1 " " $2 " " $3}')"
    printf '\n'

    # Settings + feed health
    local WHITELIST_OPENCCK WHITELIST_CUSTOM WHITELIST_GEOIP
    bridge_settings_load
    local wl_dir="${cfg_dir}/whitelist"
    local opencck_lines='?' custom_lines='?' geoip_lines='?'
    [[ -f "${wl_dir}/opencck.txt"  ]] && opencck_lines=$(wc -l < "${wl_dir}/opencck.txt")
    [[ -f "${wl_dir}/custom.txt"   ]] && custom_lines=$(grep -cvE '^\s*(#|$)' "${wl_dir}/custom.txt" 2>/dev/null || printf 0)
    [[ -f "${wl_dir}/ru_cidrs.list" ]] && geoip_lines=$(wc -l < "${wl_dir}/ru_cidrs.list")
    printf 'Settings:\n'
    _status_setting_row opencck "${WHITELIST_OPENCCK}" \
        "${opencck_lines} domains, fetched $(_status_file_mtime "${wl_dir}/opencck.txt")"
    _status_setting_row custom  "${WHITELIST_CUSTOM}"  "${custom_lines} domains in custom.txt"
    _status_setting_row geoip   "${WHITELIST_GEOIP}" \
        "${geoip_lines} CIDRs, fetched $(_status_file_mtime "${wl_dir}/ru_cidrs.list")"
    printf '\n'

    printf 'ipsets:\n'
    printf '  %-12s %s entries\n' 'vpn_domains' "$(_status_ipset_count vpn_domains)"
    printf '  %-12s %s entries\n' 'ru_cidrs'    "$(_status_ipset_count ru_cidrs)"
    printf '\n'

    printf 'Clients (wg0):\n'
    local clients_dir="${cfg_dir}/wg0/clients"
    if [[ ! -d "${clients_dir}" ]] \
        || ! compgen -G "${clients_dir}/*.peer" >/dev/null; then
        printf '  (none)\n'
    else
        printf '  %-20s %-15s %s\n' 'NAME' 'ADDR' 'LAST_HANDSHAKE'
        local peer_file name PSK ADDR PUBLIC_KEY epoch
        for peer_file in "${clients_dir}"/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            name=$(basename "${peer_file}" .peer)
            PSK=''; ADDR=''; PUBLIC_KEY=''
            # shellcheck source=/dev/null
            source "${peer_file}"
            epoch=$(_status_handshake_epoch wg0 "${PUBLIC_KEY}")
            printf '  %-20s %-15s %s\n' "${name}" "${ADDR}" "$(_status_fmt_age "${epoch}")"
        done
    fi
    printf '\n'

    # Warnings
    local warnings=()
    if [[ -n "${PORTAL_PUBKEY}" ]]; then
        local wg1_epoch
        wg1_epoch=$(_status_handshake_epoch wg1 "${PORTAL_PUBKEY}")
        if [[ -z "${wg1_epoch}" || "${wg1_epoch}" == '0' ]]; then
            warnings+=("wg1 handshake never completed — portal may be unreachable")
        elif (( $(date +%s) - wg1_epoch > STATUS_HANDSHAKE_STALE_SECONDS )); then
            warnings+=("wg1 handshake is stale (${wg1_handshake_age}) — portal may be down")
        fi
    fi
    if [[ "${WHITELIST_OPENCCK}" == 'on' && "$(_status_ipset_count vpn_domains)" == '0' \
            && -s "${wl_dir}/opencck.txt" ]]; then
        warnings+=("vpn_domains ipset empty but opencck list has ${opencck_lines} entries — try 'bridge whitelist reload'")
    fi
    if [[ "${WHITELIST_GEOIP}" == 'on' && "$(_status_ipset_count ru_cidrs)" == '0' \
            && -s "${wl_dir}/ru_cidrs.list" ]]; then
        warnings+=("ru_cidrs ipset empty but list has ${geoip_lines} CIDRs — try 'bridge geoip update'")
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        printf 'Warnings:\n'
        local w
        for w in "${warnings[@]}"; do
            printf '  %s %s\n' "$(_status_mark warn)" "${w}"
        done
    else
        printf '(no warnings)\n'
    fi
}

# --------------------------------------------------------------------------
# Dispatcher entry point
# --------------------------------------------------------------------------

cmd_status_real() {
    local role=''
    [[ -f "${GROXY_DIR}/role" ]] && role=$(<"${GROXY_DIR}/role")
    case "${role}" in
        portal) status_portal ;;
        bridge) status_bridge ;;
        '')     die "groxy not initialised on this host (run 'groxy init <portal|bridge>')" ;;
        *)      die "unknown role '${role}' in ${GROXY_DIR}/role" ;;
    esac
}
