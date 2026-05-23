#!/usr/bin/env bash
# 'groxy uninstall' — reverse of 'groxy init'. Stops + disables managed
# services, removes rendered configs and systemd units, backs up the
# declarative state to /etc/groxy.bak.<ts>. Apt packages stay installed
# (user may want wireguard/dnsmasq/ipset around for other purposes).
# Sourced by the dispatcher; do not execute directly.

# Suppress noisy systemd output. Errors are swallowed because uninstall
# is best-effort — services may already be stopped, files may not exist
# from a partial install, etc.
_uninstall_stop_disable() {
    local unit="$1"
    systemctl disable --now "${unit}" >/dev/null 2>&1 || true
}

# Strip the 'vpn2' route table entry from /etc/iproute2/rt_tables, if any.
_uninstall_clean_rt_tables() {
    local file=/etc/iproute2/rt_tables
    [[ -f "${file}" ]] || return 0
    sed -i '/^[[:space:]]*200[[:space:]]\+vpn2[[:space:]]*$/d' "${file}"
    # If we leave the file empty of meaningful content, that's the same as
    # how it shipped on Debian 13 (file may not have existed at all).
}

# Backup current state to /etc/groxy.bak.<timestamp> via rename. Returns
# the backup path (caller can log it).
_uninstall_backup_state() {
    local backup="/etc/groxy.bak.$(date +%Y%m%d-%H%M%S)"
    mv "${GROXY_DIR}" "${backup}"
    printf '%s\n' "${backup}"
}

portal_uninstall() {
    log "stopping wg-quick@wg0"
    _uninstall_stop_disable wg-quick@wg0

    log "removing managed files"
    rm -f /etc/wireguard/wg0.conf
    rm -f /etc/sysctl.d/99-groxy.conf
    sysctl -q -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true

    local backup
    backup=$(_uninstall_backup_state)
    log "state backed up to ${backup}"
    log "portal uninstalled. apt packages (wireguard/iptables/curl) kept."
}

bridge_uninstall() {
    log "stopping daily whitelist timer"
    _uninstall_stop_disable groxy-whitelist-update.timer
    rm -f /etc/systemd/system/groxy-whitelist-update.timer
    rm -f /etc/systemd/system/groxy-whitelist-update.service

    log "stopping wg-quick@wg1 + wg-quick@wg0"
    _uninstall_stop_disable wg-quick@wg1
    _uninstall_stop_disable wg-quick@wg0

    log "stopping dnsmasq"
    _uninstall_stop_disable dnsmasq

    log "stopping ipset-restore"
    _uninstall_stop_disable ipset-restore.service
    rm -f /etc/systemd/system/ipset-restore.service

    systemctl daemon-reload

    log "destroying ipsets"
    ipset destroy vpn_domains 2>/dev/null || true
    ipset destroy ru_cidrs    2>/dev/null || true

    log "removing rendered configs"
    rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg1.conf
    rm -f /etc/dnsmasq.conf
    rm -f /etc/dnsmasq.d/00-opencck.conf /etc/dnsmasq.d/50-custom.conf
    rm -f /etc/ipset/ipset.conf
    rmdir /etc/ipset 2>/dev/null || true
    rm -f /etc/sysctl.d/99-groxy.conf

    sysctl -q -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true

    log "cleaning /etc/iproute2/rt_tables ('200 vpn2' entry)"
    _uninstall_clean_rt_tables

    local backup
    backup=$(_uninstall_backup_state)
    log "state backed up to ${backup}"
    log "bridge uninstalled. apt packages (wireguard/iptables/curl/dnsmasq/ipset/qrencode) kept."
}

cmd_uninstall_real() {
    require_root
    local arg yes=0
    for arg in "$@"; do
        case "${arg}" in
            --yes|-y) yes=1 ;;
            --*) die "uninstall: unknown flag '${arg}'" ;;
            *)   die "uninstall: unexpected argument '${arg}'" ;;
        esac
    done

    local role=''
    [[ -f "${GROXY_DIR}/role" ]] && role=$(<"${GROXY_DIR}/role")
    [[ -n "${role}" ]] || die "groxy not initialised on this host (nothing to uninstall)"

    if (( ! yes )); then
        printf 'About to uninstall groxy (role: %s).\n' "${role}" >&2
        printf 'This will:\n' >&2
        printf '  - stop and disable managed systemd units\n' >&2
        printf '  - remove rendered files in /etc/wireguard/ /etc/dnsmasq.* /etc/ipset/ /etc/sysctl.d/\n' >&2
        printf '  - move %s to /etc/groxy.bak.<timestamp>\n' "${GROXY_DIR}" >&2
        printf '  - keep apt packages installed\n' >&2
        printf '\nType '"'"'yes'"'"' to confirm: ' >&2
        local answer=''
        read -r answer
        [[ "${answer}" == 'yes' ]] || die "aborted by user"
    fi

    case "${role}" in
        portal) portal_uninstall ;;
        bridge) bridge_uninstall ;;
        *) die "unknown role '${role}'" ;;
    esac
}
