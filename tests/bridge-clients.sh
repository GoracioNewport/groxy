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
# Ключи обязаны иметь настоящую форму: 43 символа base64 плюс '='. Валидация
# ключа сервера в add-client отвергает произвольную строку, и должна — именно
# пустой или обрезанный public.key раньше уезжал в выданный клиенту конфиг.
fake_key() { printf 'fakekey%036d=\n' "$1"; }
fake_key 900 > "${GROXY_DIR}/bridge/wg0/private.key"
fake_key 901 > "${GROXY_DIR}/bridge/wg0/public.key"

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
apt_install() { :; }
# Счётчики вместо пустых заглушек: часть проверок ниже смотрит именно на то,
# был ли вызван рендер и синхронизация, а не только на код возврата.
render_calls=0
sync_calls=0
wg_sync_peers() { sync_calls=$((sync_calls + 1)); }
bridge_render_wg0_conf() { render_calls=$((render_calls + 1)); }
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
check "отдельный код 10, а не общий 1" 10 "${rc}"

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
render_calls=0; sync_calls=0
( bridge_remove_client beta --yes ) >/dev/null 2>&1; rc=$?
check "успех, а не ошибка" 0 "${rc}"
# Суть блокера: раньше ранний return отдавал успех, не тронув ни конфиг, ни
# ядро — оборванное первое удаление оставляло пира живым, а повтор рапортовал,
# что доступ отозван.
bridge_remove_client beta --yes >/dev/null 2>&1
check "отсутствующий клиент всё равно реконсилится: рендер" 1 "${render_calls}"
check "отсутствующий клиент всё равно реконсилится: синхронизация" 1 "${sync_calls}"

echo "== испорченный файл пира не ломает список =="
printf 'PSK=x\nADDR=10.66.66.9\nPUBLIC_KEY=y\nsep=\nname=OVERRIDDEN\n' \
    > "${GROXY_DIR}/bridge/wg0/clients/nasty.peer"
out=$(bridge_list_clients --json 2>/dev/null)
if command -v python3 >/dev/null; then
    check "JSON остаётся валидным" ok \
        "$(python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' \
            <<<"${out}" 2>/dev/null)"
fi
check "поле name не подменилось" 0 "$(grep -c OVERRIDDEN <<<"${out}")"
rm -f "${GROXY_DIR}/bridge/wg0/clients/nasty.peer"

echo "== файл с недопустимым именем пропускается =="
printf 'ADDR=10.66.66.8\nPUBLIC_KEY=z\n' \
    > "${GROXY_DIR}/bridge/wg0/clients/ev\"il.peer"
out=$(bridge_list_clients --json 2>/dev/null)
if command -v python3 >/dev/null; then
    check "JSON валиден при постороннем файле" ok \
        "$(python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' \
            <<<"${out}" 2>/dev/null)"
fi
rm -f "${GROXY_DIR}/bridge/wg0/clients/ev\"il.peer"

echo "== пустой публичный ключ сервера =="
cp "${GROXY_DIR}/bridge/wg0/public.key" "${TMPROOT}/pub.bak"
: > "${GROXY_DIR}/bridge/wg0/public.key"
( bridge_add_client withemptykey ) >/dev/null 2>&1; rc=$?
check "отказ, а не выдача битого конфига" 1 "${rc}"
cp "${TMPROOT}/pub.bak" "${GROXY_DIR}/bridge/wg0/public.key"
rm -f "${GROXY_DIR}/bridge/wg0/clients/withemptykey.peer"

echo "== исчерпанная подсеть =="
for i in $(seq 2 254); do
    printf 'PSK=x\nADDR=10.66.66.%d\nPUBLIC_KEY=y\n' "${i}" \
        > "${GROXY_DIR}/bridge/wg0/clients/fill${i}.peer"
done
out=$( ( bridge_add_client overflow ) 2>/dev/null ); rc=$?
check "отказ вместо адреса вида 10.66.66." 1 "${rc}"
check "битый пир не создан" 0 \
    "$(find "${GROXY_DIR}/bridge/wg0/clients" -name 'overflow.peer' | wc -l | tr -d ' ')"
rm -f "${GROXY_DIR}"/bridge/wg0/clients/fill*.peer

echo "== wg_sync_peers не синхронизирует пустой конфиг =="
# Заглушка выше перезаписала функцию модуля, поэтому её надо вернуть, а не
# просто снять: unset -f оставил бы пустоту.
# shellcheck source=/dev/null
source "${REPO}/lib/wireguard.sh"
systemctl() { [[ "$1" == 'is-active' ]] && return 0; return 0; }
synced=0
wg() { case "$1" in syncconf) synced=$((synced + 1)) ;; *) : ;; esac }
wg-quick() { return 1; }   # strip падает
( wg_sync_peers wg0 ) >/dev/null 2>&1; rc=$?
check "падение wg-quick strip — отказ" 1 "${rc}"
wg-quick() { : ; }         # strip успешен, но вывод пуст
( wg_sync_peers wg0 ) >/dev/null 2>&1; rc=$?
check "пустой вывод strip — отказ" 1 "${rc}"

echo
echo "прошло: ${pass}, упало: ${fail}"
rm -rf "${TMPROOT}"
[[ ${fail} -eq 0 ]]
