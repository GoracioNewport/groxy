#!/usr/bin/env bash
# Shared helpers. Sourced by the groxy dispatcher and lib modules.
# Do not execute directly.

# Root of the declarative state. Overridable via env for testing.
readonly GROXY_DIR="${GROXY_DIR:-/etc/groxy}"

# Where rendered WireGuard configs land. Overridable for the same reason: the
# render path is where a corrupt peer file does its damage, and a hardcoded
# /etc/wireguard meant no test could watch it happen.
readonly GROXY_WG_DIR="${GROXY_WG_DIR:-/etc/wireguard}"

# Log to stderr with an ISO-8601 timestamp.
log() {
    printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" >&2
}

# Log an error and exit with a non-zero status.
die() {
    log "error: $*"
    exit 1
}

# Exit with a chosen status so a caller can tell outcomes apart instead of
# parsing text. A bot that times out mid-command needs to distinguish "the
# name is already taken" from "something broke" to decide whether retrying
# is safe.
#
# Values start at 10 on purpose. Low codes are crowded: `systemctl is-active`
# alone returns 3, and under `set -e` any command's status can surface as the
# function's own. A caller told "3 means the name is taken" would eventually
# act on a leaked status from something else entirely.
readonly GROXY_EXIT_EXISTS=10   # имя уже занято
readonly GROXY_EXIT_BUSY=11     # другая операция держит блокировку
die_code() {
    local code="$1"; shift
    log "error: $*"
    exit "${code}"
}

# Serialise state-changing operations across processes.
#
# Nothing in v1 took a lock, so two concurrent `add-client` runs both read
# the peer list, both pick the same free octet and hand one address to two
# clients — WireGuard then routes by whichever peer matches AllowedIPs and
# the breakage is silent. A human rarely raced himself; a bot with a retry
# button does it easily.
#
# The lock lives on fd 9 for the life of the process, so it is released on
# exit however we leave — including die().
# Contention gets its own status: waiting out someone else's operation is the
# safest possible outcome to retry, and collapsing it into the generic failure
# code meant a routine collision looked exactly like a broken bridge.
#
# Calling it twice in one process is a no-op rather than a re-open. Re-running
# `exec 9>` closes the previous descriptor first, and closing the last
# descriptor of an open file description releases the lock — leaving a window
# in which another process can take it.
#
# The path is overridable so the test suite can exercise real mutual exclusion
# instead of stubbing the function out.
GROXY_LOCK_HELD=0
acquire_state_lock() {
    (( GROXY_LOCK_HELD )) && return 0
    local lock="${GROXY_LOCK:-/run/groxy.lock}"
    local wait="${GROXY_LOCK_WAIT:-30}"
    exec 9>"${lock}" || die "cannot open lock file ${lock}"
    flock -w "${wait}" 9 || die_code "${GROXY_EXIT_BUSY}" \
        "another groxy operation is in progress (waited ${wait}s)"
    GROXY_LOCK_HELD=1
}

# Abort unless the effective UID is root.
require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "this command must be run as root (use sudo)"
    fi
}

# Return 0 if a command is present in PATH.
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Validate a peer name (used for both portal-bridges and bridge-portals).
# Allowed: alnum/dot/dash/underscore, 1-63 chars, first char alnum.
validate_peer_name() {
    local name="$1"
    if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
        die "invalid peer name '${name}' (allowed: [A-Za-z0-9._-], 1-63 chars, alnum first)"
    fi
}

# Read one KEY=VALUE field from a state file without executing it.
#
# Peer files are state, not code, but they were read with `source`. One
# corrupted or hand-restored file could then redefine the caller's own
# variables: a peer file containing `sep=` was enough to break the JSON output
# for every client at once, not just its own entry. Nothing in these files
# needs shell evaluation — they are flat KEY=VALUE.
#
# Prints the value, or nothing if the key is absent.
# `-a` обязателен. Без него один NUL-байт в файле переводит grep в бинарный
# режим: он возвращает пустую строку с кодом 0, то есть «поле отсутствует», а
# не «файл повреждён». Проверено на живом бридже с GNU grep 3.8. Прежний
# `source` такой файл читал корректно, так что отказ от него без этого флага
# был бы разменом одной поломки на другую, потише и потому опаснее.
peer_field() {
    local file="$1" key="$2" line
    line=$(grep -a -m1 "^${key}=" "${file}" 2>/dev/null) || return 0
    printf '%s\n' "${line#*=}"
}

# Validate a WireGuard key — public, private or preshared. All are 32-byte
# base64 strings: 43 chars from [A-Za-z0-9+/] plus a trailing '='.
validate_wg_key() {
    local key="$1" label="${2:-key}"
    if [[ ! "${key}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        die "invalid WireGuard ${label}: '${key}'"
    fi
}
