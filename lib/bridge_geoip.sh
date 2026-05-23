#!/usr/bin/env bash
# Bridge GeoIP — RU CIDR list fetcher and ru_cidrs ipset populator.
# Sourced by the dispatcher; do not execute directly.
#
# The mangle PREROUTING rule "ru_cidrs match → mark=0x0" makes packets
# destined for any IP in this set go direct (not through portal). The
# set is rebuilt atomically from a fetched newline-separated list of
# CIDRs (e.g., github.com/herrbischoff/country-ip-blocks/ipv4/ru.cidr).

readonly BRIDGE_DEFAULT_GEOIP_URL='https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr'

# Seed geoip files with defaults on first init. Doesn't touch user edits.
bridge_ensure_geoip_dir() {
    local dir="${GROXY_DIR}/bridge/whitelist"
    mkdir -p "${dir}"
    if [[ ! -f "${dir}/geoip-source-url" ]]; then
        printf '%s\n' "${BRIDGE_DEFAULT_GEOIP_URL}" > "${dir}/geoip-source-url"
        log "seeded ${dir}/geoip-source-url with default herrbischoff/country-ip-blocks URL"
    fi
    [[ -f "${dir}/ru_cidrs.list" ]] || : > "${dir}/ru_cidrs.list"
    chmod 600 "${dir}/geoip-source-url" "${dir}/ru_cidrs.list"
}

# Atomically rebuild the ru_cidrs ipset from
# ${GROXY_DIR}/bridge/whitelist/ru_cidrs.list.
# Uses the create+swap+destroy idiom so concurrent iptables -m set lookups
# never see a half-populated set.
bridge_populate_ru_cidrs() {
    local src="${GROXY_DIR}/bridge/whitelist/ru_cidrs.list"
    if [[ ! -s "${src}" ]]; then
        log "ru_cidrs list empty; flushing ipset"
        ipset flush ru_cidrs 2>/dev/null || true
        return 0
    fi

    local tmp accepted=0 rejected=0
    tmp=$(mktemp)
    {
        printf 'create ru_cidrs_new hash:net family inet hashsize 1024 maxelem 131072\n'
        local line
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" ]]      && continue
            [[ "${line}" == \#* ]]  && continue
            if [[ "${line}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
                printf 'add ru_cidrs_new %s\n' "${line}"
                accepted=$((accepted + 1))
            else
                rejected=$((rejected + 1))
            fi
        done < "${src}"
        printf 'swap ru_cidrs ru_cidrs_new\n'
        printf 'destroy ru_cidrs_new\n'
    } > "${tmp}"

    if ! ipset restore -exist -f "${tmp}" 2>/tmp/groxy-geoip.err; then
        log "warning: ipset restore failed:"
        cat /tmp/groxy-geoip.err >&2
        rm -f "${tmp}" /tmp/groxy-geoip.err
        return 1
    fi
    rm -f "${tmp}" /tmp/groxy-geoip.err
    log "populated ru_cidrs: ${accepted} CIDRs accepted, ${rejected} rejected as malformed"
}

# `groxy bridge geoip set-source <url>` — persist a new CIDR list URL.
bridge_geoip_set_source() {
    require_root
    local arg url=''
    for arg in "$@"; do
        case "${arg}" in
            http://*|https://*)
                [[ -z "${url}" ]] || die "geoip set-source: extra argument '${arg}'"
                url="${arg}"
                ;;
            *) die "geoip set-source: expected an http(s) URL, got '${arg}'" ;;
        esac
    done
    [[ -n "${url}" ]] || die "usage: groxy bridge geoip set-source <http(s)-url>"

    local dst="${GROXY_DIR}/bridge/whitelist/geoip-source-url"
    mkdir -p "$(dirname "${dst}")"
    printf '%s\n' "${url}" | write_atomic "${dst}" 600
    log "set GeoIP CIDR source URL: ${url}"
}

# `groxy bridge geoip update` — fetch the configured URL, replace
# ru_cidrs.list atomically, rebuild the ru_cidrs ipset.
# Treats fetch failures as soft: keeps previous list intact.
bridge_geoip_update() {
    require_root
    local dir="${GROXY_DIR}/bridge/whitelist"
    [[ -d "${dir}" ]] || die "bridge whitelist not initialised — run 'groxy init bridge' first"

    local url=''
    [[ -f "${dir}/geoip-source-url" ]] && url=$(<"${dir}/geoip-source-url")
    url="${url//[$'\n\r']/}"
    if [[ -z "${url}" ]]; then
        log "no GeoIP source URL set (use 'bridge geoip set-source <url>'); skipping"
        return 0
    fi

    log "fetching RU CIDR list from ${url}"
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL --max-time 60 "${url}" -o "${tmp}"; then
        rm -f "${tmp}"
        log "warning: fetch failed, keeping previous list"
        return 0
    fi
    if [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}"
        log "warning: fetched list is empty, keeping previous"
        return 0
    fi

    log "fetched $(wc -l < "${tmp}") lines"
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${dir}/ru_cidrs.list"

    bridge_populate_ru_cidrs
}
