#!/usr/bin/env bash
# Bridge ipset & policy-routing scaffolding. Sourced by the dispatcher;
# do not execute directly.
#
# The bridge's mangle PREROUTING uses two ipsets:
#   vpn_domains  hash:ip   — IPs resolved by dnsmasq for whitelisted domains
#   ru_cidrs     hash:net  — CIDR ranges geolocated as Russia (GeoIP feed)
# Both are pre-created (empty) here so wg1's mangle rules can reference
# them before the corresponding feeds run.

# Ensure routing table 200 'vpn2' is declared in /etc/iproute2/rt_tables.
# Creates the file (and its parent directory) on systems that ship without
# it — e.g., Debian 13 trixie omits both by default.
bridge_ensure_rt_table() {
    local file=/etc/iproute2/rt_tables
    mkdir -p /etc/iproute2
    if [[ ! -f "${file}" ]] \
        || ! grep -qE '^[[:space:]]*200[[:space:]]+vpn2[[:space:]]*$' "${file}"; then
        printf '200 vpn2\n' >> "${file}"
        log "added 'vpn2' (table 200) to ${file}"
    fi
}

# Ensure /etc/ipset/ipset.conf exists with create-lines for both ipsets.
# Doesn't touch existing content — preserves data between runs.
bridge_ensure_ipset_conf() {
    local file=/etc/ipset/ipset.conf
    mkdir -p /etc/ipset
    if [[ ! -f "${file}" ]]; then
        cat > "${file}" <<'EOF'
create vpn_domains hash:ip family inet hashsize 1024 maxelem 65536
create ru_cidrs hash:net family inet hashsize 1024 maxelem 131072
EOF
        chmod 600 "${file}"
        log "initialised ${file}"
    fi
}

# Ensure both ipsets exist in the running kernel. Idempotent via -exist.
bridge_ensure_ipsets_loaded() {
    ipset create vpn_domains hash:ip   family inet hashsize 1024 maxelem 65536  -exist
    ipset create ru_cidrs    hash:net  family inet hashsize 1024 maxelem 131072 -exist
}

# Install/enable ipset-restore.service. The Before= on wg-quick@wg1 makes
# sure ipsets exist before wg1's PostUp tries to match against them. The
# ExecStop saves current ipset state so updates between boots persist.
bridge_install_ipset_restore_service() {
    cat > /etc/systemd/system/ipset-restore.service <<'EOF'
[Unit]
Description=Restore groxy ipsets
Before=wg-quick@wg1.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipset restore -exist -f /etc/ipset/ipset.conf
ExecStop=/bin/sh -c '/sbin/ipset save > /etc/ipset/ipset.conf'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ipset-restore.service >/dev/null 2>&1
    systemctl start ipset-restore.service
}

# Top-level: install ipset, set up routing table, ipset config, and
# the restore service. Idempotent.
bridge_init_ipset() {
    apt_install ipset
    bridge_ensure_rt_table
    bridge_ensure_ipset_conf
    bridge_install_ipset_restore_service
    bridge_ensure_ipsets_loaded
}
