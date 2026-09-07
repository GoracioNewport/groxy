#!/usr/bin/env bash
# Контракт бэкапа состояния. Запуск: bash tests/backup.sh
#
# Главное, что здесь проверяется, — что негодный архив не объявляется годным.
# Бэкап, о непригодности которого узнают в момент восстановления, хуже, чем
# отсутствие бэкапа: на него рассчитывали.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
export GROXY_DIR="${TMPROOT}/groxy"
export GROXY_WG_DIR="${TMPROOT}/wg"
export GROXY_BACKUP_DIR="${TMPROOT}/backups"
export GROXY_BACKUP_KEEP=3
mkdir -p "${GROXY_WG_DIR}"
GROXY_VERSION='test'

fake_key() { printf 'fakekey%036d=' "$1"; }

mkdir -p "${GROXY_DIR}/bridge/wg0/clients"
printf 'bridge\n' > "${GROXY_DIR}/role"
printf '%s\n' "$(fake_key 900)" > "${GROXY_DIR}/bridge/private.key"
printf '%s\n' "$(fake_key 901)" > "${GROXY_DIR}/bridge/wg0/private.key"
for n in 1 2 3; do
    cat > "${GROXY_DIR}/bridge/wg0/clients/client${n}.peer" <<EOF
PSK=$(fake_key $((600 + n)))
ADDR=10.66.66.$((n + 1))
PUBLIC_KEY=$(fake_key ${n})
EOF
done

# shellcheck source=/dev/null
source "${REPO}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/system.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/backup.sh"

require_root() { :; }
acquire_state_lock() { :; }

pass=0; fail=0
check() {
    local what="$1" want="$2" got="$3"
    if [[ "${want}" == "${got}" ]]; then
        printf '  ok   %s\n' "${what}"; pass=$((pass + 1))
    else
        printf '  FAIL %s: want %q, got %q\n' "${what}" "${want}" "${got}"
        fail=$((fail + 1))
    fi
}

archives() { find "${GROXY_BACKUP_DIR}" -maxdepth 1 -name 'groxy-*.tar.gz' | wc -l | tr -d ' '; }

echo "== обычный снимок =="
( groxy_backup ) >/dev/null 2>&1; rc=$?
check "код возврата" 0 "${rc}"
check "архив появился" 1 "$(archives)"
check "каталог закрыт от чужих" 700 "$(stat -f '%Lp' "${GROXY_BACKUP_DIR}" 2>/dev/null || stat -c '%a' "${GROXY_BACKUP_DIR}")"
one=$(find "${GROXY_BACKUP_DIR}" -name 'groxy-*.tar.gz' | head -1)
# Внутри приватные ключи интерфейсов и преобщие ключи всех пиров.
check "архив закрыт от чужих" 600 "$(stat -f '%Lp' "${one}" 2>/dev/null || stat -c '%a' "${one}")"

echo "== архив действительно распаковывается =="
out="${TMPROOT}/unpacked"
mkdir -p "${out}"
tar -xzf "${one}" -C "${out}"
check "роль на месте" bridge "$(cat "${out}/groxy/role")"
check "все пиры на месте" 3 \
    "$(find "${out}/groxy/bridge/wg0/clients" -name '*.peer' | wc -l | tr -d ' ')"
check "приватный ключ wg0 читается" "$(fake_key 901)" \
    "$(cat "${out}/groxy/bridge/wg0/private.key")"

echo "== незаконченный архив не остаётся под настоящим именем =="
check "мусора нет" 0 \
    "$(find "${GROXY_BACKUP_DIR}" -name '*.partial' | wc -l | tr -d ' ')"

echo "== проверка ловит расхождение по числу пиров =="
# Архив, снятый не с того состояния или на середине правки. Принять его молча
# значит узнать о беде при восстановлении, когда часть людей не найдёт себя.
( _backup_verify "${one}" bridge 99 ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"

echo "== проверка ловит чужую роль =="
( _backup_verify "${one}" portal 3 ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"

echo "== проверка ловит битый ключ =="
# Обрезанный файл существует и читается, но интерфейс из него не поднимется.
printf 'обрезано\n' > "${GROXY_DIR}/bridge/wg0/private.key"
( groxy_backup ) >/dev/null 2>&1; rc=$?
check "снимок отвергнут" 1 "${rc}"
check "негодный архив не сохранён" 1 "$(archives)"
check "и не остался обрезком" 0 \
    "$(find "${GROXY_BACKUP_DIR}" -name '*.partial' | wc -l | tr -d ' ')"
printf '%s\n' "$(fake_key 901)" > "${GROXY_DIR}/bridge/wg0/private.key"

echo "== проверка ловит нераспаковываемый архив =="
broken="${TMPROOT}/broken.tar.gz"
printf 'это не архив' > "${broken}"
( _backup_verify "${broken}" bridge 3 ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"

echo "== старые архивы убираются =="
for n in 1 2 3 4; do
    ( groxy_backup ) >/dev/null 2>&1
    # Имена содержат секунды, поэтому между снимками нужна пауза.
    sleep 1
done
check "осталось не больше заданного" 3 "$(archives)"

echo "== состояние без роли не бэкапится =="
mv "${GROXY_DIR}/role" "${TMPROOT}/role.bak"
( groxy_backup ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"
mv "${TMPROOT}/role.bak" "${GROXY_DIR}/role"

echo
echo "прошло: ${pass}, упало: ${fail}"
rm -rf "${TMPROOT}"
[[ ${fail} -eq 0 ]]
