#!/usr/bin/env bash
# Shared helpers. Sourced by the groxy dispatcher and lib modules.
# Do not execute directly.

# Root of the declarative state. Overridable via env for testing.
readonly GROXY_DIR="${GROXY_DIR:-/etc/groxy}"

# Log to stderr with an ISO-8601 timestamp.
log() {
    printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" >&2
}

# Log an error and exit with a non-zero status.
die() {
    log "error: $*"
    exit 1
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

# Validate a WireGuard key — public, private or preshared. All are 32-byte
# base64 strings: 43 chars from [A-Za-z0-9+/] plus a trailing '='.
validate_wg_key() {
    local key="$1" label="${2:-key}"
    if [[ ! "${key}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        die "invalid WireGuard ${label}: '${key}'"
    fi
}
