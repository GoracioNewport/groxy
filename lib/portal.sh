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

# Validate a bridge name. Allowed: alnum, dot, dash, underscore; 1-63 chars;
# must start with alnum (avoid leading dash that could confuse CLI parsers).
_portal_validate_name() {
    local name="$1"
    if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
        die "invalid bridge name '${name}' (allowed: [A-Za-z0-9._-], 1-63 chars, alnum first)"
    fi
}

# Validate a WireGuard public/preshared key — 32-byte base64, 44 chars
# ending in '='.
_portal_validate_pubkey() {
    local key="$1"
    if [[ ! "${key}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        die "invalid WireGuard pubkey: '${key}'"
    fi
}

# Print the "<a>.<b>.<c>." prefix of a /24-style subnet.
# 10.77.77.0/24 → 10.77.77.
_portal_subnet_base() {
    local subnet="$1" base
    base="${subnet%/*}"
    printf '%s.\n' "${base%.*}"
}

# Print the last octet of each bridge's BRIDGE_IP, one per line, ascending.
_portal_used_octets() {
    local cfg_dir="${GROXY_DIR}/portal"
    local peer_file BRIDGE_IP
    {
        for peer_file in "${cfg_dir}"/bridges/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            BRIDGE_IP=''
            # shellcheck source=/dev/null
            source "${peer_file}"
            [[ -n "${BRIDGE_IP}" ]] || continue
            printf '%s\n' "${BRIDGE_IP##*.}"
        done
    } | sort -n
}

# Print the first free last-octet in [2..254]. Exits non-zero (via die) if
# the subnet is full.
_portal_alloc_octet() {
    local used i
    used=$(_portal_used_octets)
    for ((i = 2; i <= 254; i++)); do
        if ! grep -qx "${i}" <<<"${used}"; then
            printf '%d\n' "${i}"
            return 0
        fi
    done
    die "tunnel subnet exhausted (.2-.254 all taken)"
}

# Render /etc/wireguard/wg0.conf from the declarative state in
# ${GROXY_DIR}/portal/. Skips peers without a PublicKey (pending enrollment).
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
        local peer_file name PSK BRIDGE_IP PUBLIC_KEY
        for peer_file in "${cfg_dir}"/bridges/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            name=$(basename "${peer_file}" .peer)
            PSK=''; BRIDGE_IP=''; PUBLIC_KEY=''
            # shellcheck source=/dev/null
            source "${peer_file}"
            [[ -n "${PUBLIC_KEY}" ]] || continue
            cat <<EOF

# bridge: ${name}
[Peer]
PublicKey = ${PUBLIC_KEY}
PresharedKey = ${PSK}
AllowedIPs = ${BRIDGE_IP}/32
EOF
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

# `groxy portal add-bridge <name> [--portal-name=<friendly-name>]`.
# Generates a PSK, allocates the next free BRIDGE_IP, writes a pending peer
# file, and prints the portal profile to stdout. wg0.conf is NOT touched —
# the peer becomes active only after `accept-bridge`.
portal_add_bridge() {
    require_root
    local arg name='' portal_name=''
    for arg in "$@"; do
        case "${arg}" in
            --portal-name=*) portal_name="${arg#*=}" ;;
            --*) die "portal add-bridge: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "portal add-bridge: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]] \
        || die "usage: groxy portal add-bridge <name> [--portal-name=<friendly-name>]"
    _portal_validate_name "${name}"

    local cfg_dir="${GROXY_DIR}/portal"
    [[ -f "${cfg_dir}/server.env" ]] \
        || die "portal not initialised — run 'groxy init portal' first"

    local peer_file="${cfg_dir}/bridges/${name}.peer"
    if [[ -e "${peer_file}" ]]; then
        die "bridge '${name}' already exists; remove first via 'portal remove-bridge ${name}'"
    fi

    local PUBLIC_IP='' LISTEN_PORT='' TUNNEL_SUBNET='' EGRESS_IFACE=''
    # shellcheck source=/dev/null
    source "${cfg_dir}/server.env"

    local octet subnet_base bridge_ip portal_ip psk portal_pubkey
    octet=$(_portal_alloc_octet)
    subnet_base=$(_portal_subnet_base "${TUNNEL_SUBNET}")
    bridge_ip="${subnet_base}${octet}"
    portal_ip="${subnet_base}1"
    psk=$(wg genpsk)
    portal_pubkey=$(<"${cfg_dir}/public.key")
    : "${portal_name:=$(hostname -s)}"

    write_atomic "${peer_file}" 600 <<EOF
# bridge "${name}" — generated by groxy ${GROXY_VERSION}
PSK=${psk}
BRIDGE_IP=${bridge_ip}
PUBLIC_KEY=
EOF

    log "registered bridge '${name}' with ${bridge_ip} (pending pubkey)"
    log "передай portal profile ниже на bridge через защищённый канал — внутри PSK"

    cat <<EOF
# groxy portal profile v1
PORTAL_NAME=${portal_name}
PORTAL_ENDPOINT=${PUBLIC_IP}
PORTAL_PORT=${LISTEN_PORT}
PORTAL_PUBKEY=${portal_pubkey}
PSK=${psk}
TUNNEL_SUBNET=${TUNNEL_SUBNET}
TUNNEL_PORTAL_IP=${portal_ip}
TUNNEL_BRIDGE_IP=${bridge_ip}
EOF
}

# `groxy portal accept-bridge <name> --pubkey=<key>`. Fills in the bridge's
# public key, re-renders wg0.conf, and restarts wg-quick@wg0. Refuses to
# overwrite a different pubkey already on file (call remove-bridge first).
portal_accept_bridge() {
    require_root
    local arg name='' pubkey=''
    for arg in "$@"; do
        case "${arg}" in
            --pubkey=*) pubkey="${arg#*=}" ;;
            --*) die "portal accept-bridge: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "portal accept-bridge: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]]   || die "usage: groxy portal accept-bridge <name> --pubkey=<key>"
    [[ -n "${pubkey}" ]] || die "missing --pubkey=<key>"
    _portal_validate_name "${name}"
    _portal_validate_pubkey "${pubkey}"

    local peer_file="${GROXY_DIR}/portal/bridges/${name}.peer"
    [[ -e "${peer_file}" ]] \
        || die "bridge '${name}' not registered; run 'portal add-bridge ${name}' first"

    local PSK='' BRIDGE_IP='' PUBLIC_KEY=''
    # shellcheck source=/dev/null
    source "${peer_file}"

    if [[ -n "${PUBLIC_KEY}" && "${PUBLIC_KEY}" != "${pubkey}" ]]; then
        die "bridge '${name}' already has a different pubkey; 'remove-bridge ${name}' first to re-key"
    fi

    write_atomic "${peer_file}" 600 <<EOF
# bridge "${name}" — generated by groxy ${GROXY_VERSION}
PSK=${PSK}
BRIDGE_IP=${BRIDGE_IP}
PUBLIC_KEY=${pubkey}
EOF

    log "activating bridge '${name}' (${BRIDGE_IP})"
    portal_render_wg0_conf
    wg_quick_enable_restart wg0
    log "bridge '${name}' active — wg-quick@wg0 reloaded"
}

# `groxy portal list-bridges`. Prints a table: name, BRIDGE_IP, status
# (active vs pending pubkey).
portal_list_bridges() {
    require_root
    local cfg_dir="${GROXY_DIR}/portal"
    [[ -d "${cfg_dir}/bridges" ]] \
        || die "portal not initialised — run 'groxy init portal' first"

    printf '%-20s %-15s %s\n' 'NAME' 'BRIDGE_IP' 'STATUS'
    local peer_file name PSK BRIDGE_IP PUBLIC_KEY status
    for peer_file in "${cfg_dir}"/bridges/*.peer; do
        [[ -e "${peer_file}" ]] || continue
        name=$(basename "${peer_file}" .peer)
        PSK=''; BRIDGE_IP=''; PUBLIC_KEY=''
        # shellcheck source=/dev/null
        source "${peer_file}"
        status='pending'
        [[ -n "${PUBLIC_KEY}" ]] && status='active'
        printf '%-20s %-15s %s\n' "${name}" "${BRIDGE_IP}" "${status}"
    done
}

# `groxy portal remove-bridge <name> [--yes]`. Deletes the peer file,
# re-renders wg0.conf, restarts wg-quick. The --yes flag is accepted for
# CLI consistency; v1 has no interactive confirmation step.
portal_remove_bridge() {
    require_root
    local arg name=''
    for arg in "$@"; do
        case "${arg}" in
            --yes) ;;
            --*) die "portal remove-bridge: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "portal remove-bridge: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]] || die "usage: groxy portal remove-bridge <name> [--yes]"
    _portal_validate_name "${name}"

    local peer_file="${GROXY_DIR}/portal/bridges/${name}.peer"
    [[ -e "${peer_file}" ]] || die "bridge '${name}' not registered"

    rm -f "${peer_file}"
    log "removed bridge '${name}'"

    portal_render_wg0_conf
    wg_quick_enable_restart wg0
    log "wg-quick@wg0 reloaded"
}
