#!/usr/bin/env bash
# Bridge wg0 — angristan-style WireGuard server for end-user clients.
# Sourced by the dispatcher; do not execute directly.
#
# wg0 lives on a separate subnet from the portal-side tunnel to avoid the
# "kernel treats client IP as local" gotcha documented in 01-TECHNICAL-
# SUMMARY.md #1. Default is 10.66.66.0/24; portal uses 10.77.77.0/24.

readonly BRIDGE_DEFAULT_WG0_SUBNET='10.66.66.0/24'

# Ensure wg0 server keypair and server.env exist in
# ${GROXY_DIR}/bridge/wg0/. Auto-detects bridge public IP for the client
# endpoint hint, then persists it.
bridge_init_wg0() {
    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    mkdir -p "${cfg_dir}/clients"
    chmod 700 "${cfg_dir}"

    log "ensuring wg0 keypair in ${cfg_dir}"
    wg_ensure_keypair "${cfg_dir}"

    local SUBNET='' LISTEN_PORT='' PUBLIC_IP=''
    if [[ -f "${cfg_dir}/server.env" ]]; then
        # shellcheck source=/dev/null
        source "${cfg_dir}/server.env"
    fi
    [[ -n "${SUBNET}" ]]      || SUBNET="${BRIDGE_DEFAULT_WG0_SUBNET}"
    [[ -n "${LISTEN_PORT}" ]] || LISTEN_PORT=$(pick_random_port)
    if [[ -z "${PUBLIC_IP}" ]]; then
        log "auto-detecting bridge public IPv4"
        PUBLIC_IP=$(detect_public_ip) \
            || die "could not detect bridge public IP — set PUBLIC_IP manually in ${cfg_dir}/server.env"
    fi

    write_atomic "${cfg_dir}/server.env" 600 <<EOF
SUBNET=${SUBNET}
LISTEN_PORT=${LISTEN_PORT}
PUBLIC_IP=${PUBLIC_IP}
EOF
}

# Print the "<a>.<b>.<c>." prefix of the wg0 /24 subnet plus the server's
# host octet (.1). Returns the bridge wg0 IP and the prefix base separately.
_bridge_wg0_server_ip() {
    local subnet="$1" base
    base="${subnet%/*}"
    printf '%s.1\n' "${base%.*}"
}

# Print the "<a>.<b>.<c>." prefix (with trailing dot).
_bridge_wg0_base() {
    local subnet="$1" base
    base="${subnet%/*}"
    printf '%s.\n' "${base%.*}"
}

# Print first free last-octet in [2..254] not used by any client.
_bridge_wg0_alloc_octet() {
    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    local peer_file ADDR i used
    used=$(
        for peer_file in "${cfg_dir}"/clients/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            ADDR=''
            # shellcheck source=/dev/null
            source "${peer_file}"
            [[ -n "${ADDR}" ]] && printf '%s\n' "${ADDR##*.}"
        done | sort -n
    )
    for ((i = 2; i <= 254; i++)); do
        if ! grep -qx "${i}" <<<"${used}"; then
            printf '%d\n' "${i}"
            return 0
        fi
    done
    die "wg0 subnet exhausted (.2-.254 taken)"
}

# Render /etc/wireguard/wg0.conf from server.env + clients/*.peer.
# Server has no PostUp — routing happens at wg1 level. wg0 is just the
# kernel-side WG socket that clients hit.
bridge_render_wg0_conf() {
    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    local SUBNET='' LISTEN_PORT='' PUBLIC_IP=''
    # shellcheck source=/dev/null
    source "${cfg_dir}/server.env"

    local private_key server_ip mask
    private_key=$(<"${cfg_dir}/private.key")
    server_ip=$(_bridge_wg0_server_ip "${SUBNET}")
    mask="${SUBNET#*/}"

    {
        cat <<EOF
# Managed by groxy ${GROXY_VERSION}. Do not edit by hand.

[Interface]
PrivateKey = ${private_key}
Address = ${server_ip}/${mask}
ListenPort = ${LISTEN_PORT}
EOF
        local peer_file name PSK ADDR PUBLIC_KEY
        for peer_file in "${cfg_dir}"/clients/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            name=$(basename "${peer_file}" .peer)
            PSK=''; ADDR=''; PUBLIC_KEY=''
            # shellcheck source=/dev/null
            source "${peer_file}"
            [[ -n "${PUBLIC_KEY}" ]] || continue
            cat <<EOF

# client: ${name}
[Peer]
PublicKey = ${PUBLIC_KEY}
PresharedKey = ${PSK}
AllowedIPs = ${ADDR}/32
EOF
        done
    } | write_atomic /etc/wireguard/wg0.conf 600
}

# `groxy bridge add-client <name>`. Generates the client keypair on the
# bridge for ergonomic one-step setup, allocates an IP, writes a peer
# entry, re-renders wg0.conf, restarts wg-quick@wg0, prints the client's
# WireGuard config to stdout.
bridge_add_client() {
    require_root
    local arg name=''
    for arg in "$@"; do
        case "${arg}" in
            --*) die "bridge add-client: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "bridge add-client: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]] || die "usage: groxy bridge add-client <name>"
    validate_peer_name "${name}"

    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    [[ -f "${cfg_dir}/server.env" ]] \
        || die "bridge not initialised — run 'groxy init bridge --portal-profile=...' first"

    local peer_file="${cfg_dir}/clients/${name}.peer"
    [[ -e "${peer_file}" ]] && die "client '${name}' already exists; remove first with 'bridge remove-client ${name}'"

    local SUBNET='' LISTEN_PORT='' PUBLIC_IP=''
    # shellcheck source=/dev/null
    source "${cfg_dir}/server.env"

    local octet base addr psk priv pub server_pub server_ip
    octet=$(_bridge_wg0_alloc_octet)
    base=$(_bridge_wg0_base "${SUBNET}")
    addr="${base}${octet}"
    psk=$(wg genpsk)
    priv=$(wg genkey)
    pub=$(printf '%s' "${priv}" | wg pubkey)

    write_atomic "${peer_file}" 600 <<EOF
# client "${name}" — generated by groxy ${GROXY_VERSION}
PSK=${psk}
ADDR=${addr}
PUBLIC_KEY=${pub}
EOF

    log "added client '${name}' (${addr})"
    bridge_render_wg0_conf
    wg_quick_enable_restart wg0
    log "wg-quick@wg0 reloaded"

    server_pub=$(<"${cfg_dir}/public.key")
    server_ip=$(_bridge_wg0_server_ip "${SUBNET}")

    # Client config — DNS=bridge's wg0 IP так что whitelist через dnsmasq
    # будет работать (когда dnsmasq поднимется в следующем checkpoint'е).
    cat <<EOF
# groxy client config — "${name}"
[Interface]
PrivateKey = ${priv}
Address = ${addr}/32
DNS = ${server_ip}

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${PUBLIC_IP}:${LISTEN_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}

# `groxy bridge list-clients`.
bridge_list_clients() {
    require_root
    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    [[ -d "${cfg_dir}/clients" ]] \
        || die "bridge not initialised — run 'groxy init bridge --portal-profile=...' first"

    printf '%-20s %s\n' 'NAME' 'ADDR'
    local peer_file name PSK ADDR PUBLIC_KEY
    for peer_file in "${cfg_dir}"/clients/*.peer; do
        [[ -e "${peer_file}" ]] || continue
        name=$(basename "${peer_file}" .peer)
        ADDR=''
        # shellcheck source=/dev/null
        source "${peer_file}"
        printf '%-20s %s\n' "${name}" "${ADDR}"
    done
}

# `groxy bridge remove-client <name> [--yes]`. --yes is accepted for CLI
# consistency; no interactive confirmation in v1.
bridge_remove_client() {
    require_root
    local arg name=''
    for arg in "$@"; do
        case "${arg}" in
            --yes) ;;
            --*) die "bridge remove-client: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "bridge remove-client: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]] || die "usage: groxy bridge remove-client <name> [--yes]"
    validate_peer_name "${name}"

    local peer_file="${GROXY_DIR}/bridge/wg0/clients/${name}.peer"
    [[ -e "${peer_file}" ]] || die "client '${name}' not found"

    rm -f "${peer_file}"
    log "removed client '${name}'"
    bridge_render_wg0_conf
    wg_quick_enable_restart wg0
    log "wg-quick@wg0 reloaded"
}
