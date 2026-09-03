#!/usr/bin/env bash
# Контракт add/remove/list-client, на который опирается бот.
#
# Проверяется без root и без WireGuard: состояние живёт во временном
# каталоге через GROXY_DIR, внешние вызовы подменены. Запуск:
#   bash tests/bridge-clients.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
export GROXY_DIR="${TMPROOT}/groxy"
GROXY_VERSION='test'

mkdir -p "${GROXY_DIR}/bridge/wg0/clients"
cat > "${GROXY_DIR}/bridge/wg0/server.env" <<EOF
SUBNET=10.66.66.0/24
LISTEN_PORT=51820
PUBLIC_IP=203.0.113.1
EOF
printf 'fakeserverprivatekey000000000000000000000000=\n' \
    > "${GROXY_DIR}/bridge/wg0/private.key"
printf 'fakeserverpublickey0000000000000000000000000=\n' \
    > "${GROXY_DIR}/bridge/wg0/public.key"

# shellcheck source=/dev/null
source "${REPO}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/wireguard.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/system.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/bridge_wg0.sh"

# --- подмены внешнего мира ------------------------------------------------
require_root() { :; }
acquire_state_lock() { :; }   # /run недоступен вне root
wg_sync_peers() { :; }
bridge_render_wg0_conf() { :; }
apt_install() { :; }
_n=0
wg() {
    case "$1" in
        genkey|genpsk) _n=$((_n + 1)); printf 'fakekey%036d=\n' "${_n}" ;;
        pubkey)        cat >/dev/null; _n=$((_n + 1))
                       printf 'fakepub%036d=\n' "${_n}" ;;
        *) : ;;
    esac
}

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

echo "== создание клиента =="
out=$(bridge_add_client alpha 2>/dev/null); rc=$?
check "код возврата" 0 "${rc}"
check "выдан первый свободный адрес" 1 \
    "$(grep -c 'Address = 10.66.66.2/32' <<<"${out}")"
check "файл пира создан" 1 \
    "$(find "${GROXY_DIR}/bridge/wg0/clients" -name 'alpha.peer' | wc -l | tr -d ' ')"

echo "== повторное создание того же имени =="
# Подоболочка обязательна: die_code вызывает exit, и без неё он завершил бы
# сам тест вместо проверяемой функции.
( bridge_add_client alpha ) >/dev/null 2>&1; rc=$?
check "отдельный код 3, а не общий 1" 3 "${rc}"

echo "== следующий клиент получает следующий адрес =="
out=$(bridge_add_client beta 2>/dev/null)
check "адрес .3" 1 "$(grep -c 'Address = 10.66.66.3/32' <<<"${out}")"

echo "== --json =="
out=$(bridge_add_client gamma --json 2>/dev/null)
check "ровно одна строка" 1 "$(wc -l <<<"${out}" | tr -d ' ')"
check "есть поле config_b64" 1 "$(grep -c 'config_b64' <<<"${out}")"
decoded=$(sed 's/.*"config_b64":"\([^"]*\)".*/\1/' <<<"${out}" | base64 -d)
check "конфиг декодируется" 1 "$(grep -c '\[Interface\]' <<<"${decoded}")"

echo "== list-clients --json =="
out=$(bridge_list_clients --json 2>/dev/null)
check "три записи" 3 "$(grep -o '"name"' <<<"${out}" | wc -l | tr -d ' ')"
if command -v python3 >/dev/null; then
    check "валидный JSON" ok \
        "$(python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' \
            <<<"${out}" 2>/dev/null)"
fi

echo "== удаление =="
( bridge_remove_client beta --yes ) >/dev/null 2>&1; rc=$?
check "код возврата" 0 "${rc}"
check "файл исчез" 0 \
    "$(find "${GROXY_DIR}/bridge/wg0/clients" -name 'beta.peer' | wc -l | tr -d ' ')"

echo "== повторное удаление отсутствующего =="
( bridge_remove_client beta --yes ) >/dev/null 2>&1; rc=$?
check "успех, а не ошибка" 0 "${rc}"

echo
echo "прошло: ${pass}, упало: ${fail}"
rm -rf "${TMPROOT}"
[[ ${fail} -eq 0 ]]
