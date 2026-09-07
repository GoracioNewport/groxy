#!/usr/bin/env bash
# Бэкап состояния groxy и проверка, что он годен к восстановлению.
# Sourced by the dispatcher; do not execute directly.
#
# Всё состояние живёт в ${GROXY_DIR}: приватные ключи интерфейсов, файлы пиров
# с преобщими ключами, реестр порталов, настройки, источник списка доменов. Без
# него узел не восстанавливается — клиентам придётся выдавать новые конфиги, а
# приватные ключи клиентов не хранятся нигде и подавно.
#
# Архив остаётся на самом узле. Отправлять его куда-то — отдельное решение,
# которого никто не принимал: в нём приватные ключи, и любая копия наружу
# расширяет то, что придётся считать скомпрометированным при утечке.

readonly GROXY_BACKUP_DIR="${GROXY_BACKUP_DIR:-/var/backups/groxy}"

# Сколько архивов держать. Ежедневный таймер, две недели истории: этого хватает,
# чтобы заметить порчу состояния и откатиться, а больше — просто копии ключей,
# лежащие лишний месяц.
readonly GROXY_BACKUP_KEEP="${GROXY_BACKUP_KEEP:-14}"

# Сколько пиров сейчас в состоянии. Считается по файлам, а не по ядру:
# сверяем архив с тем, что записано на диск, а не с тем, что успело доехать
# до интерфейса.
_backup_peer_count() {
    local root="$1" role="$2" dir
    case "${role}" in
        bridge) dir="${root}/bridge/wg0/clients" ;;
        portal) dir="${root}/portal/bridges" ;;
        *)      printf '0\n'; return 0 ;;
    esac
    find "${dir}" -maxdepth 1 -name '*.peer' 2>/dev/null | wc -l | tr -d ' '
}

# Проверить, что архив действительно восстанавливается.
#
# Не «tar -t», а полная распаковка во временный каталог и сверка инвариантов.
# Список содержимого доказывает лишь то, что оглавление читается: архив, где
# файлы обрезаны или пусты, оглавление проходит и на восстановлении подводит.
# А узнать об этом в момент, когда бэкап понадобился, — это узнать поздно.
_backup_verify() {
    local archive="$1" role="$2" want_peers="$3"
    local tmp rc=0
    tmp=$(mktemp -d) || die "cannot create a temporary directory for verification"
    # shellcheck disable=SC2064  # путь подставляется сейчас, и это намеренно
    trap "rm -rf '${tmp}'" RETURN

    if ! tar -xzf "${archive}" -C "${tmp}" 2>/dev/null; then
        log "verification failed: archive does not extract"
        return 1
    fi

    local root="${tmp}/groxy"
    [[ -f "${root}/role" ]] || { log "verification failed: no role file"; return 1; }

    local got_role
    got_role=$(<"${root}/role")
    [[ "${got_role}" == "${role}" ]] \
        || { log "verification failed: role is '${got_role}', expected '${role}'"; return 1; }

    # Приватный ключ проверяется формой, а не наличием: обрезанный файл
    # существует и читается, но восстановленный из него интерфейс не поднимет
    # ни одного туннеля.
    local key_file="${root}/${role}/private.key"
    if [[ "${role}" == 'bridge' ]]; then
        # У бриджа их два: свой для wg1 и отдельный для wg0.
        _backup_check_key "${root}/bridge/private.key" || rc=1
        _backup_check_key "${root}/bridge/wg0/private.key" || rc=1
    else
        _backup_check_key "${key_file}" || rc=1
    fi
    (( rc )) && return 1

    local got_peers
    got_peers=$(_backup_peer_count "${root}" "${role}")
    if [[ "${got_peers}" != "${want_peers}" ]]; then
        # Расхождение означает, что архив снят не с того состояния или снят
        # на середине правки. Молчаливо принять его нельзя: обнаружится это
        # при восстановлении, когда часть людей просто не найдёт себя.
        log "verification failed: archive has ${got_peers} peer(s), state has ${want_peers}"
        return 1
    fi

    log "verified: role ${role}, ${got_peers} peer(s), keys readable"
    return 0
}

_backup_check_key() {
    local path="$1" key
    if [[ ! -f "${path}" ]]; then
        log "verification failed: missing ${path#*/tmp.*/}"
        return 1
    fi
    key=$(<"${path}")
    if [[ ! "${key}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        log "verification failed: ${path##*/} is not a WireGuard key"
        return 1
    fi
}

# `groxy backup [--keep=<n>]`. Снимает архив состояния, проверяет его
# распаковкой и убирает старые.
groxy_backup() {
    require_root
    # Блокировка обязательна: архив, снятый посреди add-client, содержит файл
    # пира без записи в конфиге — то есть состояние, которого никогда не было.
    acquire_state_lock

    local arg keep="${GROXY_BACKUP_KEEP}"
    for arg in "$@"; do
        case "${arg}" in
            --keep=*) keep="${arg#*=}" ;;
            --*) die "backup: unknown flag '${arg}'" ;;
            *) die "backup: unexpected argument '${arg}'" ;;
        esac
    done
    [[ "${keep}" =~ ^[0-9]+$ && "${keep}" -ge 1 ]] \
        || die "backup: --keep must be a positive number, got '${keep}'"

    [[ -f "${GROXY_DIR}/role" ]] \
        || die "groxy not initialised on this host — nothing to back up"
    local role
    role=$(<"${GROXY_DIR}/role")

    mkdir -p "${GROXY_BACKUP_DIR}"
    # 700 на каталоге и 600 на архивах: внутри приватные ключи интерфейсов и
    # преобщие ключи всех пиров. /var/backups по умолчанию читаем всем.
    chmod 700 "${GROXY_BACKUP_DIR}"

    local want_peers stamp archive
    want_peers=$(_backup_peer_count "${GROXY_DIR}" "${role}")
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    archive="${GROXY_BACKUP_DIR}/groxy-${role}-${stamp}.tar.gz"

    # Пишется во временный файл рядом и переносится на место: прерванный tar
    # оставил бы обрезанный архив с правильным именем, и следующая проверка
    # нашла бы «бэкап есть», а восстановление — нет.
    local tmp="${archive}.partial"
    if ! tar -czf "${tmp}" -C "$(dirname "${GROXY_DIR}")" "$(basename "${GROXY_DIR}")" 2>/dev/null; then
        rm -f "${tmp}"
        die "tar failed — no backup written"
    fi
    chmod 600 "${tmp}"

    if ! _backup_verify "${tmp}" "${role}" "${want_peers}"; then
        rm -f "${tmp}"
        die "backup did not verify — nothing written"
    fi

    mv -f "${tmp}" "${archive}"
    log "backup written: ${archive} ($(du -h "${archive}" | cut -f1))"

    _backup_prune "${keep}"
}

# Оставить только последние N архивов.
#
# Удаляются самые старые по имени, а не по mtime: имя содержит отметку времени
# съёмки, а mtime может измениться от чего угодно — от копирования до
# восстановления файловой системы.
_backup_prune() {
    local keep="$1" old count
    count=$(find "${GROXY_BACKUP_DIR}" -maxdepth 1 -name 'groxy-*.tar.gz' | wc -l | tr -d ' ')
    (( count <= keep )) && return 0

    while IFS= read -r old; do
        rm -f "${old}"
        log "pruned old backup: $(basename "${old}")"
    done < <(find "${GROXY_BACKUP_DIR}" -maxdepth 1 -name 'groxy-*.tar.gz' \
                | sort | head -n "$(( count - keep ))")
}

# `groxy backup list`. Что лежит и насколько свежее.
groxy_backup_list() {
    require_root
    if [[ ! -d "${GROXY_BACKUP_DIR}" ]]; then
        log "no backups yet (${GROXY_BACKUP_DIR} does not exist)"
        return 0
    fi
    local file
    printf '%-40s %8s  %s\n' 'ARCHIVE' 'SIZE' 'TAKEN'
    while IFS= read -r file; do
        printf '%-40s %8s  %s\n' \
            "$(basename "${file}")" \
            "$(du -h "${file}" | cut -f1)" \
            "$(date -r "${file}" '+%Y-%m-%d %H:%M')"
    done < <(find "${GROXY_BACKUP_DIR}" -maxdepth 1 -name 'groxy-*.tar.gz' | sort -r)
}
