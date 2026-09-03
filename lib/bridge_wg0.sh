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
    local peer_file addr i used
    used=$(
        for peer_file in "${cfg_dir}"/clients/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            addr=$(peer_field "${peer_file}" ADDR)
            [[ -n "${addr}" ]] && printf '%s\n' "${addr##*.}"
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

# Привести правила фаервола wg0 к желаемому виду, не трогая интерфейс.
#
# Эти же две команды стоят в PostUp шаблона wg0.conf, и текст обязан совпадать
# дословно, иначе проверка -C не найдёт живое правило и появится дубль. Держать
# их в двух местах приходится потому, что PostUp обязан быть самодостаточным:
# wg-quick поднимает интерфейс и без groxy.
#
# Нужны здесь потому, что apply больше не перезапускает wg0, а syncconf PostUp
# не выполняет — проверено на бридже: `wg-quick strip wg0` отдаёт интерфейс и
# пиров, но ни одной строки PostUp. Без этой сверки reconciler печатал бы
# «apply complete», не восстановив ни MSS-клэмпа, ни MASQUERADE.
bridge_ensure_wg0_rules() {
    local subnet="$1"

    iptables -t nat -C POSTROUTING -s "${subnet}" ! -o wg1 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "${subnet}" ! -o wg1 -j MASQUERADE \
        || die "failed to install the MASQUERADE rule for ${subnet}"

    iptables -t mangle -C FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320 2>/dev/null \
        || iptables -t mangle -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320 \
        || die "failed to install the MSS clamp"
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

    # Собирается во временный файл, а не через конвейер в write_atomic.
    # С конвейером `die` из цикла убивал только левую подоболочку, а
    # write_atomic справа спокойно дочитывал оборванный поток, ставил права и
    # переименовывал его на место: один испорченный файл пира давал wg0.conf с
    # одним клиентом вместо тридцати шести, и wg-quick такой файл принимал.
    # Отказ был громким, а конфиг всё равно подменялся.
    local tmp
    tmp=$(mktemp) || die "cannot create a temporary file for wg0.conf"

    local written_peers=0
    {
        cat <<EOF
# Managed by groxy ${GROXY_VERSION}. Do not edit by hand.

[Interface]
PrivateKey = ${private_key}
Address = ${server_ip}/${mask}
ListenPort = ${LISTEN_PORT}

# MASQUERADE client traffic when it carve-outs to egress (mark=0x0 → main
# table → not wg1). Без этого src остаётся 10.66.66.X и пакет теряется
# на первом же гетвее. Traffic that DOES go through wg1 уже MASQUERADE'ится
# его собственным POSTROUTING правилом, поэтому исключаем wg1.
PostUp = iptables -t nat -A POSTROUTING -s ${SUBNET} ! -o wg1 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${SUBNET} ! -o wg1 -j MASQUERADE 2>/dev/null || true

# MSS-клэмп. Путь клиент → bridge → portal вкладывает один туннель в
# другой, и полноразмерный сегмент не проходит: соединение открывается,
# а потом виснет на первом большом ответе. Клэмп правит MSS в SYN, чтобы
# отправитель сам не превышал размер.
#
# На проде это правило с мая жило только в рантайме и в репозиторий не
# попадало — переустановка бриджа молча теряла его.
#
# Таблица именно mangle: на moscow-1000-01 правило стоит в mangle FORWARD и
# через него прошло 20 млн пакетов, а filter FORWARD пуст. Без -t iptables
# пишет в filter, и тогда guard ниже проверяет не ту таблицу, а на узле
# оказываются два клэмпа — живой в mangle вне управления groxy и второй в
# filter. Отсутствие фильтра по интерфейсу тоже воспроизводит прод: этот узел
# форвардит только туннельный трафик.
#
# Добавление через -C ... || -A, потому что правило на проде уже стоит:
# безусловный -A при первом же полном рестарте wg0 создал бы дубль, а
# PostDown снял бы только один.
PostUp = iptables -t mangle -C FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320 2>/dev/null || iptables -t mangle -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320
PostDown = iptables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320 2>/dev/null || true
EOF
        # Every field is validated before it reaches the config. A peer file
        # with a missing ADDR used to render `AllowedIPs = /32`, which wg
        # rejects — and it rejects the WHOLE file, so one damaged peer took
        # every client down rather than just itself. Refusing loudly here beats
        # writing a config that cannot load.
        local peer_file name psk addr pubkey
        for peer_file in "${cfg_dir}"/clients/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            name=$(basename "${peer_file}" .peer)
            psk=$(peer_field "${peer_file}" PSK)
            addr=$(peer_field "${peer_file}" ADDR)
            pubkey=$(peer_field "${peer_file}" PUBLIC_KEY)

            # Пропуск заменён на отказ: раньше пир с нечитаемым ключом просто
            # исчезал из конфига без единой строки в логе, а следующая
            # синхронизация снимала его с ядра. Клиент терял доступ, и никто
            # об этом не узнавал. Лучше не тронуть конфиг вовсе — старый
            # остаётся рабочим, пока человек не починит файл. Удалению это не
            # мешает: remove-client сносит файл до рендера.
            [[ -n "${pubkey}" ]] \
                || die "no readable PUBLIC_KEY in ${peer_file} — refusing to render"
            validate_wg_key "${pubkey}" "public key in ${peer_file}"
            [[ -n "${psk}" ]] && validate_wg_key "${psk}" "preshared key in ${peer_file}"
            [[ "${addr}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
                || die "invalid ADDR '${addr}' in ${peer_file}"

            written_peers=$((written_peers + 1))
            cat <<EOF

# client: ${name}
[Peer]
PublicKey = ${pubkey}
PresharedKey = ${psk}
AllowedIPs = ${addr}/32
EOF
        done
    } > "${tmp}"

    write_atomic "${GROXY_WG_DIR}/wg0.conf" 600 < "${tmp}"
    rm -f "${tmp}"
    log "rendered wg0.conf with ${written_peers} peer(s)"
}

# `groxy bridge add-client <name>`. Generates the client keypair on the
# bridge for ergonomic one-step setup, allocates an IP, writes a peer
# entry, re-renders wg0.conf, restarts wg-quick@wg0, prints the client's
# WireGuard config to stdout.
bridge_add_client() {
    require_root
    local arg name='' want_qr=0 want_json=0
    for arg in "$@"; do
        case "${arg}" in
            --qr) want_qr=1 ;;
            --json) want_json=1 ;;
            --*) die "bridge add-client: unknown flag '${arg}'" ;;
            *)
                [[ -z "${name}" ]] || die "bridge add-client: extra argument '${arg}'"
                name="${arg}"
                ;;
        esac
    done
    [[ -n "${name}" ]] || die "usage: groxy bridge add-client <name> [--qr] [--json]"
    validate_peer_name "${name}"

    # Before the lock, deliberately. apt can take tens of seconds and can block
    # on dpkg's own lock; holding the state lock through that made an unrelated
    # remove-client time out, and a failure here after the client was already
    # created reported a completed operation as a failure.
    if (( want_qr )) && ! has_command qrencode; then
        apt_install qrencode
    fi

    # Taken before the free-octet scan: the scan reads every peer file and
    # then writes one, so without the lock a concurrent run allocates the
    # same address.
    acquire_state_lock

    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    [[ -f "${cfg_dir}/server.env" ]] \
        || die "bridge not initialised — run 'groxy init bridge --portal-profile=...' first"

    local peer_file="${cfg_dir}/clients/${name}.peer"
    # A distinct status, not a generic failure: the private key is never
    # stored, so we cannot hand back a config for a client that already
    # exists. A caller that lost the response to a timeout uses this to tell
    # "the name is taken" from "something broke", and then removes and
    # recreates — safe, because a config nobody received was never used.
    [[ -e "${peer_file}" ]] && die_code "${GROXY_EXIT_EXISTS}" \
        "client '${name}' already exists; remove first with 'bridge remove-client ${name}'"

    local SUBNET='' LISTEN_PORT='' PUBLIC_IP=''
    # shellcheck source=/dev/null
    source "${cfg_dir}/server.env"

    local octet base addr psk priv pub server_pub server_ip
    # The `die` inside _bridge_wg0_alloc_octet runs in a command substitution,
    # so it only kills the subshell: without this check a full subnet produced
    # an empty octet, an ADDR of "10.66.66." and a peer whose AllowedIPs line
    # wg refuses — taking the whole config down, not just this client.
    octet=$(_bridge_wg0_alloc_octet) \
        || die "could not allocate an address in ${SUBNET}"
    [[ "${octet}" =~ ^[0-9]+$ ]] \
        || die "address allocation returned '${octet}' — subnet ${SUBNET} may be exhausted"
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
    wg_sync_peers wg0

    # An empty public.key reads successfully and yields a config with a blank
    # PublicKey — accepted silently and handed out as working. wg_ensure_keypair
    # can leave one behind if it is interrupted, so check rather than trust.
    server_pub=$(<"${cfg_dir}/public.key")
    validate_wg_key "${server_pub}" "server public key (${cfg_dir}/public.key)"
    server_ip=$(_bridge_wg0_server_ip "${SUBNET}")

    # Client config — DNS=bridge's wg0 IP так что whitelist через dnsmasq
    # будет работать.
    local client_conf
    printf -v client_conf '# groxy client config — "%s"
[Interface]
PrivateKey = %s
Address = %s/32
DNS = %s

[Peer]
PublicKey = %s
PresharedKey = %s
Endpoint = %s:%s
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
' "${name}" "${priv}" "${addr}" "${server_ip}" "${server_pub}" "${psk}" "${PUBLIC_IP}" "${LISTEN_PORT}"
    if (( want_json )); then
        # The config is carried base64-encoded: it is multi-line and contains
        # characters that would need escaping, and a caller decoding one field
        # beats a caller unescaping a string.
        #
        # Encoded into a variable first, and checked. Inline in the printf
        # argument, a failing base64 produced an empty config_b64 while printf
        # itself still returned 0 — valid JSON, successful exit, and a user
        # handed an empty file for a client that now exists and cannot be
        # recreated under the same name.
        local encoded
        encoded=$(printf '%s' "${client_conf}" | base64 -w0) \
            || die "failed to encode the client config"
        [[ -n "${encoded}" ]] || die "encoded client config is empty"
        printf '{"name":"%s","address":"%s","config_b64":"%s"}\n' \
            "${name}" "${addr}" "${encoded}"
    else
        printf '%s' "${client_conf}"
    fi

    if (( want_qr )); then
        # qrencode уже поставлен выше, до захвата блокировки.
        # ANSI-UTF8 QR в stderr — не загрязняет stdout (если юзер делает > file.conf).
        printf '%s' "${client_conf}" | qrencode -t ansiutf8 >&2
    fi
}

# `groxy bridge list-clients`.
bridge_list_clients() {
    require_root
    local arg want_json=0
    for arg in "$@"; do
        case "${arg}" in
            --json) want_json=1 ;;
            *) die "bridge list-clients: unknown argument '${arg}'" ;;
        esac
    done

    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    [[ -d "${cfg_dir}/clients" ]] \
        || die "bridge not initialised — run 'groxy init bridge --portal-profile=...' first"

    local peer_file name addr pubkey sep=''
    if (( want_json )); then
        # add-client only ever creates names that pass validate_peer_name, but
        # files also arrive in this directory by other routes — a restore from
        # backup, an rsync from an old node, a hand edit. A file literally named
        # `ev"il.peer` produced `{"name":"ev"il",...}` and broke parsing of the
        # entire list, so the name is checked on the way OUT, not only in.
        printf '['
        for peer_file in "${cfg_dir}"/clients/*.peer; do
            [[ -e "${peer_file}" ]] || continue
            name=$(basename "${peer_file}" .peer)
            if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
                log "warning: skipping '${peer_file}' — name is not a valid peer name"
                continue
            fi
            addr=$(peer_field "${peer_file}" ADDR)
            pubkey=$(peer_field "${peer_file}" PUBLIC_KEY)
            if [[ ! "${addr}" =~ ^[0-9.]*$ ]] || [[ ! "${pubkey}" =~ ^[A-Za-z0-9+/=]*$ ]]; then
                log "warning: skipping '${peer_file}' — field would not be safe in JSON"
                continue
            fi
            printf '%s{"name":"%s","address":"%s","public_key":"%s"}' \
                "${sep}" "${name}" "${addr}" "${pubkey}"
            sep=','
        done
        printf ']\n'
        return 0
    fi

    printf '%-20s %s\n' 'NAME' 'ADDR'
    for peer_file in "${cfg_dir}"/clients/*.peer; do
        [[ -e "${peer_file}" ]] || continue
        name=$(basename "${peer_file}" .peer)
        addr=$(peer_field "${peer_file}" ADDR)
        printf '%-20s %s\n' "${name}" "${addr}"
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
    acquire_state_lock

    local cfg_dir="${GROXY_DIR}/bridge/wg0"
    [[ -f "${cfg_dir}/server.env" ]] \
        || die "bridge not initialised — run 'groxy init bridge --portal-profile=...' first"

    local peer_file="${cfg_dir}/clients/${name}.peer"

    # Absent is success, not an error — the desired end state already holds.
    # But state lives in three places, not one: the peer file, wg0.conf and the
    # kernel. Judging by the file alone and returning early was wrong: a first
    # run that deleted the file and then died left the peer still live in the
    # kernel, and the retry cheerfully reported success without revoking
    # anything. So reconcile unconditionally and let the sync be the thing that
    # decides we are done.
    if [[ -e "${peer_file}" ]]; then
        rm -f "${peer_file}"
        log "removed client '${name}'"
    else
        log "client '${name}' not present — reconciling anyway"
    fi

    bridge_render_wg0_conf
    wg_sync_peers wg0
}
