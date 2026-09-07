#!/usr/bin/env bash
# Bridge settings — three on/off toggles controlling whitelist feeds.
# Sourced by the dispatcher; do not execute directly.
#
# Keys (env-var style internally, lowercase via CLI):
#   WHITELIST_OPENCCK  — DNS-feed по cron'у (00-opencck.conf, ipset=)
#   WHITELIST_CUSTOM   — DNS-feed из локального custom.txt (50-custom.conf)
#   WHITELIST_GEOIP    — IP-feed CIDR'ов в ipset ru_cidrs
#   XRAY_CLASSIFIER    — классификация по имени из соединения вместо адреса
#   XRAY_ACCESS_LOG    — журнал соединений Xray (по умолчанию off, см. ниже)
#
# Все три по умолчанию on. Off — соответствующий feed не обновляется и
# его эффект убирается из системы:
#   opencck off → rm /etc/dnsmasq.d/00-opencck.conf
#   custom  off → rm /etc/dnsmasq.d/50-custom.conf
#   geoip   off → ipset flush ru_cidrs
#
# XRAY_CLASSIFIER по умолчанию **off**, в отличие от остальных. Включение
# меняет путь всего TCP и UDP клиентов, и такое не должно случаться само собой
# при обновлении кода. Выключение снимает перехват, и классификация по меткам
# продолжает работать — это и есть откат.
#
# XRAY_ACCESS_LOG по умолчанию off не ради места на диске. Он записывает, куда
# именно ходил каждый клиент, то есть историю посещений тридцати шести человек
# в открытом файле. Включается на время разбора и выключается после.

# Путь через GROXY_DIR, как и всё остальное состояние. Зашитый абсолютный
# путь означал, что ни один тест не может подсунуть свои настройки, и
# проверить поведение при выключенном переключателе было нечем.
readonly BRIDGE_SETTINGS_FILE="${GROXY_DIR}/bridge/settings.env"

# Ensure settings.env exists with all three keys set to 'on'. Doesn't
# touch user edits — only fills missing keys.
bridge_ensure_settings() {
    mkdir -p "$(dirname "${BRIDGE_SETTINGS_FILE}")"
    local WHITELIST_OPENCCK='' WHITELIST_CUSTOM='' WHITELIST_GEOIP=''
    local XRAY_CLASSIFIER='' XRAY_ACCESS_LOG=''
    if [[ -f "${BRIDGE_SETTINGS_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${BRIDGE_SETTINGS_FILE}"
    fi
    [[ -n "${WHITELIST_OPENCCK}" ]] || WHITELIST_OPENCCK='on'
    [[ -n "${WHITELIST_CUSTOM}" ]]  || WHITELIST_CUSTOM='on'
    [[ -n "${WHITELIST_GEOIP}" ]]   || WHITELIST_GEOIP='on'
    [[ -n "${XRAY_CLASSIFIER}" ]]   || XRAY_CLASSIFIER='off'
    [[ -n "${XRAY_ACCESS_LOG}" ]]   || XRAY_ACCESS_LOG='off'

    write_atomic "${BRIDGE_SETTINGS_FILE}" 644 <<EOF
# Managed by groxy. Edit via 'groxy bridge settings set <key> on|off'.
WHITELIST_OPENCCK=${WHITELIST_OPENCCK}
WHITELIST_CUSTOM=${WHITELIST_CUSTOM}
WHITELIST_GEOIP=${WHITELIST_GEOIP}
XRAY_CLASSIFIER=${XRAY_CLASSIFIER}
XRAY_ACCESS_LOG=${XRAY_ACCESS_LOG}
EOF
}

# Load settings into caller's scope (caller must declare locals first or
# accept globals).
bridge_settings_load() {
    WHITELIST_OPENCCK='on'
    WHITELIST_CUSTOM='on'
    WHITELIST_GEOIP='on'
    XRAY_CLASSIFIER='off'
    XRAY_ACCESS_LOG='off'
    if [[ -f "${BRIDGE_SETTINGS_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${BRIDGE_SETTINGS_FILE}"
    fi
}

# Translate CLI key (lowercase short) → internal env-var name.
# Echoes the internal name or returns non-zero for unknown keys.
_bridge_settings_resolve_key() {
    case "$1" in
        opencck) printf 'WHITELIST_OPENCCK\n' ;;
        custom)  printf 'WHITELIST_CUSTOM\n' ;;
        geoip)   printf 'WHITELIST_GEOIP\n' ;;
        xray)    printf 'XRAY_CLASSIFIER\n' ;;
        xraylog) printf 'XRAY_ACCESS_LOG\n' ;;
        *) return 1 ;;
    esac
}

# Reconcile system state with current settings. Run after settings change
# or at init.
bridge_apply_settings() {
    local WHITELIST_OPENCCK WHITELIST_CUSTOM WHITELIST_GEOIP
    local XRAY_CLASSIFIER XRAY_ACCESS_LOG
    bridge_settings_load

    # Основной конфиг перерендеривается здесь же, а не только в init.
    #
    # Он теперь зависит от содержимого фида: список российских суффиксов, для
    # которых резолвер пиннится на прямой путь, собирается из тех же файлов.
    # Без этого вызова обновление whitelist'а меняло бы ipset, но не географию
    # резолва, и выкатить правку можно было бы только через `groxy apply`,
    # который перезапускает wg1 и рвёт зарубежный трафик всем клиентам.
    bridge_render_dnsmasq_conf

    # DNS feeds → dnsmasq.d/ files.
    if [[ "${WHITELIST_OPENCCK}" == 'on' ]]; then
        bridge_render_opencck_conf
    else
        rm -f /etc/dnsmasq.d/00-opencck.conf
    fi
    if [[ "${WHITELIST_CUSTOM}" == 'on' ]]; then
        bridge_render_custom_conf
    else
        rm -f /etc/dnsmasq.d/50-custom.conf
    fi
    systemctl is-active --quiet dnsmasq && _bridge_dnsmasq_restart_verify

    # GeoIP feed → ru_cidrs ipset population.
    if [[ "${WHITELIST_GEOIP}" == 'on' ]]; then
        bridge_populate_ru_cidrs
    else
        log "WHITELIST_GEOIP=off → flushing ru_cidrs ipset"
        ipset flush ru_cidrs 2>/dev/null || true
    fi

    # Классификатор приводится к состоянию переключателя здесь же: список
    # доменов у него тот же, что у dnsmasq, и обновляться они обязаны вместе.
    # Разъедься они — по имени и по адресу решалось бы по-разному, и разбирать
    # пришлось бы два списка.
    local SUBNET=''
    if [[ -f "${GROXY_DIR}/bridge/wg0/server.env" ]]; then
        # shellcheck source=/dev/null
        source "${GROXY_DIR}/bridge/wg0/server.env"
    fi
    [[ -n "${SUBNET}" ]] && bridge_xray_apply "${SUBNET}"
}

# `groxy bridge settings get` — print all current settings.
bridge_settings_get() {
    require_root
    [[ -f "${BRIDGE_SETTINGS_FILE}" ]] \
        || die "settings not initialised — run 'groxy init bridge' first"
    local WHITELIST_OPENCCK WHITELIST_CUSTOM WHITELIST_GEOIP
    local XRAY_CLASSIFIER XRAY_ACCESS_LOG
    bridge_settings_load
    printf '%-10s %s\n' 'opencck' "${WHITELIST_OPENCCK}"
    printf '%-10s %s\n' 'custom'  "${WHITELIST_CUSTOM}"
    printf '%-10s %s\n' 'geoip'   "${WHITELIST_GEOIP}"
    printf '%-10s %s\n' 'xray'    "${XRAY_CLASSIFIER}"
    printf '%-10s %s\n' 'xraylog' "${XRAY_ACCESS_LOG}"
}

# `groxy bridge settings set <key> <on|off>`.
bridge_settings_set() {
    require_root
    acquire_state_lock
    local key="${1:-}" value="${2:-}"
    [[ -n "${key}" && -n "${value}" ]] \
        || die "usage: groxy bridge settings set <opencck|custom|geoip|xray|xraylog> <on|off>"

    local env_key
    env_key=$(_bridge_settings_resolve_key "${key}") \
        || die "unknown key '${key}' (expected: opencck|custom|geoip|xray|xraylog)"

    case "${value}" in
        on|off) ;;
        *) die "value must be 'on' or 'off' (got '${value}')" ;;
    esac

    # Read current settings, patch one key, write back.
    local WHITELIST_OPENCCK WHITELIST_CUSTOM WHITELIST_GEOIP
    local XRAY_CLASSIFIER XRAY_ACCESS_LOG
    bridge_settings_load
    printf -v "${env_key}" '%s' "${value}"

    write_atomic "${BRIDGE_SETTINGS_FILE}" 644 <<EOF
# Managed by groxy. Edit via 'groxy bridge settings set <key> on|off'.
WHITELIST_OPENCCK=${WHITELIST_OPENCCK}
WHITELIST_CUSTOM=${WHITELIST_CUSTOM}
WHITELIST_GEOIP=${WHITELIST_GEOIP}
XRAY_CLASSIFIER=${XRAY_CLASSIFIER}
XRAY_ACCESS_LOG=${XRAY_ACCESS_LOG}
EOF
    log "set ${env_key}=${value}"

    log "applying settings to system state"
    bridge_apply_settings
}
