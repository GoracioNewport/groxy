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
    sysctl_persist "$1" "$2"
    sysctl -q -w "$1=$2" >/dev/null
}

# Записать sysctl в /etc/sysctl.d/99-groxy.conf, НЕ применяя его сейчас.
#
# Нужно там, где ключа в /proc может ещё не быть: nf_conntrack — загружаемый
# модуль, и на свежем узле его нет до первого NAT. Попытка применить такой ключ
# завершилась бы ошибкой и под set -e уронила бы установку.
sysctl_persist() {
    local key="$1" value="$2" path='/etc/sysctl.d/99-groxy.conf'
    mkdir -p /etc/sysctl.d
    if [[ -f "${path}" ]]; then
        # Escape dots in the key so sed treats them as literals.
        sed -i "/^${key//./\\.}[[:space:]]*=/d" "${path}"
    fi
    printf '%s = %s\n' "${key}" "${value}" >> "${path}"
}

# Give conntrack enough room for a node that forwards a whole fleet.
#
# The kernel derives nf_conntrack_max from RAM at boot. On the 960 MB portal
# that lands at 8192 — and every foreign connection of every client crosses
# that one node. A page of images opens hundreds of connections per client, so
# a few people browsing at once can fill the table; once full, new connections
# are dropped and it looks to the user like the internet stopped.
#
# Cost is roughly 330 bytes per entry, so 65536 entries is about 21 MB —
# affordable even on the small portal. The hash table is sized to match:
# raising the ceiling alone only makes the chains longer.
#
# Idempotent, and a no-op on kernels where conntrack is not loaded.
ensure_conntrack_capacity() {
    local want=65536
    local max_path='/proc/sys/net/netfilter/nf_conntrack_max'
    local hash_path='/sys/module/nf_conntrack/parameters/hashsize'

    # Файлы пишутся ПЕРВЫМИ и безусловно. Раньше выше стоял ранний выход по
    # читаемости /proc-ключа, а init обеих ролей зовёт эту функцию до того, как
    # wg-quick поднимет NAT и подтянет nf_conntrack. На чистом узле ключа ещё
    # нет — и не писалось ни одного из трёх файлов, то есть ровно в сценарии
    # «разворачиваем новый портал» настройка не применялась вовсе.

    # Загрузка модуля на старте. Без неё nf_conntrack появляется только когда
    # что-то запросит NAT, то есть много позже systemd-sysctl: ключа на момент
    # применения не существует, и запись в sysctl.d молча пропадает.
    # systemd-sysctl упорядочен после systemd-modules-load, поэтому загрузка
    # здесь делает sysctl применимым.
    write_atomic /etc/modules-load.d/99-groxy-conntrack.conf 644 <<EOF
# Managed by groxy ${GROXY_VERSION}. Do not edit by hand.
nf_conntrack
EOF

    write_atomic /etc/modprobe.d/99-groxy-conntrack.conf 644 <<EOF
# Managed by groxy ${GROXY_VERSION}. Do not edit by hand.
options nf_conntrack hashsize=${want}
EOF

    # Потолок пишется ВСЕГДА, а не только когда он ниже желаемого.
    #
    # Явный hashsize меняет то, как ядро выводит nf_conntrack_max при загрузке
    # модуля: множитель остаётся равным восьми, и вместо 65536 получается
    # 524288 — на узле с 960 МБ это около 170 МБ вместо 21. Раньше строка не
    # писалась, если текущее значение уже равнялось желаемому, и тогда после
    # перезагрузки вернуть потолок было некому.
    sysctl_persist net.netfilter.nf_conntrack_max "${want}"

    # Живое применение — только если ядро уже знает про conntrack.
    [[ -r "${max_path}" ]] || return 0

    local current
    current=$(<"${max_path}")
    if [[ "${current}" =~ ^[0-9]+$ ]] && (( current != want )); then
        log "setting nf_conntrack_max ${current} -> ${want}"
        sysctl -q -w "net.netfilter.nf_conntrack_max=${want}" >/dev/null || true
    fi

    if [[ -w "${hash_path}" ]]; then
        local buckets
        buckets=$(<"${hash_path}")
        if [[ "${buckets}" =~ ^[0-9]+$ ]] && (( buckets < want )); then
            printf '%s\n' "${want}" > "${hash_path}" || true
        fi
    fi
}
