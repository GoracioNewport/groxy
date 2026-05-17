#!/usr/bin/env bash
# Bridge role — RU-side entry point. Sourced by the dispatcher; do not
# execute directly.
#
# v1 of `init bridge` is intentionally minimal: it brings up only the wg1
# tunnel to the active portal so the bridge↔portal handshake can be
# end-to-end-tested. Subsequent steps layer in wg0 (client side),
# dnsmasq + ipset, mangle PREROUTING marking, and the daily whitelist
# refresh timer.

# Parse `init bridge` flags into BRIDGE_INIT_* globals.
_bridge_parse_init_flags() {
    BRIDGE_INIT_PORTAL_PROFILE=''
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --portal-profile=*) BRIDGE_INIT_PORTAL_PROFILE="${arg#*=}" ;;
            *) die "init bridge: unknown flag '${arg}'" ;;
        esac
    done
}

# Validate a portal-profile file and load it into the *caller's* scope.
# Relies on dynamic scoping: caller must declare the eight profile vars as
# local before calling, then read them after the function returns.
_bridge_load_profile() {
    local file="$1"
    [[ -f "${file}" ]] || die "profile file not found: ${file}"
    # shellcheck source=/dev/null
    source "${file}"

    local var
    for var in PORTAL_NAME PORTAL_ENDPOINT PORTAL_PORT PORTAL_PUBKEY PSK \
               TUNNEL_SUBNET TUNNEL_PORTAL_IP TUNNEL_BRIDGE_IP; do
        [[ -n "${!var:-}" ]] || die "profile missing required field: ${var}"
    done

    validate_peer_name "${PORTAL_NAME}"
    validate_wg_key "${PORTAL_PUBKEY}" "portal pubkey"
    validate_wg_key "${PSK}" "PSK"
    [[ "${PORTAL_PORT}" =~ ^[0-9]+$ ]] \
        || die "profile PORTAL_PORT not numeric: '${PORTAL_PORT}'"
}

# Render /etc/wireguard/wg1.conf for the active portal. Minimal form — only
# the tunnel itself, no mangle/ipset/forward rules. Those join when the
# wg0-side is implemented.
bridge_render_wg1_conf() {
    local cfg_dir="${GROXY_DIR}/bridge"
    [[ -f "${cfg_dir}/current-portal" ]] \
        || die "no active portal selected; run 'groxy init bridge --portal-profile=...' first"

    local portal_name
    portal_name=$(<"${cfg_dir}/current-portal")
    local portal_dir="${cfg_dir}/portals/${portal_name}"
    [[ -d "${portal_dir}" ]] || die "active portal '${portal_name}' missing state dir"

    local PORTAL_NAME='' PORTAL_ENDPOINT='' PORTAL_PORT='' PORTAL_PUBKEY=''
    local PSK='' TUNNEL_SUBNET='' TUNNEL_PORTAL_IP='' TUNNEL_BRIDGE_IP=''
    # shellcheck source=/dev/null
    source "${portal_dir}/portal.env"

    local private_key
    private_key=$(<"${cfg_dir}/private.key")

    write_atomic /etc/wireguard/wg1.conf 600 <<EOF
# Managed by groxy ${GROXY_VERSION}. Do not edit by hand —
# changes will be overwritten on next 'groxy apply'.
# Active portal: ${portal_name}

[Interface]
PrivateKey = ${private_key}
Address = ${TUNNEL_BRIDGE_IP}/32

[Peer]
PublicKey = ${PORTAL_PUBKEY}
PresharedKey = ${PSK}
Endpoint = ${PORTAL_ENDPOINT}:${PORTAL_PORT}
AllowedIPs = ${TUNNEL_PORTAL_IP}/32
PersistentKeepalive = 25
EOF
}

# `groxy init bridge --portal-profile=<file>`. Minimal v1 — sets up only
# the wg1 tunnel and prints the bridge's pubkey to stdout, which the
# operator must hand to the portal admin for `portal accept-bridge`.
# Idempotent.
bridge_init() {
    require_root
    _bridge_parse_init_flags "$@"
    require_supported_os

    [[ -n "${BRIDGE_INIT_PORTAL_PROFILE}" ]] \
        || die "usage: groxy init bridge --portal-profile=<file>"

    if [[ -f "${GROXY_DIR}/role" ]]; then
        local current
        current=$(<"${GROXY_DIR}/role")
        if [[ "${current}" != 'bridge' ]]; then
            die "this machine is already initialised as '${current}'; refusing to overwrite (run 'groxy uninstall' first)"
        fi
    fi

    # Validate the profile first — don't touch the system if it's malformed.
    local PORTAL_NAME='' PORTAL_ENDPOINT='' PORTAL_PORT='' PORTAL_PUBKEY=''
    local PSK='' TUNNEL_SUBNET='' TUNNEL_PORTAL_IP='' TUNNEL_BRIDGE_IP=''
    _bridge_load_profile "${BRIDGE_INIT_PORTAL_PROFILE}"

    apt_install wireguard iptables curl

    mkdir -p "${GROXY_DIR}/bridge/portals/${PORTAL_NAME}"
    chmod 700 "${GROXY_DIR}/bridge"

    log "ensuring WG keypair in ${GROXY_DIR}/bridge"
    wg_ensure_keypair "${GROXY_DIR}/bridge"

    local portal_dir="${GROXY_DIR}/bridge/portals/${PORTAL_NAME}"
    write_atomic "${portal_dir}/portal.env" 600 <<EOF
PORTAL_NAME=${PORTAL_NAME}
PORTAL_ENDPOINT=${PORTAL_ENDPOINT}
PORTAL_PORT=${PORTAL_PORT}
PORTAL_PUBKEY=${PORTAL_PUBKEY}
PSK=${PSK}
TUNNEL_SUBNET=${TUNNEL_SUBNET}
TUNNEL_PORTAL_IP=${TUNNEL_PORTAL_IP}
TUNNEL_BRIDGE_IP=${TUNNEL_BRIDGE_IP}
EOF
    write_atomic "${portal_dir}/portal-public.key" 644 <<<"${PORTAL_PUBKEY}"

    write_atomic "${GROXY_DIR}/bridge/current-portal" 644 <<<"${PORTAL_NAME}"
    write_atomic "${GROXY_DIR}/role" 644 <<<'bridge'
    write_atomic "${GROXY_DIR}/version" 644 <<<"${GROXY_VERSION}"

    log "rendering /etc/wireguard/wg1.conf"
    bridge_render_wg1_conf

    log "starting wg-quick@wg1"
    wg_quick_enable_restart wg1

    local bridge_pubkey
    bridge_pubkey=$(<"${GROXY_DIR}/bridge/public.key")

    log "bridge initialised — active portal: ${PORTAL_NAME}"
    log "tunnel: ${TUNNEL_BRIDGE_IP} (bridge) ↔ ${TUNNEL_PORTAL_IP} (portal) via ${PORTAL_ENDPOINT}:${PORTAL_PORT}"
    log ""
    log "next: отдай этот pubkey админу portal'а для активации:"
    log "  groxy portal accept-bridge <bridge-name> --pubkey=${bridge_pubkey}"

    # Pubkey also on stdout — handy for scripting / pipes.
    printf '%s\n' "${bridge_pubkey}"
}
