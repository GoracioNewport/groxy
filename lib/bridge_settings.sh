#!/usr/bin/env bash
# Bridge settings — three on/off toggles controlling whitelist feeds.
# Sourced by the dispatcher; do not execute directly.
#
# Keys (env-var style internally, lowercase via CLI):
#   WHITELIST_OPENCCK  — DNS-feed по cron'у (00-opencck.conf, ipset=)
#   WHITELIST_CUSTOM   — DNS-feed из локального custom.txt (50-custom.conf)
#   WHITELIST_GEOIP    — IP-feed CIDR'ов в ipset ru_cidrs
#
# Все три по умолчанию on. Off — соответствующий feed не обновляется и
# его эффект убирается из системы:
#   opencck off → rm /etc/dnsmasq.d/00-opencck.conf
#   custom  off → rm /etc/dnsmasq.d/50-custom.conf
#   geoip   off → ipset flush ru_cidrs

readonly BRIDGE_SETTINGS_FILE='/etc/groxy/bridge/settings.env'

# Ensure settings.env exists with all three keys set to 'on'. Doesn't
# touch user edits — only fills missing keys.
bridge_ensure_settings() {
    mkdir -p "$(dirname "${BRIDGE_SETTINGS_FILE}")"
    local WHITELIST_OPENCCK='' WHITELIST_CUSTOM='' WHITELIST_GEOIP=''
    if [[ -f "${BRIDGE_SETTINGS_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${BRIDGE_SETTINGS_FILE}"
    fi
    [[ -n "${WHITELIST_OPENCCK}" ]] || WHITELIST_OPENCCK='on'
    [[ -n "${WHITELIST_CUSTOM}" ]]  || WHITELIST_CUSTOM='on'
    [[ -n "${WHITELIST_GEOIP}" ]]   || WHITELIST_GEOIP='on'

    write_atomic "${BRIDGE_SETTINGS_FILE}" 644 <<EOF
# Managed by groxy. Edit via 'groxy bridge settings set <key> on|off'.
WHITELIST_OPENCCK=${WHITELIST_OPENCCK}
WHITELIST_CUSTOM=${WHITELIST_CUSTOM}
WHITELIST_GEOIP=${WHITELIST_GEOIP}
EOF
}

# Load settings into caller's scope (caller must declare locals first or
# accept globals).
bridge_settings_load() {
    WHITELIST_OPENCCK='on'
    WHITELIST_CUSTOM='on'
    WHITELIST_GEOIP='on'
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
        *) return 1 ;;
    esac
}

# Reconcile system state with current settings. Run after settings change
# or at init.
bridge_apply_settings() {
    local WHITELIST_OPENCCK WHITELIST_CUSTOM WHITELIST_GEOIP
    bridge_settings_load

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
}

# `groxy bridge settings get` — print all current settings.
bridge_settings_get() {
    require_root
    [[ -f "${BRIDGE_SETTINGS_FILE}" ]] \
        || die "settings not initialised — run 'groxy init bridge' first"
    local WHITELIST_OPENCCK WHITELIST_CUSTOM WHITELIST_GEOIP
    bridge_settings_load
    printf '%-10s %s\n' 'opencck' "${WHITELIST_OPENCCK}"
    printf '%-10s %s\n' 'custom'  "${WHITELIST_CUSTOM}"
    printf '%-10s %s\n' 'geoip'   "${WHITELIST_GEOIP}"
}

# `groxy bridge settings set <key> <on|off>`.
bridge_settings_set() {
    require_root
    local key="${1:-}" value="${2:-}"
    [[ -n "${key}" && -n "${value}" ]] \
        || die "usage: groxy bridge settings set <opencck|custom|geoip> <on|off>"

    local env_key
    env_key=$(_bridge_settings_resolve_key "${key}") \
        || die "unknown key '${key}' (expected: opencck|custom|geoip)"

    case "${value}" in
        on|off) ;;
        *) die "value must be 'on' or 'off' (got '${value}')" ;;
    esac

    # Read current settings, patch one key, write back.
    local WHITELIST_OPENCCK WHITELIST_CUSTOM WHITELIST_GEOIP
    bridge_settings_load
    printf -v "${env_key}" '%s' "${value}"

    write_atomic "${BRIDGE_SETTINGS_FILE}" 644 <<EOF
# Managed by groxy. Edit via 'groxy bridge settings set <key> on|off'.
WHITELIST_OPENCCK=${WHITELIST_OPENCCK}
WHITELIST_CUSTOM=${WHITELIST_CUSTOM}
WHITELIST_GEOIP=${WHITELIST_GEOIP}
EOF
    log "set ${env_key}=${value}"

    log "applying settings to system state"
    bridge_apply_settings
}
