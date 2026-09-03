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
# Обе константы объявлены readonly при загрузке common.sh, поэтому задать их
# надо ДО неё.
export GROXY_WG_DIR="${TMPROOT}/wg"
mkdir -p "${GROXY_WG_DIR}"
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
# Настоящий рендер сохраняется под другим именем ДО подмены: часть проверок
# смотрит именно на него, а повторный source модуля ругался бы на константы.
eval "real_render_wg0_conf() $(declare -f bridge_render_wg0_conf | tail -n +2)"
wg_sync_peers() { sync_calls=$((sync_calls + 1)); }
bridge_render_wg0_conf() { render_calls=$((render_calls + 1)); }
_n=0
wg() {
    case "$1" in
        genkey|genpsk) _n=$((_n + 1)); printf 'fakekey%036d=\n' "${_n}" ;;
        # Публичный выводится из приватного, а не из независимого счётчика:
        # иначе ни одна проверка не может убедиться, что в файл пира записан
        # ключ именно того клиента, чей приватный ушёл в конфиг.
        pubkey)        local priv; read -r priv
                       printf '%s\n' "${priv/fakekey/fakepub}" ;;
        *) : ;;
    esac
}

skipped=0
have_python=0
command -v python3 >/dev/null && have_python=1

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
if (( have_python )); then
    # Раньше проверялось только наличие подстроки: структура вывода
    # add-client не разбиралась как JSON ни разу.
    check "валидный JSON с нужными полями" ok \
        "$(python3 -c 'import json,sys
d=json.load(sys.stdin)
assert set(d) >= {"name","address","config_b64"}, d
assert d["config_b64"], "пустой config_b64"
print("ok")' <<<"${out}" 2>/dev/null)"
else
    skipped=$((skipped + 1))
fi
decoded=$(sed 's/.*"config_b64":"\([^"]*\)".*/\1/' <<<"${out}" | base64 -d)
check "конфиг декодируется" 1 "$(grep -c '\[Interface\]' <<<"${decoded}")"

# Ключ, отданный клиенту, и ключ, записанный в файл пира, должны быть парой.
priv=$(sed -n 's/^PrivateKey = //p' <<<"${decoded}")
want_pub="${priv/fakekey/fakepub}"
got_pub=$(peer_field "${GROXY_DIR}/bridge/wg0/clients/gamma.peer" PUBLIC_KEY)
check "в файле пира лежит публичный ключ выданного приватного" "${want_pub}" "${got_pub}"

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

echo "== рендер не подменяет конфиг обрезком =="
# Проверяется настоящий bridge_render_wg0_conf, без заглушки: именно здесь
# конвейер в write_atomic коммитил оборванный поток, и один битый файл пира
# оставлял в wg0.conf одного клиента вместо всех.
( real_render_wg0_conf ) >/dev/null 2>&1
check "исходный рендер удался" 1 \
    "$(find "${GROXY_WG_DIR}" -name 'wg0.conf' | wc -l | tr -d ' ')"
good_peers=$(grep -c '^\[Peer\]' "${GROXY_WG_DIR}/wg0.conf")
cp "${GROXY_WG_DIR}/wg0.conf" "${TMPROOT}/wg0.good"

printf 'PSK=x\nPUBLIC_KEY=y\n' \
    > "${GROXY_DIR}/bridge/wg0/clients/broken.peer"
( real_render_wg0_conf ) >/dev/null 2>&1; rc=$?
check "битый файл пира — отказ" 1 "${rc}"
check "старый конфиг не тронут" "${good_peers}" \
    "$(grep -c '^\[Peer\]' "${GROXY_WG_DIR}/wg0.conf")"
check "конфиг не подменён обрезком" ok \
    "$(cmp -s "${TMPROOT}/wg0.good" "${GROXY_WG_DIR}/wg0.conf" && echo ok)"
rm -f "${GROXY_DIR}/bridge/wg0/clients/broken.peer"

echo "== NUL-байт в файле пира не читается как пустое поле =="
printf 'PSK=x\nADDR=10.66.66.50\n\000\nPUBLIC_KEY=z\n' \
    > "${GROXY_DIR}/bridge/wg0/clients/nul.peer"
check "ADDR всё равно читается" 10.66.66.50 \
    "$(peer_field "${GROXY_DIR}/bridge/wg0/clients/nul.peer" ADDR)"
rm -f "${GROXY_DIR}/bridge/wg0/clients/nul.peer"

echo "== блокировка действительно взаимоисключающая =="
# Раньше лок в тестах просто заглушали пустышкой, поэтому не проверялось
# ничего — включая то, ради чего он вводился. Здесь берётся настоящий flock,
# только по пути во временном каталоге и с коротким ожиданием.
if command -v flock >/dev/null; then
    unset -f acquire_state_lock
    # shellcheck source=/dev/null
    source "${REPO}/lib/common.sh"
    export GROXY_LOCK="${TMPROOT}/state.lock"
    export GROXY_LOCK_WAIT=1

    ( flock -x 8 && sleep 3 ) 8>"${GROXY_LOCK}" &
    holder=$!
    sleep 0.3
    ( acquire_state_lock ) >/dev/null 2>&1; rc=$?
    check "занятый лок даёт код 11, а не общий 1" 11 "${rc}"
    wait "${holder}" 2>/dev/null

    ( acquire_state_lock ) >/dev/null 2>&1; rc=$?
    check "свободный лок берётся" 0 "${rc}"

    # Повторный вызов в одном процессе не должен переоткрывать дескриптор:
    # переоткрытие на миг снимает блокировку.
    ( acquire_state_lock; acquire_state_lock ) >/dev/null 2>&1; rc=$?
    check "повторный захват — не ошибка" 0 "${rc}"
    acquire_state_lock() { :; }   # вернуть заглушку для остальных проверок
else
    echo "  (flock недоступен — проверка блокировки пропущена)"
fi

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

# Самый тихий из сценариев: конфиг валиден, секция [Interface] на месте, но
# пиров ноль — а в ядре их 36. Прежний страж такое пропускал, и syncconf
# снимал всех, отрапортовав «sessions preserved».
wg() {
    case "$1" in
        show) [[ "$3" == 'peers' ]] && printf 'peerA\npeerB\n' ;;
        syncconf) synced=$((synced + 1)) ;;
        *) : ;;
    esac
}
wg-quick() { printf '[Interface]\nPrivateKey = x\n'; }
( wg_sync_peers wg0 ) >/dev/null 2>&1; rc=$?
check "ноль пиров при живых пирах в ядре — отказ" 1 "${rc}"

wg-quick() { printf '[Interface]\nPrivateKey = x\n\n[Peer]\nPublicKey = y\n'; }
( wg_sync_peers wg0 ) >/dev/null 2>&1; rc=$?
check "конфиг с пирами проходит" 0 "${rc}"

echo
if (( skipped )); then
    echo "прошло: ${pass}, упало: ${fail}, пропущено: ${skipped} (нет python3)"
else
    echo "прошло: ${pass}, упало: ${fail}"
fi
rm -rf "${TMPROOT}"
[[ ${fail} -eq 0 ]]
