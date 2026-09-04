#!/usr/bin/env bash
# Multi-portal management for bridge — register multiple portals and switch
# between them without full re-init.
# Sourced by the dispatcher; do not execute directly.
#
# State is already laid out for this since stage 1.3:
#   /etc/groxy/bridge/portals/<name>/portal.env + portal-public.key
#   /etc/groxy/bridge/current-portal   ← text file with active dir name
#
# Bridge identity (wg1 keypair) is shared across portals: one bridge =
# one pubkey, each portal sees it as a peer with the AllowedIP that the
# respective profile assigned.

# `groxy bridge add-portal <name> --profile=<file>`. Imports a profile under
# /etc/groxy/bridge/portals/<name>/, does NOT switch active portal. Prints
# the bridge's pubkey for use in 'portal accept-bridge' on the new portal.
bridge_add_portal() {
    require_root
    acquire_state_lock
    local arg name='' profile=''
    for arg in "$@"; do
        case "${arg}" in
            --profile=*) profile="${arg#*=}" ;;
            --*) die "bridge add-portal: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "bridge add-portal: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]]    || die "usage: groxy bridge add-portal <name> --profile=<file>"
    [[ -n "${profile}" ]] || die "missing --profile=<file>"
    validate_peer_name "${name}"

    [[ -d "${GROXY_DIR}/bridge" ]] \
        || die "bridge not initialised — run 'groxy init bridge --portal-profile=...' first"

    local portal_dir="${GROXY_DIR}/bridge/portals/${name}"
    [[ -e "${portal_dir}" ]] \
        && die "portal '${name}' already exists; remove first with 'bridge remove-portal ${name}'"

    # Validate profile via the shared loader (dynamic scoping: caller must
    # declare the eight vars as local before calling).
    local PORTAL_NAME='' PORTAL_ENDPOINT='' PORTAL_PORT='' PORTAL_PUBKEY=''
    local PSK='' TUNNEL_SUBNET='' TUNNEL_PORTAL_IP='' TUNNEL_BRIDGE_IP=''
    _bridge_load_profile "${profile}"

    mkdir -p "${portal_dir}"
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

    local bridge_pubkey
    bridge_pubkey=$(<"${GROXY_DIR}/bridge/public.key")

    log "registered portal '${name}' (endpoint ${PORTAL_ENDPOINT}:${PORTAL_PORT})"
    log "active portal unchanged; switch with 'groxy bridge use-portal ${name}'"
    log ""
    log "next: отдай этот pubkey админу portal'а '${name}' для активации:"
    log "  groxy portal accept-bridge <bridge-name> --pubkey=${bridge_pubkey}"

    printf '%s\n' "${bridge_pubkey}"
}

# `groxy bridge list-portals`.
bridge_list_portals() {
    require_root
    local cfg_dir="${GROXY_DIR}/bridge"
    [[ -d "${cfg_dir}/portals" ]] \
        || die "bridge not initialised — run 'groxy init bridge --portal-profile=...' first"

    local current=''
    [[ -f "${cfg_dir}/current-portal" ]] && current=$(<"${cfg_dir}/current-portal")

    printf '%-3s %-20s %-25s %s\n' '' 'NAME' 'ENDPOINT' 'BRIDGE_IP'
    local portal_path name PORTAL_NAME PORTAL_ENDPOINT PORTAL_PORT PORTAL_PUBKEY
    local PSK TUNNEL_SUBNET TUNNEL_PORTAL_IP TUNNEL_BRIDGE_IP marker
    for portal_path in "${cfg_dir}"/portals/*/; do
        [[ -e "${portal_path}/portal.env" ]] || continue
        name=$(basename "${portal_path}")
        PORTAL_NAME=''; PORTAL_ENDPOINT=''; PORTAL_PORT=''
        PORTAL_PUBKEY=''; PSK=''; TUNNEL_SUBNET=''
        TUNNEL_PORTAL_IP=''; TUNNEL_BRIDGE_IP=''
        # shellcheck source=/dev/null
        source "${portal_path}/portal.env"
        marker=' '
        [[ "${name}" == "${current}" ]] && marker='*'
        printf ' %s  %-20s %-25s %s\n' \
            "${marker}" "${name}" "${PORTAL_ENDPOINT}:${PORTAL_PORT}" "${TUNNEL_BRIDGE_IP}"
    done
}

# `groxy bridge use-portal <name>`. Switches active portal: updates
# current-portal, re-renders wg1.conf, restarts wg-quick@wg1. Clients on
# wg0 are unaffected (their tunnel terminates at wg0, not wg1).
bridge_use_portal() {
    require_root
    # Held for the whole switch: the failover monitor calls this on its own
    # schedule, so it can collide with a hand-run command at any moment.
    acquire_state_lock
    local arg name=''
    for arg in "$@"; do
        case "${arg}" in
            --*) die "bridge use-portal: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "bridge use-portal: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]] || die "usage: groxy bridge use-portal <name>"
    validate_peer_name "${name}"

    local cfg_dir="${GROXY_DIR}/bridge"
    [[ -d "${cfg_dir}/portals/${name}" ]] \
        || die "portal '${name}' not registered (try 'bridge list-portals')"

    local current=''
    [[ -f "${cfg_dir}/current-portal" ]] && current=$(<"${cfg_dir}/current-portal")
    if [[ "${current}" == "${name}" ]]; then
        log "portal '${name}' is already active; no-op"
        return 0
    fi

    write_atomic "${cfg_dir}/current-portal" 644 <<<"${name}"
    log "switched active portal: ${current:-(none)} → ${name}"

    log "re-rendering /etc/wireguard/wg1.conf"
    bridge_render_wg1_conf

    log "restarting wg-quick@wg1"
    wg_quick_enable_restart wg1
    log "wg-quick@wg1 reloaded — handshake to '${name}' should converge within ~25s"
}

# `groxy bridge remove-portal <name> [--yes]`. Refuses to remove the
# currently-active portal — call 'use-portal' first to switch.
bridge_remove_portal() {
    require_root
    acquire_state_lock
    local arg name=''
    for arg in "$@"; do
        case "${arg}" in
            --yes) ;;
            --*) die "bridge remove-portal: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "bridge remove-portal: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]] || die "usage: groxy bridge remove-portal <name> [--yes]"
    validate_peer_name "${name}"

    local cfg_dir="${GROXY_DIR}/bridge"
    [[ -d "${cfg_dir}/portals/${name}" ]] \
        || die "portal '${name}' not registered"

    local current=''
    [[ -f "${cfg_dir}/current-portal" ]] && current=$(<"${cfg_dir}/current-portal")
    if [[ "${current}" == "${name}" ]]; then
        die "cannot remove active portal '${name}'; switch first with 'bridge use-portal <other>'"
    fi

    rm -rf "${cfg_dir}/portals/${name}"
    log "removed portal '${name}'"
}
