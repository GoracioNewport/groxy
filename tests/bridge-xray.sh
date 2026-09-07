#!/usr/bin/env bash
# Контракт классификатора Xray. Запуск: bash tests/bridge-xray.sh
#
# Ни root, ни настоящего Xray: iptables, ip, systemctl и сам xray подменены.
# Проверяется то, что дороже всего ошибиться: выключенный переключатель не
# должен ставить перехват, а включённый — не должен заворачивать трафик в
# сокет, которого ещё нет.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
export GROXY_DIR="${TMPROOT}/groxy"
export GROXY_WG_DIR="${TMPROOT}/wg"
export BRIDGE_XRAY_BIN="${TMPROOT}/fake-xray"
export BRIDGE_XRAY_CONF="${TMPROOT}/xray-config.json"
export BRIDGE_XRAY_ASSETS="${TMPROOT}/assets"
mkdir -p "${GROXY_WG_DIR}" "${GROXY_DIR}/bridge/whitelist" "${GROXY_DIR}/bridge/wg0" "${BRIDGE_XRAY_ASSETS}"
GROXY_VERSION='test'

cat > "${GROXY_DIR}/bridge/wg0/server.env" <<'EOF'
SUBNET=10.66.66.0/24
LISTEN_PORT=51820
PUBLIC_IP=203.0.113.1
EOF

# Подставной xray: `run -test` соглашается, если конфиг — валидный JSON.
# Именно это и проверяет настоящий, а разбирать JSON тут есть чем.
cat > "${TMPROOT}/fake-xray" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ "${a}" == -config ]]; then next=1; continue; fi
    if [[ "${next:-}" == 1 ]]; then cfg="${a}"; next=0; fi
done
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cfg}"
EOF
chmod +x "${TMPROOT}/fake-xray"

# shellcheck source=/dev/null
source "${REPO}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/system.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/bridge_dns.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/bridge_settings.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/bridge_xray.sh"

require_root() { :; }
acquire_state_lock() { :; }
# Всё, что тянет за собой `settings set`, но к классификатору отношения не
# имеет. Без заглушек проверка уходила бы в настоящий dnsmasq и ipset.
bridge_render_dnsmasq_conf() { :; }
bridge_render_opencck_conf() { :; }
bridge_render_custom_conf() { :; }
_bridge_dnsmasq_restart_verify() { :; }
bridge_populate_ru_cidrs() { :; }
ipset() { :; }

CALLS="${TMPROOT}/calls"
mkdir -p "${CALLS}"
iptables() { printf '%s\n' "$*" >> "${CALLS}/iptables"; }
ip() { printf '%s\n' "$*" >> "${CALLS}/ip"; return 0; }
systemctl() { printf '%s\n' "$*" >> "${CALLS}/systemctl"; return 0; }
ss() { printf 'LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:*\n' "${BRIDGE_XRAY_PORT}"; }
reset_calls() { rm -f "${CALLS}"/*; }
# Отсутствующий файл — это ноль вызовов, а не пустая строка: `grep -cs` по
# несуществующему файлу не печатает ничего, и проверка «вызовов не было»
# падала бы именно тогда, когда их действительно не было.
count_calls() {
    local pattern="$1" file="${CALLS}/$2"
    [[ -f "${file}" ]] || { printf '0\n'; return 0; }
    # `|| printf 0` дописывал бы второй ноль к настоящему нулю от grep:
    # он и печатает 0, и возвращает 1, когда совпадений нет.
    local n
    n=$(grep -cs -- "${pattern}" "${file}") || n=0
    printf '%s\n' "${n:-0}"
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

cat > "${GROXY_DIR}/bridge/whitelist/opencck.txt" <<'EOF'
ipset=/ya.ru/vpn_domains
ipset=/avito.ru/vpn_domains
# комментарий
*.mail.ru
EOF
cat > "${GROXY_DIR}/bridge/whitelist/foreign-denylist.txt" <<'EOF'
blocked.example
EOF

echo "== переключатель выключен =="
# Прод не должен переехать на новую классификацию сам собой при обновлении
# кода. По умолчанию off — и это единственный переключатель с таким умолчанием.
bridge_ensure_settings
check "по умолчанию off" off "$(grep '^XRAY_CLASSIFIER=' "${GROXY_DIR}/bridge/settings.env" | cut -d= -f2)"
reset_calls
bridge_xray_apply 10.66.66.0/24 >/dev/null 2>&1
check "перехват не ставится" 0 "$(count_calls "-j TPROXY" iptables)"
check "правило маршрутизации не добавляется" 0 "$(count_calls "rule add" ip)"
check "снятие всё равно вызвано" 1 "$(grep -cs 'PREROUTING' "${CALLS}/iptables" > /dev/null && echo 1 || echo 0)"

echo "== конфиг собирается из тех же файлов, что и dnsmasq =="
bridge_xray_render_config >/dev/null 2>&1
check "конфиг валиден как JSON" ok \
    "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "${BRIDGE_XRAY_CONF}" 2>/dev/null)"
check "домены из фида попали" 1 "$(grep -c '"domain:ya.ru"' "${BRIDGE_XRAY_CONF}")"
check "звёздочка из фида срезана" 1 "$(grep -c '"domain:mail.ru"' "${BRIDGE_XRAY_CONF}")"
check "комментарий не попал" 0 "$(grep -c 'комментарий' "${BRIDGE_XRAY_CONF}")"

echo "== denylist проверяется раньше российского списка =="
# Иначе его перекроет список: домен, обязанный идти через портал, ушёл бы
# напрямую, и заметили бы это не сразу.
deny_line=$(grep -n '"domain:blocked.example"' "${BRIDGE_XRAY_CONF}" | cut -d: -f1)
ru_line=$(grep -n '"domain:ya.ru"' "${BRIDGE_XRAY_CONF}" | cut -d: -f1)
check "denylist выше" 1 "$(( deny_line < ru_line ? 1 : 0 ))"

echo "== журнал соединений по умолчанию выключен =="
# Он записывает, куда ходил каждый клиент. Такие данные не собирают
# «на всякий случай».
check "access отключён" 1 "$(grep -c '"access": "none"' "${BRIDGE_XRAY_CONF}")"
XRAY_ACCESS_LOG=on bridge_xray_render_config >/dev/null 2>&1
check "включается настройкой" 1 "$(grep -c 'access.log' "${BRIDGE_XRAY_CONF}")"

echo "== мусор из фида не ломает конфиг =="
cp "${GROXY_DIR}/bridge/whitelist/opencck.txt" "${TMPROOT}/feed.bak"
cat >> "${GROXY_DIR}/bridge/whitelist/opencck.txt" <<'EOF'
ipset=/ev"il.example/vpn_domains
ipset=/нетточки/vpn_domains
EOF
bridge_xray_render_config >/dev/null 2>&1
check "конфиг остался валиден" ok \
    "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "${BRIDGE_XRAY_CONF}" 2>/dev/null)"
check "кавычка отброшена" 0 "$(grep -c 'ev"il' "${BRIDGE_XRAY_CONF}")"
check "имя без точки отброшено" 0 "$(grep -c 'нетточки' "${BRIDGE_XRAY_CONF}")"
check "живые домены не потеряны" 1 "$(grep -c '"domain:ya.ru"' "${BRIDGE_XRAY_CONF}")"
cp "${TMPROOT}/feed.bak" "${GROXY_DIR}/bridge/whitelist/opencck.txt"

echo "== переключатель включён =="
bridge_settings_set xray on >/dev/null 2>&1
reset_calls
bridge_xray_apply 10.66.66.0/24 >/dev/null 2>&1
check "перехват поставлен" 2 "$(count_calls "-j TPROXY" iptables)"
check "правило маршрутизации добавлено" 1 "$(count_calls "rule add fwmark" ip)"
check "свои клиенты исключены" 1 "$(count_calls RETURN iptables)"
# Наоборот — значит завернуть трафик клиентов в сокет, которого ещё нет.
restart_line=$(grep -n 'restart groxy-xray' "${CALLS}/systemctl" | head -1 | cut -d: -f1)
check "Xray поднят до перехвата" 1 "$(( restart_line >= 1 ? 1 : 0 ))"

echo "== сокет не поднялся — перехват не ставится =="
# Иначе весь TCP и UDP клиентов ушёл бы в никуда.
ss() { printf 'ничего не слушает\n'; }
reset_calls
( bridge_xray_apply 10.66.66.0/24 ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"
check "перехват не поставлен" 0 "$(count_calls "-j TPROXY" iptables)"
ss() { printf 'LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:*\n' "${BRIDGE_XRAY_PORT}"; }

echo "== битый конфиг не подменяет рабочий =="
# Xray с битым конфигом не стартует вовсе, а он к этому моменту единственный
# путь для всего TCP и UDP клиентов.
cp "${BRIDGE_XRAY_CONF}" "${TMPROOT}/good.json"
cat > "${TMPROOT}/fake-xray" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${TMPROOT}/fake-xray"
( bridge_xray_render_config ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"
check "прежний конфиг цел" ok \
    "$(cmp -s "${BRIDGE_XRAY_CONF}" "${TMPROOT}/good.json" && echo ok || echo изменён)"

echo
echo "прошло: ${pass}, упало: ${fail}"
rm -rf "${TMPROOT}"
[[ ${fail} -eq 0 ]]
