#!/usr/bin/env bash
# Контракт проверки фида доменов перед заменой действующего списка. Запуск:
#   bash tests/whitelist-feed.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
export GROXY_DIR="${TMPROOT}/groxy"
export GROXY_WG_DIR="${TMPROOT}/wg"
export GROXY_DNSMASQ_CONF="${TMPROOT}/dnsmasq.conf"
mkdir -p "${GROXY_WG_DIR}" "${GROXY_DIR}/bridge/whitelist"
GROXY_VERSION='test'
# Порог доли задаётся до загрузки модуля: константы там readonly.
export BRIDGE_WHITELIST_MIN_DOMAINS=100
export BRIDGE_WHITELIST_MIN_RATIO=50

# shellcheck source=/dev/null
source "${REPO}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/system.sh"
# shellcheck source=/dev/null
source "${REPO}/lib/bridge_dns.sh"

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

feed() {
    local path="$1" count="$2" i
    : > "${path}"
    for ((i = 1; i <= count; i++)); do
        printf 'ipset=/example%d.com/vpn_domains\n' "${i}" >> "${path}"
    done
}

CURRENT="${TMPROOT}/current.txt"
CANDIDATE="${TMPROOT}/candidate.txt"

echo "== счёт доменов, а не строк =="
# Сервер, отдавший страницу с ошибкой вместо списка, возвращает сотни строк и
# ноль доменов. Прежняя проверка «файл непустой» такое пропускала.
cat > "${CANDIDATE}" <<'HTML'
<!doctype html>
<html><head><title>502 Bad Gateway</title></head>
<body><h1>502 Bad Gateway</h1><p>nginx</p></body></html>
HTML
check "у HTML-страницы доменов нет" 0 "$(_bridge_dns_count_domains "${CANDIDATE}")"

feed "${CANDIDATE}" 5
check "комментарии и пустые строки не считаются" 5 \
    "$(printf '# комментарий\n\n%s' "$(cat "${CANDIDATE}")" > "${CANDIDATE}.x"; \
       _bridge_dns_count_domains "${CANDIDATE}.x")"

echo "== пустой ответ сервера отвергается =="
cat > "${CANDIDATE}" <<'HTML'
<!doctype html><html><body>502</body></html>
HTML
feed "${CURRENT}" 1000
( _bridge_whitelist_feed_ok "${CANDIDATE}" "${CURRENT}" ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"

echo "== слишком короткий список отвергается =="
feed "${CANDIDATE}" 50
( _bridge_whitelist_feed_ok "${CANDIDATE}" "${CURRENT}" ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"

echo "== резкое усыхание отвергается =="
# Фид меняется понемногу. Падение вдвое означает, что отдали не то, а не что
# интернет уполовинился.
feed "${CANDIDATE}" 400
( _bridge_whitelist_feed_ok "${CANDIDATE}" "${CURRENT}" ) >/dev/null 2>&1; rc=$?
check "отказ" 1 "${rc}"

echo "== обычное изменение принимается =="
feed "${CANDIDATE}" 950
( _bridge_whitelist_feed_ok "${CANDIDATE}" "${CURRENT}" ) >/dev/null 2>&1; rc=$?
check "принято" 0 "${rc}"

feed "${CANDIDATE}" 1200
( _bridge_whitelist_feed_ok "${CANDIDATE}" "${CURRENT}" ) >/dev/null 2>&1; rc=$?
check "рост принят" 0 "${rc}"

echo "== первый запуск, прежнего списка нет =="
# Сравнивать не с чем, работает только абсолютный пол.
feed "${CANDIDATE}" 200
( _bridge_whitelist_feed_ok "${CANDIDATE}" "${TMPROOT}/нет-такого" ) >/dev/null 2>&1; rc=$?
check "принято" 0 "${rc}"

feed "${CANDIDATE}" 20
( _bridge_whitelist_feed_ok "${CANDIDATE}" "${TMPROOT}/нет-такого" ) >/dev/null 2>&1; rc=$?
check "но пол всё равно держит" 1 "${rc}"

echo "== прежний список не тронут при отказе =="
before=$(_bridge_dns_count_domains "${CURRENT}")
feed "${CANDIDATE}" 1
( _bridge_whitelist_feed_ok "${CANDIDATE}" "${CURRENT}" ) >/dev/null 2>&1
check "остался прежним" "${before}" "$(_bridge_dns_count_domains "${CURRENT}")"

echo
echo "прошло: ${pass}, упало: ${fail}"
rm -rf "${TMPROOT}"
[[ ${fail} -eq 0 ]]
