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

# Apply peer changes to a running interface without dropping it.
#
# wg_quick_enable_restart tears the interface down first, so every client
# re-handshakes and the kernel's per-peer counters reset — that is why
# issuing one profile knocked all of them offline and why traffic stats
# were never trustworthy. syncconf pushes the diff over netlink instead:
# live sessions and counters survive.
#
# What it does and does not apply: syncconf sets the peers AND the interface
# section it is given — PrivateKey, ListenPort and FwMark included. It does
# NOT touch the interface address (that is `ip addr`, wg-quick's job) and does
# NOT run PostUp/PostDown. So a changed subnet still needs a full restart,
# while a changed listen port would be applied here and would silently strand
# every client whose config still names the old one.
#
# The strip output is written to a file and checked before use, never piped in
# through process substitution: `wg syncconf iface <(wg-quick strip iface)`
# reports only syncconf's own status, so a failed strip goes unnoticed — and an
# empty config is not a no-op for syncconf but a full wipe, removing every peer
# and the interface's private key. Getting that wrong meant a successful-looking
# add-client could disconnect all 36 clients at once.
wg_sync_peers() {
    local iface="$1" tmp
    systemctl enable "wg-quick@${iface}" >/dev/null 2>&1

    if ! systemctl is-active --quiet "wg-quick@${iface}"; then
        systemctl start "wg-quick@${iface}"
        return 0
    fi

    tmp=$(mktemp) || die "cannot create a temporary file for wg syncconf"
    if ! wg-quick strip "${iface}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        die "wg-quick strip ${iface} failed — refusing to sync (an empty config would wipe every peer)"
    fi
    if [[ ! -s "${tmp}" ]] || ! grep -q '^\[Interface\]' "${tmp}"; then
        rm -f "${tmp}"
        die "wg-quick strip ${iface} produced no usable config — refusing to sync"
    fi
    if ! wg syncconf "${iface}" "${tmp}"; then
        rm -f "${tmp}"
        die "wg syncconf ${iface} failed"
    fi
    rm -f "${tmp}"
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
