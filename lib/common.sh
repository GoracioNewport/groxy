#!/usr/bin/env bash
# Shared helpers. Sourced by the cascade-vpn dispatcher and lib modules.
# Do not execute directly.

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
        die "this command must be run as root (try: sudo $0 $*)"
    fi
}

# Return 0 if a command is present in PATH.
has_command() {
    command -v "$1" >/dev/null 2>&1
}
