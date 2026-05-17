#!/usr/bin/env bash
# System-level helpers — OS detection, apt, sysctl, network introspection,
# atomic file writes. Sourced by the dispatcher; do not execute directly.

# Print "<id> <version>" of the host OS, lowercased. Fields fall back to
# "unknown" if /etc/os-release is missing.
detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        printf 'unknown unknown\n'
        return
    fi
    local ID='' VERSION_ID=''
    # shellcheck source=/dev/null
    . /etc/os-release
    printf '%s %s\n' "${ID,,}" "${VERSION_ID:-}"
}

# Warn loudly when the host is not Debian 12. groxy targets bookworm; other
# distros may work but aren't tested. Hard-fail policy is deliberately not
# applied — easier to relax later than to retrofit.
require_supported_os() {
    local id version
    read -r id version < <(detect_os)
    if [[ "${id}" != 'debian' || "${version}" != '12' ]]; then
        log "warning: groxy targets Debian 12 (bookworm); detected '${id} ${version}'"
    fi
}

# Install Debian packages, skipping any that are already present. No-op on
# empty argument list.
apt_install() {
    [[ $# -eq 0 ]] && return 0
    local pkg missing=()
    for pkg in "$@"; do
        if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null \
                | grep -q 'install ok installed'; then
            missing+=("${pkg}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "apt: installing ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    fi
}

# Print the name of the interface used by the default IPv4 route, or empty
# string on failure.
detect_default_iface() {
    ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}'
}

# Print the host's public IPv4 by querying a small list of services in turn.
# Returns non-zero if none responded with a valid address.
detect_public_ip() {
    local svc ip
    for svc in \
        'https://api.ipify.org' \
        'https://ifconfig.me/ip' \
        'https://ipv4.icanhazip.com'
    do
        ip=$(curl -fsS4 --max-time 3 "${svc}" 2>/dev/null || true)
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s\n' "${ip}"
            return 0
        fi
    done
    return 1
}

# Print a random port from the IANA dynamic/private range.
pick_random_port() {
    shuf -i 49152-65535 -n 1
}

# Write stdin to <path> atomically with the given mode (default 644).
# Creates the parent directory if missing.
write_atomic() {
    local dest="$1" mode="${2:-644}" tmp
    mkdir -p "$(dirname "${dest}")"
    tmp=$(mktemp "${dest}.XXXXXX")
    cat > "${tmp}"
    chmod "${mode}" "${tmp}"
    mv -f "${tmp}" "${dest}"
}

# Persist a sysctl key in /etc/sysctl.d/99-groxy.conf and apply it
# immediately. Idempotent — replaces any existing line for the same key.
sysctl_set() {
    local key="$1" value="$2" path='/etc/sysctl.d/99-groxy.conf'
    mkdir -p /etc/sysctl.d
    if [[ -f "${path}" ]]; then
        # Escape dots in the key so sed treats them as literals.
        sed -i "/^${key//./\\.}[[:space:]]*=/d" "${path}"
    fi
    printf '%s = %s\n' "${key}" "${value}" >> "${path}"
    sysctl -q -w "${key}=${value}" >/dev/null
}
