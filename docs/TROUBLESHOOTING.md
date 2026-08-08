# Naaf — operations & troubleshooting

Practical knowledge for running Naaf on a real Debian 13 host. Pairs with
`deploy/DEPLOY.md` (the deploy runbook) and `AGENTS.md` (conventions/boundaries).

---

## 0. The layered-firewall gotcha (read this first)

**Many Debian cloud images ship `ufw` installed with `ufw.service` enabled.** Its
`iptables-nft` tables (`ip filter`, `ip6 filter`) sit on the *same* input/forward
netfilter hooks as our `inet filter` / `inet naaf` tables and **silently drop**:

- inbound **udp/51820** → clients never complete a handshake
- **udp/53 arriving on `wg0`** → tunnel DNS (`DNS = 10.8.0.1`) times out
- **forwarded traffic** → full-tunnel TCP dies (ICMP may still pass)

This happens **even though `ufw status` reads "inactive"** — the rules are loaded in
the kernel regardless, and `ufw.service` re-applies them on every boot, so a one-off
`nft flush ruleset` does not stick.

The provisioning (`deploy/provision/20-system.sh`) now disables it:

```bash
ufw --force disable
systemctl disable --now ufw && systemctl mask ufw
nft delete table ip filter 2>/dev/null; nft delete table ip6 filter 2>/dev/null
```

**Invariant:** `nft list tables` on a healthy box shows **only** `inet filter` and
`inet naaf`. If you ever see `ip filter` / `ip6 filter`, ufw is back — that is a bug.

Why it was so hard to see: a WireGuard client in a **network namespace on the box**
(arriving via a veth, not the WAN NIC) is *not* blocked and handshakes fine, so the
server looks healthy while every real external client fails.

---

## 1. Playbook: a client can't connect / DNS fails / full-tunnel is dead

Work outward from the server. Each step tells you where the packet dies.

**1. Is the peer in the running interface?**
```bash
sudo wg show wg0                 # is the client's pubkey a peer? handshake? transfer?
sudo sqlite3 /var/lib/naaf/naaf.db 'select name,wg_ip,enabled,substr(pubkey,1,12) from clients;'
```
No peer → the DB/apply path is the problem (check `journalctl -u naaf`). Peer present
but no handshake/transfer → keep going.

**2. Do the client's handshake packets reach the NIC?** (tcpdump captures *before*
netfilter, so "seen here" ≠ "delivered".)
```bash
sudo timeout 15 tcpdump -n -i any udp port 51820
```
Nothing → the client isn't sending (tunnel inactive, or its network blocks outbound
udp/51820), or your provider's network firewall lacks the rule. Packets arrive → keep going.

**3. Do they reach the UDP layer?** This is the decisive counter.
```bash
grep ^Udp: /proc/net/snmp        # watch InDatagrams before/after
```
`InDatagrams` **not** incrementing while packets arrive = dropped between NIC and
socket = **a firewall table**. Check for the ufw tables (section 0):
```bash
sudo nft list tables             # want ONLY: inet filter, inet naaf
```
`InErrors`/`InCsumErrors` incrementing instead = a UDP-layer/checksum problem.

**4. Does WireGuard itself see it?**
```bash
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null
echo 'module wireguard +p' | sudo tee /sys/kernel/debug/dynamic_debug/control
sudo dmesg -C; sleep 10; sudo dmesg | grep -i wireguard
echo 'module wireguard -p' | sudo tee /sys/kernel/debug/dynamic_debug/control
```
`Receiving handshake initiation from peer N` = wg0 is processing it (good).
`Invalid MAC of handshake` = the client has the **wrong server public key** (compare
its `[Peer] PublicKey` to `select server_pubkey from settings`). Silence with packets
arriving = they're being dropped before the socket (back to step 3).

**5. Reachability sanity checks (from the server):**
```bash
sudo wg show wg0 listen-port                 # 51820
sudo ip route get <client-public-ip>         # reverse path via enp1s0
sysctl net.ipv4.ip_forward                   # must be 1
sudo nft list table inet naaf                # masquerade + spoke policy present?
```

**6. DNS timing out from a client but not locally?** Almost always the ufw block on
`wg0`-ingress udp/53. From the server the resolver works because the query is local:
```bash
dig +short @10.8.0.1 example.com             # external via upstream
dig +short @10.8.0.1 <hostname>.vpn          # internal zone
```
If these work but a *client's* DNS doesn't, suspect the firewall (section 0).

---

## 2. In-box reproduction: a real client without touching the server firewall

The most reliable end-to-end test — a genuine WireGuard client in a netns, which
exercises the server's *decrypted* input/forward path exactly like a real client
(handshake arrives via a veth so it isn't subject to the WAN-facing firewall). Use it
to prove wg0/DNS/forwarding health independent of any external client:

```bash
SERVER_IP=<the box's public IP>      # e.g. the value in `ip -4 addr show` for the WAN iface
DB=/var/lib/naaf/naaf.db
SPUB=$(sqlite3 "$DB" 'select server_pubkey from settings;')
PRIV=$(wg genkey); PUB=$(echo "$PRIV"|wg pubkey); PSK=$(wg genpsk)
sqlite3 "$DB" "insert into clients (name,hostname,wg_ip,pubkey,psk,enabled,created_at)
  values ('nstest','nstest','10.8.0.250','$PUB','$PSK',1,datetime('now'));"
cd /opt/naaf && runuser -u naaf -- env BUNDLE_GEMFILE=/opt/naaf/Gemfile HOME=/var/lib/naaf \
  PATH=/opt/rubies/ruby-4.0.6/bin:/usr/sbin:/usr/bin:/bin \
  ruby -e 'require "console";$LOAD_PATH.unshift("lib");require "naaf/db";require "naaf/zone";require "naaf/reconciler";Naaf::Reconciler.new(Naaf.db,Naaf::Zone.new(Naaf.db)).apply!'

ip netns add c1
ip link add veth-h type veth peer name veth-c; ip link set veth-c netns c1
ip addr add 172.31.0.1/30 dev veth-h; ip link set veth-h up
ip netns exec c1 sh -c 'ip link set lo up; ip addr add 172.31.0.2/30 dev veth-c; ip link set veth-c up'
ip link add wgc type wireguard; ip link set wgc netns c1
ip netns exec c1 wg set wgc private-key <(printf %s "$PRIV") peer "$SPUB" \
  preshared-key <(printf %s "$PSK") endpoint "$SERVER_IP:51820" allowed-ips 0.0.0.0/0 persistent-keepalive 25
ip netns exec c1 sh -c "ip addr add 10.8.0.250/32 dev wgc; ip link set wgc up
  ip route add $SERVER_IP/32 via 172.31.0.1 dev veth-c; ip route add default dev wgc"
sleep 3
ip netns exec c1 wg show wgc | grep -E 'handshake|transfer'   # handshake?
ip netns exec c1 ping -c2 10.8.0.1                            # gateway
ip netns exec c1 dig +short @10.8.0.1 example.com            # tunnel DNS
ip netns exec c1 curl -s -o /dev/null -w '%{http_code}\n' http://1.1.1.1   # full-tunnel TCP

# cleanup
ip netns del c1; ip link del veth-h; sqlite3 "$DB" "delete from clients where name='nstest';"
# then re-apply so the peer is removed from wg0 (same ruby -e apply! as above)
```

If this passes but a real client fails, the problem is the WAN-facing firewall
(section 0) or the client's own network.

---

## 3. Provisioning gotchas (encoded in `deploy/provision/*`, documented here)

These were found bringing the first box up live; the scripts already handle them.

| Gotcha | Where | Fix |
|---|---|---|
| `ufw` drops WireGuard/DNS/forwarding | `20-system.sh` | disable + mask ufw, delete its tables |
| `ruby-install` URL 404s (asset is versioned) | `30-ruby.sh` | resolve download URL via the GitHub releases API |
| `bundle exec ruby` → `command not found: ruby` | `00-lib.sh` | put `/opt/rubies/ruby-4.0.6/bin` on `PATH` |
| helper socket `EACCES` for the app | `deploy/naaf-helper.service` | `Group=naaf` so `RuntimeDirectory` makes `/run/naaf` root:naaf |
| app dies on first boot (wg0 not up yet) | `bin/naaf`, sysctl, `50-bringup.sh` | rescue boot `apply!`; `net.ipv4.ip_nonlocal_bind=1`; restart naaf after wg-quick |
| Ruby 4.0 compile OOMs on 1 GB | `05-swap.sh` | 2 GB swapfile before the build |
| bootstrap re-keys on re-run (destructive) | `50-bringup.sh` | skip bootstrap when `server_pubkey` already set |

**Boot ordering:** `naaf.service` is `After=wg-quick@wg0.service` (not `Requires`), so
on normal reboots systemd raises `wg0` before the app. Only the *first* bring-up starts
the app before `wg0` exists — hence the rescue + `ip_nonlocal_bind` + post-wg-quick
restart. `wg0.conf` is written by the app's boot `apply!` (the helper writes the file
before `wg syncconf`, which is expected to fail the first time with no interface).

---

## 4. Access / SSH keys note (for automated ops)

If the SSH key registered with your provider lives only in an **agent that can't be
unlocked non-interactively** (a password manager's SSH agent, a smartcard, a
hardware token), an unattended deploy will stall on approval prompts. Generate a
throwaway on-disk keypair, register its public key with the provider, and drive SSH
with `-o IdentitiesOnly=yes -o IdentityAgent=none -i <key>` so nothing touches the
agent — this is exactly what `./deploy.sh` does when `NAAF_SSH_KEY` is set.
Install it *alongside* your normal key so you keep interactive access, and remove it
when the deploy is done.
