#!/usr/bin/env bash
# WireGuard helpers — keypair generation, service control. Sourced by the
# dispatcher; do not execute directly.

# Ensure a WG keypair exists in <dir>. Creates the dir at mode 700, writes
# private.key (600) and public.key (644). No-op on the private key if it
# already exists; public.key is always re-derived to stay in sync.
wg_ensure_keypair() {
    local dir="$1"
    mkdir -p "${dir}"
    chmod 700 "${dir}"
    if [[ ! -s "${dir}/private.key" ]]; then
        # Isolate umask in a subshell so the parent's value is unchanged.
        ( umask 077; wg genkey > "${dir}/private.key" )
    fi
    chmod 600 "${dir}/private.key"
    wg pubkey < "${dir}/private.key" > "${dir}/public.key"
    chmod 644 "${dir}/public.key"
}

# Enable a wg-quick@<iface> unit and either start it or restart it to pick up
# config changes.
wg_quick_enable_restart() {
    local iface="$1"
    systemctl enable "wg-quick@${iface}" >/dev/null 2>&1
    if systemctl is-active --quiet "wg-quick@${iface}"; then
        systemctl restart "wg-quick@${iface}"
    else
        systemctl start "wg-quick@${iface}"
    fi
}
