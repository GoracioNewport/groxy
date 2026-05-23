---
name: groxy
description: Manage a groxy two-tier WireGuard VPN — install portal or bridge on a VPS, add/remove WireGuard client users, switch between portals (failover), diagnose tunnel/whitelist/handshake issues. Use when the user mentions groxy, asks to set up the RU-bypass VPN described in this repo, manages WireGuard clients on a groxy bridge, or troubleshoots a groxy installation.
---

# groxy — VPN management

You are helping the user operate a groxy installation: a two-tier WireGuard tunnel where a Russian-side **bridge** VPS accepts clients and selectively routes their traffic either direct (RU domains/IPs → bridge's IP) or via a foreign-side **portal** VPS (everything else → portal's IP).

Read the [project README](../../../README.md) for the architecture, the commands, and the file layout. This skill is a workflow guide on top of that.

## Before you do anything

- **Confirm the user has SSH access to the relevant VPS(es)**. Most operations are SSH-driven (`ssh root@portal`, `ssh root@bridge`). If they don't have SSH, you can't do anything useful.
- **Confirm OS**: Debian 12 or 13. Other distros emit a warning but may still work; flag it.
- **Confirm role of each VPS**: portal (foreign, e.g. Frankfurt, Stockholm, Helsinki) vs. bridge (Russian, e.g. Moscow). Roles can't be swapped after init without uninstall.
- **Two VPSes are required** for a full install. A single VPS can't be both.
- Operations that change state (init, add-bridge, accept-bridge, add-client, remove-portal, settings set, uninstall) **mutate the user's infrastructure**. Always say what you're about to do before you run it on a fresh-to-you VPS.

## Workflows

### Fresh install (no groxy on either VPS)

1. **Portal first** (the foreign VPS):
   ```sh
   ssh root@<portal-vps>
   apt update && apt install -y git
   git clone https://github.com/GoracioNewport/groxy /opt/groxy
   /opt/groxy/groxy init portal
   ```
   This is idempotent — safe to re-run.

2. **Generate the bridge profile on the portal**:
   ```sh
   /opt/groxy/groxy portal add-bridge <bridge-name> > /root/<bridge-name>.profile
   ```
   The profile contains a preshared key. Treat it as a secret.

3. **Move the profile to the bridge**. Prefer `scp` between the two VPSes if they can reach each other, else pipe via your machine. Do not paste it through chat or screen-share.
   ```sh
   ssh root@<portal-vps> "cat /root/<bridge-name>.profile" | \
     ssh root@<bridge-vps> "cat > /root/<bridge-name>.profile"
   ```

4. **Initialise the bridge**:
   ```sh
   ssh root@<bridge-vps>
   apt update && apt install -y git
   git clone https://github.com/GoracioNewport/groxy /opt/groxy
   /opt/groxy/groxy init bridge --portal-profile=/root/<bridge-name>.profile
   ```
   The last line of stdout is the bridge's public key. Capture it.

5. **Activate the peer on the portal**:
   ```sh
   ssh root@<portal-vps>
   /opt/groxy/groxy portal accept-bridge <bridge-name> --pubkey=<bridge-pubkey>
   ```

6. **Verify** — wait ~25 seconds for handshake, then on either side:
   ```sh
   wg show
   ```
   `latest handshake` should be recent. If `(never)`, see Diagnostics below.

### Add a client (end-user device)

```sh
ssh root@<bridge-vps>
/opt/groxy/groxy bridge add-client <name> --qr > /root/<name>.conf
```

- `--qr` prints a scannable QR to **stderr** while stdout stays a clean WireGuard config (so the `> file.conf` redirect works).
- For mobile: tell the user to scan the QR with the WireGuard app.
- For desktop: copy `/root/<name>.conf` to their machine and import into the WireGuard app.

After client connects, verify on the client:
```sh
curl https://api.ipify.org    # should return PORTAL's public IP
curl https://yandex.ru/internet  # should return BRIDGE's public IP
```

### Remove a client

```sh
ssh root@<bridge-vps>
/opt/groxy/groxy bridge remove-client <name> --yes
```

The client's WireGuard config becomes useless immediately (peer entry removed from wg0).

### List clients

```sh
ssh root@<bridge-vps>
/opt/groxy/groxy bridge list-clients
```

### Multi-portal: add failover portal

When the user wants a backup portal:

1. Spin up a second foreign VPS, install groxy on it as portal (same as step 1 above).
2. On the new portal: `portal add-bridge <bridge-name>` and capture the profile.
3. Move the profile to the bridge.
4. On the bridge: `bridge add-portal <portal-alias> --profile=/root/<file>` — registers without switching. Capture the printed bridge pubkey.
5. On the new portal: `portal accept-bridge <bridge-name> --pubkey=<pubkey>`.
6. To switch active: `bridge use-portal <portal-alias>` on the bridge. Handshake converges in ~25s; client wg0 sessions are unaffected.

### Whitelist tweaks

- **Add a domain to direct routing**: edit `/etc/groxy/bridge/whitelist/custom.txt`, then `groxy bridge whitelist reload`.
  - Wildcards: `*.example.com` and `example.com` are equivalent (dnsmasq suffix-matches both).
- **Force-refresh the cron feed** (opencck): `groxy bridge whitelist update`.
- **Refresh GeoIP CIDRs**: `groxy bridge geoip update`.
- **Change feed sources**:
  - `groxy bridge whitelist set-source <url>` — opencck-style domain list.
  - `groxy bridge geoip set-source <url>` — CIDR list.

### Toggle a feed off

```sh
groxy bridge settings set <opencck|custom|geoip> off
```

`off` immediately removes the corresponding `/etc/dnsmasq.d/*-...conf` (for DNS-based feeds) or flushes `ru_cidrs` ipset (for GeoIP). No restart needed.

### Uninstall

```sh
ssh root@<vps>
/opt/groxy/groxy uninstall --yes
```

- Stops + disables all managed services.
- Removes rendered files.
- Backs up `/etc/groxy/` → `/etc/groxy.bak.<timestamp>`.
- **Does NOT** uninstall apt packages (wireguard, dnsmasq, ipset, qrencode, iptables, curl).
- Without `--yes`, prompts interactively (won't work over non-tty SSH; always pass `--yes` from scripts).

## Diagnostics

### First step always: `groxy status`

```sh
ssh root@<bridge-vps>
/opt/groxy/groxy status
```

It prints role, services with `[OK]/[WARN]/[FAIL]`, handshake ages, ipset sizes, last-fetch timestamps, and a Warnings section. Read the Warnings — they point at common issues.

### Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| wg1 handshake `(never)` or `>3min ago` | Portal unreachable, firewall blocking UDP, or bridge wasn't accepted on portal | Check portal is up; check `portal list-bridges` shows this bridge as `active`; check UDP/`LISTEN_PORT` reachable from bridge to portal |
| Client connects to wg0 but no internet | wg0 forwarding broken | Check `iptables -t nat -L POSTROUTING -n` has both wg1-MASQUERADE and `! -o wg1` egress-MASQUERADE. Check `sysctl net.ipv4.ip_forward` is 1. |
| RU sites show foreign IP | DNS bypass: client used DoH or specified non-bridge DNS | Confirm client's config has `DNS = 10.66.66.1`. If browser has DoH on, RU-domain match falls back to GeoIP only. |
| `dnsmasq` failed to start after edit | Hand-edited a managed file with bad syntax | Run `groxy apply` to regenerate. Or fix the managed file at `/etc/groxy/bridge/whitelist/` and re-render. |
| `vpn_domains` is empty but list has entries | dnsmasq cache wasn't flushed when whitelist changed | `groxy bridge whitelist reload` (full restart, not SIGHUP — see commit 27ff895) |
| `ru_cidrs` is empty | GeoIP feed failed to fetch OR `geoip` toggle is off | Check `groxy bridge settings get`. If on, run `groxy bridge geoip update` manually and read its output. |

### Manual probes

```sh
# Is a specific IP in the carve-out path?
ipset test vpn_domains 77.88.55.55   # exit 0 = yes
ipset test ru_cidrs   77.88.55.55    # exit 0 = yes

# What does dnsmasq currently know?
ipset list vpn_domains | head

# Where does kernel say a client packet would go?
ip route get 1.1.1.1 from 10.66.66.99 iif wg0 mark 0x1   # → table vpn2 (via wg1)
ip route get 77.88.55.55 from 10.66.66.99 iif wg0        # → main (direct egress)

# Live tunnel traffic counters:
wg show
```

### Recovery: rebuild everything from state

If rendered configs got corrupted or out of sync:
```sh
groxy apply
```

This re-renders all the managed files from `/etc/groxy/` state and restarts services. Idempotent and safe.

### Restore from a uninstall backup

```sh
# After accidental uninstall:
ls -d /etc/groxy.bak.*                              # find the backup
mv /etc/groxy.bak.<timestamp> /etc/groxy            # restore state
# Re-init does NOT regenerate keypairs if private.key already exists:
groxy init <portal|bridge> [args]
```

For a bridge, this preserves the wg1 keypair so the portal-side peer entry still matches — no need to re-do `accept-bridge`.

## Tone and care

- **For destructive ops** (remove-bridge, remove-client, remove-portal, uninstall, settings set X off), describe the effect, then run with `--yes`.
- **For network-affecting ops** (init, use-portal, apply), tell the user the wg-tunnels will momentarily restart (handshake ~25s to reconverge).
- **Never paste preshared keys / private keys in chat output**. If displaying a `portal profile`, warn that it contains a PSK.

## What this skill does NOT do

- Provision VPSes (Hetzner/aeza/Vultr API calls). User does that.
- Manage DNS for the bridge/portal hostnames. Use raw IPs.
- Configure firewall on the VPS hosts beyond what groxy itself does.
- Bypass DPI or hide WireGuard as HTTPS. Out of scope.
