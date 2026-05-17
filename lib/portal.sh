#!/usr/bin/env bash
# Portal role — install and configure a VPS as the foreign exit-relay.
# Sourced by the dispatcher; do not execute directly.

readonly PORTAL_DEFAULT_SUBNET='10.77.77.0/24'

# Parse `init portal` flags into PORTAL_INIT_* globals.
_portal_parse_init_flags() {
    PORTAL_INIT_PUBLIC_IP=''
    PORTAL_INIT_PORT=''
    PORTAL_INIT_SUBNET=''
    PORTAL_INIT_IFACE=''
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --public-ip=*) PORTAL_INIT_PUBLIC_IP="${arg#*=}" ;;
            --port=*)      PORTAL_INIT_PORT="${arg#*=}" ;;
            --subnet=*)    PORTAL_INIT_SUBNET="${arg#*=}" ;;
            --iface=*)     PORTAL_INIT_IFACE="${arg#*=}" ;;
            *) die "init portal: unknown flag '${arg}'" ;;
        esac
    done
}

# Given an IPv4 CIDR like 10.77.77.0/24, print the first host with the same
# prefix length: 10.77.77.1/24.
_portal_subnet_to_server_ip() {
    local subnet="$1"
    local base="${subnet%/*}" mask="${subnet#*/}"
    printf '%s.1/%s\n' "${base%.*}" "${mask}"
}

# Render /etc/wireguard/wg0.conf from the declarative state in
# ${GROXY_DIR}/portal/. Inlines all .peer files from bridges/.
portal_render_wg0_conf() {
    local cfg_dir="${GROXY_DIR}/portal"
    local PUBLIC_IP='' LISTEN_PORT='' TUNNEL_SUBNET='' EGRESS_IFACE=''
    # shellcheck source=/dev/null
    source "${cfg_dir}/server.env"

    local private_key server_ip
    private_key=$(<"${cfg_dir}/private.key")
    server_ip=$(_portal_subnet_to_server_ip "${TUNNEL_SUBNET}")

    {
        cat <<EOF
# Managed by groxy ${GROXY_VERSION}. Do not edit by hand —
# changes will be overwritten on next 'groxy apply'.

[Interface]
PrivateKey = ${private_key}
Address = ${server_ip}
ListenPort = ${LISTEN_PORT}

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${EGRESS_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${EGRESS_IFACE} -j MASQUERADE
EOF
        local peer_file
        for peer_file in "${cfg_dir}"/bridges/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            printf '\n'
            cat "${peer_file}"
        done
    } | write_atomic /etc/wireguard/wg0.conf 600
}

# Top-level: `groxy init portal [flags]`. Idempotent.
portal_init() {
    require_root
    _portal_parse_init_flags "$@"
    require_supported_os

    if [[ -f "${GROXY_DIR}/role" ]]; then
        local current
        current=$(<"${GROXY_DIR}/role")
        if [[ "${current}" != 'portal' ]]; then
            die "this machine is already initialised as '${current}'; refusing to overwrite (run 'groxy uninstall' first)"
        fi
    fi

    apt_install wireguard iptables curl

    mkdir -p "${GROXY_DIR}/portal/bridges"
    chmod 700 "${GROXY_DIR}/portal"

    log "ensuring WG keypair in ${GROXY_DIR}/portal"
    wg_ensure_keypair "${GROXY_DIR}/portal"

    # Resolve config with priority: CLI flag > existing server.env > auto-detect.
    local PUBLIC_IP='' LISTEN_PORT='' TUNNEL_SUBNET='' EGRESS_IFACE=''
    if [[ -f "${GROXY_DIR}/portal/server.env" ]]; then
        # shellcheck source=/dev/null
        source "${GROXY_DIR}/portal/server.env"
    fi

    local public_ip="${PORTAL_INIT_PUBLIC_IP:-${PUBLIC_IP}}"
    local port="${PORTAL_INIT_PORT:-${LISTEN_PORT}}"
    local subnet="${PORTAL_INIT_SUBNET:-${TUNNEL_SUBNET:-${PORTAL_DEFAULT_SUBNET}}}"
    local iface="${PORTAL_INIT_IFACE:-${EGRESS_IFACE}}"

    if [[ -z "${public_ip}" ]]; then
        log "auto-detecting public IPv4"
        public_ip=$(detect_public_ip) \
            || die "could not detect public IP; rerun with --public-ip=<ip>"
    fi
    if [[ -z "${port}" ]]; then
        port=$(pick_random_port)
    fi
    if [[ -z "${iface}" ]]; then
        iface=$(detect_default_iface)
        [[ -n "${iface}" ]] \
            || die "could not detect default egress interface; rerun with --iface=<name>"
    fi

    log "config: PUBLIC_IP=${public_ip} PORT=${port} SUBNET=${subnet} IFACE=${iface}"
    write_atomic "${GROXY_DIR}/portal/server.env" 600 <<EOF
PUBLIC_IP=${public_ip}
LISTEN_PORT=${port}
TUNNEL_SUBNET=${subnet}
EGRESS_IFACE=${iface}
EOF

    write_atomic "${GROXY_DIR}/role" 644 <<<'portal'
    write_atomic "${GROXY_DIR}/version" 644 <<<"${GROXY_VERSION}"

    log "enabling IPv4 forwarding"
    sysctl_set net.ipv4.ip_forward 1

    log "rendering /etc/wireguard/wg0.conf"
    portal_render_wg0_conf

    log "starting wg-quick@wg0"
    wg_quick_enable_restart wg0

    log "portal ready — endpoint ${public_ip}:${port}"
    log "next: 'groxy portal add-bridge <name>' to enroll a bridge"
}
