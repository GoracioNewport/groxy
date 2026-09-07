#!/usr/bin/env bash
# Xray как классификатор трафика клиентов.
# Sourced by the dispatcher; do not execute directly.
#
# Решение «российское или зарубежное» принимается по имени из самого
# соединения — SNI у TLS, Host у HTTP, имя из QUIC, — а не по адресу
# назначения. Разбор, замеры и результаты обкатки — в docs/PLAN-XRAY.md.
#
# Классификация по меткам никуда не девается: она остаётся для всего, что не
# TCP и не UDP, и служит откатом. Выключить Xray — значит вернуться к ней, и
# ничего перезапускать при этом не нужно.

readonly BRIDGE_XRAY_BIN="${BRIDGE_XRAY_BIN:-/usr/local/bin/xray}"
readonly BRIDGE_XRAY_CONF="${BRIDGE_XRAY_CONF:-/usr/local/etc/xray/config.json}"
readonly BRIDGE_XRAY_ASSETS="${BRIDGE_XRAY_ASSETS:-/usr/local/share/xray}"

# Порт локального инбаунда. Слушает только на 127.0.0.1: попасть туда можно
# лишь через правило TPROXY, снаружи он недоступен.
readonly BRIDGE_XRAY_PORT="${BRIDGE_XRAY_PORT:-12345}"

# Метка и таблица для доставки перехваченных пакетов локальному сокету.
# Обязаны отличаться от 0x1/vpn2: совпади они, перехваченный пакет ушёл бы в
# wg1 вместо сокета, то есть в никуда.
readonly BRIDGE_XRAY_MARK="${BRIDGE_XRAY_MARK:-0x2}"
readonly BRIDGE_XRAY_TABLE="${BRIDGE_XRAY_TABLE:-100}"
readonly BRIDGE_XRAY_RULE_PRIO="${BRIDGE_XRAY_RULE_PRIO:-99}"

readonly BRIDGE_XRAY_CHAIN='GROXY_TPROXY'

# Домены, которые обязаны идти через портал, чем бы они ни выглядели.
# Проверяются первыми — иначе их перекрыл бы российский список.
readonly BRIDGE_XRAY_DENYLIST="${GROXY_DIR}/bridge/whitelist/foreign-denylist.txt"

# Имя годится в правило Xray, если это домен, а не мусор из фида.
# Проверяется отдельно от разбора строки: фид приходит из сети, а результат
# уезжает в JSON, где одна кавычка ломает весь конфиг, а не свою запись.
#
# Точка НЕ обязательна. Первая версия её требовала — и молча выбрасывала
# `*.ru` из custom.txt, то есть правило «весь домен .ru напрямую», одну из
# самых крупных частей классификации на этом парке. Для dnsmasq `*.ru`
# означает домен и всё под ним; `domain:ru` у Xray значит ровно то же.
_xray_valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,251}[A-Za-z0-9])?$ ]]
}

# Напечатать домены из файла в виде элементов JSON-массива, по одному в строке.
# Пустой файл или отсутствующий — пустой вывод, это не ошибка.
_xray_domain_items() {
    local file="$1" prefix="$2" line domain sep=''
    [[ -f "${file}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        domain=$(_bridge_dns_domain_from_line "${line}")
        [[ -n "${domain}" ]] || continue
        _xray_valid_domain "${domain}" || continue
        printf '%s"%s%s"' "${sep}" "${prefix}" "${domain}"
        sep=$',\n      '
    done < "${file}"
}

# Собрать конфиг Xray из состояния groxy.
#
# Список российских доменов берётся из тех же файлов, что и правила dnsmasq, —
# второго источника правды не заводим. Иначе классификация по имени и по
# адресу однажды разошлись бы, и разбираться пришлось бы, глядя на два списка.
bridge_xray_render_config() {
    local dir="${GROXY_DIR}/bridge/whitelist"
    local tmp
    tmp=$(mktemp) || die "cannot create a temporary file for the xray config"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp}'" RETURN

    local ru_items deny_items
    ru_items=$(
        _xray_domain_items "${dir}/opencck.txt" 'domain:'
        # custom.txt дописывается тем же способом, но список надо разделить
        # запятой, только если первый непустой.
        #
        # Именно `if`, а не `[[ ... ]] && printf`. Пустой custom.txt — обычное
        # дело, и тогда `&&`-конструкция возвращает 1, подстановка команд
        # возвращает 1, а `set -e` убивает всю функцию молча: конфиг не
        # собирался, классификатор не включался, и в журнале не было ни строки.
        # Поймано на живом узле; набор тестов идёт без `-e` и пропустил это.
        local extra
        extra=$(_xray_domain_items "${dir}/custom.txt" 'domain:')
        if [[ -n "${extra}" ]]; then
            printf ',\n      %s' "${extra}"
        fi
    )
    deny_items=$(_xray_domain_items "${BRIDGE_XRAY_DENYLIST}" 'domain:')

    # Журнал соединений по умолчанию выключен, и это не про место на диске.
    # Он записывает, куда именно ходил каждый клиент, то есть историю
    # посещений тридцати шести человек, лежащую в открытом файле. Такие данные
    # не собирают «на всякий случай»: включается на время разбора и
    # выключается после.
    local access_log='none'
    [[ "${XRAY_ACCESS_LOG:-off}" == 'on' ]] && access_log='/var/log/groxy-xray/access.log'

    cat > "${tmp}" <<EOF
{
  "log": { "loglevel": "warning", "access": "${access_log}" },

  "inbounds": [
    {
      "tag": "tproxy-in",
      "listen": "127.0.0.1",
      "port": ${BRIDGE_XRAY_PORT},
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
    }
  ],

  "outbounds": [
    { "tag": "portal", "protocol": "freedom", "settings": {},
      "streamSettings": { "sockopt": { "mark": 1 } } },
    { "tag": "direct", "protocol": "freedom", "settings": {},
      "streamSettings": { "sockopt": { "mark": 0 } } }
  ],

  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "outboundTag": "portal", "domain": [
      ${deny_items:-\"domain:invalid.groxy.placeholder\"}
      ] },
      { "type": "field", "outboundTag": "direct", "domain": [
      ${ru_items:-\"domain:invalid.groxy.placeholder\"}
      ] },
      { "type": "field", "outboundTag": "direct", "ip": ["geoip:ru", "geoip:private"] },
      { "type": "field", "outboundTag": "portal", "network": "tcp,udp" }
    ]
  }
}
EOF

    # Конфиг проверяется до подмены живого. Xray с битым конфигом не стартует
    # вовсе, а он к этому моменту — единственный путь для всего TCP и UDP
    # клиентов: подменить рабочий конфиг непроверенным значит оставить парк
    # без сети до прихода человека.
    # `-format json` обязателен. Xray определяет формат по расширению файла, а
    # у временного файла от mktemp его нет — и он отказывается словами «failed
    # to get format», которые ничего не говорят о конфиге. Проверка при этом
    # честно падала, и рабочий конфиг не подменялся, так что вреда не было —
    # только час на поиск.
    local check_out
    if ! check_out=$(XRAY_LOCATION_ASSET="${BRIDGE_XRAY_ASSETS}" \
            "${BRIDGE_XRAY_BIN}" run -test -format json -config "${tmp}" 2>&1); then
        # Сообщение Xray печатается, а не глотается. В конфиге нет секретов —
        # только домены, — а без причины отказ выглядит как «просто не
        # получилось», и разбираться приходится вслепую.
        log "xray -test сказал: $(printf '%s' "${check_out}" | tail -2 | tr '\n' ' ')"
        die "rendered xray config did not pass 'xray -test' — keeping the previous one"
    fi

    mkdir -p "$(dirname "${BRIDGE_XRAY_CONF}")"
    write_atomic "${BRIDGE_XRAY_CONF}" 644 < "${tmp}"
    log "rendered xray config ($(_xray_count_domains) domain rule(s))"
}

# Сколько доменов попало в конфиг. Только для строки в логе.
_xray_count_domains() {
    grep -c '"domain:' "${BRIDGE_XRAY_CONF}" 2>/dev/null || printf '0'
}

# Поставить перехват. Идемпотентно.
bridge_xray_ensure_rules() {
    local subnet="$1"

    ip rule show | grep -q "fwmark ${BRIDGE_XRAY_MARK} lookup ${BRIDGE_XRAY_TABLE}" \
        || ip rule add fwmark "${BRIDGE_XRAY_MARK}" lookup "${BRIDGE_XRAY_TABLE}" \
               priority "${BRIDGE_XRAY_RULE_PRIO}"
    ip route replace local default dev lo table "${BRIDGE_XRAY_TABLE}"

    iptables -t mangle -N "${BRIDGE_XRAY_CHAIN}" 2>/dev/null || true
    iptables -t mangle -F "${BRIDGE_XRAY_CHAIN}"

    # Что НЕ заворачивается. Каждый пропущенный случай — поломка, которую
    # заметят не сразу:
    #   свои же клиенты между собой,
    #   обращения к самому бриджу, прежде всего DNS на его туннельном адресе.
    # ICMP сюда не попадает вовсе: TPROXY ловит только TCP и UDP, и пинги
    # идут прежним путём по метке.
    iptables -t mangle -A "${BRIDGE_XRAY_CHAIN}" -d "${subnet}" -j RETURN

    iptables -t mangle -A "${BRIDGE_XRAY_CHAIN}" -p tcp -j TPROXY \
        --on-ip 127.0.0.1 --on-port "${BRIDGE_XRAY_PORT}" \
        --tproxy-mark "${BRIDGE_XRAY_MARK}/0xffffffff"
    iptables -t mangle -A "${BRIDGE_XRAY_CHAIN}" -p udp -j TPROXY \
        --on-ip 127.0.0.1 --on-port "${BRIDGE_XRAY_PORT}" \
        --tproxy-mark "${BRIDGE_XRAY_MARK}/0xffffffff"

    # Переход ставится первым в цепочке: TPROXY завершает обработку пакета, и
    # правила меток ниже до TCP и UDP уже не доберутся.
    iptables -t mangle -C PREROUTING -i wg0 -p tcp -j "${BRIDGE_XRAY_CHAIN}" 2>/dev/null \
        || iptables -t mangle -I PREROUTING 1 -i wg0 -p tcp -j "${BRIDGE_XRAY_CHAIN}"
    iptables -t mangle -C PREROUTING -i wg0 -p udp -j "${BRIDGE_XRAY_CHAIN}" 2>/dev/null \
        || iptables -t mangle -I PREROUTING 2 -i wg0 -p udp -j "${BRIDGE_XRAY_CHAIN}"
}

# Снять перехват. Это и есть откат: классификация по меткам продолжит работать
# сама, перезапускать ничего не нужно.
bridge_xray_remove_rules() {
    iptables -t mangle -D PREROUTING -i wg0 -p tcp -j "${BRIDGE_XRAY_CHAIN}" 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i wg0 -p udp -j "${BRIDGE_XRAY_CHAIN}" 2>/dev/null || true
    iptables -t mangle -F "${BRIDGE_XRAY_CHAIN}" 2>/dev/null || true
    iptables -t mangle -X "${BRIDGE_XRAY_CHAIN}" 2>/dev/null || true
    ip rule del fwmark "${BRIDGE_XRAY_MARK}" lookup "${BRIDGE_XRAY_TABLE}" 2>/dev/null || true
    ip route flush table "${BRIDGE_XRAY_TABLE}" 2>/dev/null || true
}

# Дождаться, пока инбаунд действительно начнёт слушать.
#
# Без ожидания перехват включался бы раньше готовности, и первые соединения
# клиентов уходили бы в никуда. Двадцать попыток по четверти секунды: Xray с
# девятнадцатью тысячами правил поднимается заметно дольше пустого.
_xray_wait_listening() {
    local i
    for ((i = 0; i < 20; i++)); do
        ss -lnt 2>/dev/null | grep -q "127.0.0.1:${BRIDGE_XRAY_PORT}" && return 0
        sleep 0.25
    done
    return 1
}

# `groxy bridge xray-rules <up|down>`. Ставит или снимает перехват.
#
# Отдельной командой потому, что её зовёт сам юнит через ExecStartPost и
# ExecStopPost. Правила перехвата — состояние времени выполнения: после
# перезагрузки их никто не восстановил бы до следующего `apply`, и
# классификатор молча выродился бы в прежнюю классификацию по меткам. Хуже
# всего, что тревога на живость при этом молчит: Xray-то работает, просто
# трафик мимо него не идёт.
bridge_xray_rules() {
    require_root
    # Общую блокировку намеренно НЕ берёт. Её зовёт ExecStartPost, а тот
    # запускается из systemctl restart, который в свою очередь вызывается из
    # bridge_xray_apply — а он блокировку уже держит. Попытка взять её здесь
    # означала бы тридцать секунд ожидания и отказ на ровном месте.
    # Команда ставит только правила фаервола и маршрутизации, состояние groxy
    # не трогает, так что защищать нечего.
    local action="${1:-}"
    local SUBNET=''
    if [[ -f "${GROXY_DIR}/bridge/wg0/server.env" ]]; then
        # shellcheck source=/dev/null
        source "${GROXY_DIR}/bridge/wg0/server.env"
    fi

    case "${action}" in
        up)
            [[ -n "${SUBNET}" ]] || die "wg0 subnet unknown — cannot install the rules"
            _xray_wait_listening \
                || die "xray is not listening on ${BRIDGE_XRAY_PORT} — refusing to redirect traffic"
            bridge_xray_ensure_rules "${SUBNET}"
            log "tproxy rules installed"
            ;;
        down)
            bridge_xray_remove_rules
            log "tproxy rules removed"
            ;;
        *)
            die "usage: groxy bridge xray-rules <up|down>"
            ;;
    esac
}

# Привести всё к состоянию, заданному переключателем.
#
# Зовётся из apply и из обновления фида. Порядок при включении важен: сначала
# конфиг и живой Xray, только потом перехват. Наоборот — значит завернуть
# трафик клиентов в сокет, которого ещё нет.
bridge_xray_apply() {
    local subnet="$1"
    local XRAY_CLASSIFIER
    bridge_settings_load

    if [[ "${XRAY_CLASSIFIER:-off}" != 'on' ]]; then
        bridge_xray_remove_rules
        systemctl disable --now groxy-xray >/dev/null 2>&1 || true
        log "xray classifier is off — traffic classified by marks"
        return 0
    fi

    [[ -x "${BRIDGE_XRAY_BIN}" ]] \
        || die "xray classifier is on but ${BRIDGE_XRAY_BIN} is missing"

    bridge_xray_render_config
    systemctl enable groxy-xray >/dev/null 2>&1 || true
    systemctl restart groxy-xray || die "failed to start groxy-xray"

    _xray_wait_listening \
        || die "groxy-xray is not listening on ${BRIDGE_XRAY_PORT} — refusing to redirect traffic"

    bridge_xray_ensure_rules "${subnet}"
    log "xray classifier is on — tcp/udp from wg0 goes through it"
}
