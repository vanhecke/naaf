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

> **The dashboard charts exactly this.** The **Packet pipeline** strip on `/`
> shows WAN packets/s → UDP datagrams/s delivered to a socket → wg0 packets/s
> out of the tunnel, live. Watch it while you change a rule instead of grepping
> in a loop.
>
> Read the middle number as a hint, not a verdict: `Udp: InDatagrams` is
> host-wide and IPv4-wide, so this box's own DNS replies keep it moving even
> when WireGuard is being dropped. The panel deliberately does **not** claim to
> have detected a firewall. What it does assert is narrower and reliable — if
> peers are enabled, traffic is arriving, and not one peer has handshaked in
> three minutes, it says so in red and points back here.

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

### Two things at step 5 that look like ufw and are not

**Table `inet naaf` missing entirely.** Something loaded `/etc/nftables.conf`,
which opens with `flush ruleset`, without re-applying it. `20-system.sh` pairs
its reload with `systemctl try-restart naaf` for exactly this reason (`bin/naaf`
runs `Reconciler#apply!` at startup), so a hand-run `nft -f /etc/nftables.conf`
or `systemctl reload nftables` is the usual cause. `systemctl restart naaf`, or
`POST /apply`, puts it back. `Reconciler#poll!` will **not** notice on its own —
it re-applies on peer-set drift, and a vanished table is not something it looks
for.

**A port forward sitting on a port the box needs for itself.** A DNAT in
`inet naaf` prerouting runs *before* the routing decision, so a forward on
tcp/22, udp/`listen_port` or tcp/`NAAF_WSTUNNEL_PORT` rewrites packets addressed
to the box and hands them to a client — SSH gone, or every WireGuard handshake
gone, or every ws client gone while the unit still looks healthy. The form
refuses those three now, and refuses re-enabling an existing row on one, but a
row written before that check (or straight into SQLite) is still on disk:
```bash
sudo sqlite3 /var/lib/naaf/naaf.db 'select proto, public_port, target_port, enabled from port_forwards;'
sudo nft list table inet naaf | grep dnat
```
Delete the offending row rather than toggling it. If SSH is already gone, the
provider's serial console is the way back in.

---

## 1a. Playbook: a `split-ws` client will not connect

Only for the two `ws` flavors — WireGuard carried inside a TLS WebSocket
([`WSTUNNEL.md`](WSTUNNEL.md)). This covers the transport *in front of* the
kernel's WireGuard listener; once datagrams reach that listener, §1 applies
unchanged and step 5 is where to rejoin it.

**Before anything else: the first handshake can take up to 5 seconds.** wg-quick
starts the relay and brings the interface up together, so the first
keepalive-triggered handshake can hit a socket the relay has not bound yet.
WireGuard ignores the ICMP error and retries every 5 s. That is expected and it
is not a fault. Zero handshakes after ~15 seconds is.

### Server side — is the transport up and reachable?

```bash
systemctl status naaf-wstunnel --no-pager -l
ss -ltnp '( sport = :443 )'                        # want exactly one listener on [::]:443
sudo nft list table inet filter | grep 'tcp dport 443'
journalctl -u naaf-wstunnel -n 100 --no-pager
```

- **Unit inactive, or no listener** → `NAAF_WSTUNNEL_ENABLED` is not 1, or
  `65-wstunnel` has not run. `./deploy.sh --step 65-wstunnel`.
- **Listener but no firewall rule** → the base firewall is rendered by
  `20-system`, not by 65, so `--step 65-wstunnel` alone never opens the port. A
  plain `./deploy.sh` does both — it renders the file *and* reloads it into the
  kernel, which `enable --now` on its own never did (§3).
- **Both fine and still unreachable from outside** → a provider-level firewall.
  `deploy/providers/vultr/ensure-firewall.sh` *reuses* an existing group without
  reconciling it, so flipping the flag on an existing box leaves Vultr dropping
  tcp/443 while the host happily accepts it.

**Test from off the VPN, or you will get a false pass.** This has bitten:
if the machine you test from is connected to this very VPN, its packets reach
:443 over `wg0` and are accepted by `iifname "wg0" accept` — never touching the
public path at all. `route get <endpoint-ip>` showing a `utun`/`wg` interface
means the test proves nothing. Bind the physical interface, and check a
known-good host first so you know the binding itself works:

```bash
curl --interface en0 --max-time 8 https://github.com/ -o /dev/null   # control
nc -z -G 6 -s <your-lan-ip> <endpoint-ip> 443
```

**The decisive one-line diagnostic** is the drop counter on the host:

```bash
sudo nft list chain inet filter input | tail -1     # -> counter packets N bytes M drop
```

If N is **0** while a client is actively retrying, the packets are not arriving —
the block is upstream of the box, not on it. (A host-level block would show the
counter climbing; a *reject* would give the client `connection refused` rather
than a timeout.)

On Vultr, do **not** trust `vultr-cli firewall group list` — its INSTANCE COUNT
and RULE COUNT columns have been observed reading 0 for a group that is attached
and has rules. The authoritative field is on the instance:

```bash
vultr-cli instance get <id> | grep -i firewall     # FIREWALL GROUP ID
vultr-cli firewall rule list <group-id>            # the rules that actually apply
vultr-cli firewall rule create <group-id> --ip-type v4 --protocol tcp \
  --size 0 --subnet 0.0.0.0 --port 443 --notes "wstunnel v4"
```

The rule takes about 15 seconds to apply at the edge.

Then prove TLS answers, from a machine that is not the box:

```bash
openssl s_client -connect vpn.example.com:443 -servername vpn.example.com </dev/null 2>/dev/null |
  openssl x509 -noout -subject -issuer -dates
```

Four symptoms are distinctive enough to name.

**A · Path-prefix mismatch.** TCP connects, TLS completes, the WebSocket upgrade
is refused, WireGuard never handshakes. The prefix is a shared secret the server
requires on every upgrade, and it is per-*server*, not per-client — so this hits
every config issued before it was regenerated, and none issued after.

```bash
# strip comments first — this unit's comments name the very flags they explain,
# so an unfiltered sed reads the documentation and reports on that instead
systemctl cat naaf-wstunnel | grep -v '^[[:space:]]*#' |
  sed -n 's/.*--restrict-http-upgrade-path-prefix \([^ ]*\).*/\1/p'
grep NAAF_WSTUNNEL_PATH_PREFIX /etc/naaf/wstunnel.env
```

Those two and the `-P` value in a freshly downloaded config must all be the same
string. If the fresh config differs from the unit, the running app is holding a
stale environment — `systemctl restart naaf`, which is what reads
`EnvironmentFile=-/etc/naaf/wstunnel.env`, and it only does so at start. If the
client's config differs, re-download it; there is no way to fix one client from
the server. Do not paste any of these values into a ticket: `./deploy.sh
--verify` deliberately reports `generated` / `wstunnel's default` / `missing`
instead of the value, and so should you.

**B · `--restrict-to` port drift.** The one that wastes a whole afternoon,
because nothing looks wrong: unit active, port open, TLS clean, and not a single
client works. The server's unit takes its forward target from `NAAF_LISTEN_PORT`
in `naaf.conf`; the client's `-L` takes it from `settings.listen_port` in the
database; WireGuard listens on the database's value. Disagree and wstunnel
refuses the destination every client asks for.

```bash
sqlite3 /var/lib/naaf/naaf.db 'select listen_port from settings'
grep ^NAAF_LISTEN_PORT /etc/naaf/naaf.conf
systemctl cat naaf-wstunnel | grep -v '^[[:space:]]*#' | sed -n 's/.*--restrict-to \([^ ]*\).*/\1/p'
```

`deploy/verify.sh` section 8 asserts that pair with an equality test rather than
a substring grep — `5182` would pass a grep against `51820`, which is exactly the
drift it exists to catch. Section 1 already reports the naaf.conf/DB
disagreement, as a WARN; that WARN is the early hint. Fix by making `naaf.conf`
match the database (the database is authoritative everywhere else too), then
`./deploy.sh --sync && ./deploy.sh --step 65-wstunnel`.

**C · An extra route that covers the server's public IP.** A hard hang: no
handshake, no error, no log line on either end. The relay's own TCP session to
`<endpoint>:443` gets routed into the tunnel the relay is carrying.

**For the ws flavors this is now refused at render time**, so the symptom you
actually get is a **500 on the config download** and a message in the journal
naming the route:

```bash
journalctl -u naaf | grep AllowedIPs
#   AllowedIPs route 203.0.113.0/24 contains the endpoint address, …
#   AllowedIPs route 0.0.0.0/0 is a default route, …
```

Only a config downloaded *before* the route was added can still hang this way —
re-download it after fixing the route and the file will be correct or the
download will refuse.

**Plain `split` is still exposed, deliberately** — there it is WireGuard's own UDP
to the endpoint that gets captured, the hazard predates the ws flavors, and it is
a false alarm whenever `endpoint_host` resolves somewhere other than
`endpoint_v4`, so the server logs a warning and renders anyway:

```bash
journalctl -u naaf | grep 'contains the endpoint address'
```

A `/0` is a different matter for plain `split`: wg-quick's `not fwmark <table>`
exemption covers the kernel WireGuard socket, so `split` plus a `/0` route is a
working full tunnel and is not refused. It is only userspace wstunnel that the
exemption misses.

```bash
# on the client
ip route get <server public ip>            # must NOT come back dev <wg interface>
# on the server — what is being folded into every split AllowedIPs
sudo sqlite3 /var/lib/naaf/naaf.db 'select client_id, cidr from extra_routes;'
```

`0.0.0.0/0`, a `/1`, or the hosting provider's own block are the usual culprits.
Remove it on the **Routes** page, or add a more specific route for the endpoint
out the physical interface on the client.

**D · TLS verify / SNI mismatch.** The client log names it and the server
journal shows *nothing at all* — the handshake fails before any upgrade request
exists. That asymmetry is itself the tell.

```bash
sudo grep -i -e tls -e cert -e sni /var/log/naaf-wstunnel.log      # on the client
```

Three shapes:

- `--tls-verify-certificate` against the **self-signed** default. It can never
  pass. Either `NAAF_WSTUNNEL_TLS_VERIFY=on` was set by hand, or `auto` saw
  `NAAF_ACME_ENABLED=1` and the CA never actually issued — `auto` reads the
  *intent* flag, not the installed issuer. The usual case is a bare-IP endpoint
  (no public CA issues for an address), then a missing DNS token or CNAME.
  `./deploy.sh --verify` section 9 fails in the same run for that reason; read
  the issuer with `openssl x509 -in /etc/naaf/certs/<slug>/cert.pem -noout
  -issuer`. Fix the certificate, or pin `NAAF_WSTUNNEL_TLS_VERIFY=off`.
- `--tls-sni-override <name>` *plus* verification, where the box holds no
  certificate for `<name>` — the override also picks the name that gets verified.
  Add the cover name to `NAAF_ACME_DOMAINS` and re-run `60-certs`, or drop the
  verification.
- ACME on, but the **staging** CA issued the certificate. Clients that verify
  reject it and `verify.sh`'s CA-issued check passes happily, because the issuer
  does differ from the subject. Read it yourself —
  `openssl x509 -in /etc/naaf/certs/<slug>/cert.pem -noout -issuer`; `(STAGING)`
  is the answer. [`CERTS.md` §6](CERTS.md).

Related, and easy to misread: **downloading a ws config that returns
`Internal error` (500)** is one of six refusals — a refused TLS combination
(verify on + SNI override + ACME off); a malformed `NAAF_WSTUNNEL_SNI`,
`NAAF_WSTUNNEL_PORT` or `NAAF_WSTUNNEL_TLS_VERIFY`; a missing or malformed path
prefix (`65-wstunnel` has not run — `/clients` shows a banner for this);
an `extra_routes` row that would capture the transport (**C** above); or a box
with neither `endpoint_host` nor `endpoint_v4`, since the ws path dials the v4
family. The real message is always in `journalctl -u naaf`, and the full list is
[`WSTUNNEL.md` §7](WSTUNNEL.md).

A 500 there **does not burn the one-shot private key**: the download route peeks
at the stash, renders, and only spends it once a complete response exists. Fix
the cause and download again — the key is still on offer. A **404** on the same
URL means something else entirely: the flavor is not enabled (or you asked for a
QR, which the ws flavors deliberately do not have).

### Client side — the logfile and the pidfile

```bash
sudo tail -n 50 /var/log/naaf-wstunnel.log          # 0600 root:root, TRUNCATED on every `up`
cat /var/run/naaf-wstunnel-51820.pid
ps -p "$(cat /var/run/naaf-wstunnel-51820.pid)" -o comm=
ss -lunp '( sport = :51820 )'                       # macOS: netstat -an -p udp | grep 51820
sudo wg show
```

- **No log, no pidfile** → the relay never started. Nearly always `wstunnel`
  missing from **root's** `PATH`: check `sudo wstunnel --version`, not
  `wstunnel --version`. The first `PreUp` guard is meant to say so and tear the
  interface back down, so an interface that came up *and* has no log means the
  guard passed and the relay itself failed.
- **Pidfile present, `ps` prints nothing** → the relay started and died; the log
  says why. It is truncated on every `up`, so copy it before retrying.
- **Nothing bound on `127.0.0.1:51820` while the relay is alive** → it is stuck
  retrying the connection to the server. Back to the server-side checks.
- **Bound on `0.0.0.0:51820`** → the config was hand-edited to the short
  `-L udp://51820:…` form. Put the bind address back: that machine is an open UDP
  relay from its LAN into the hub's WireGuard port, on exactly the untrusted
  networks this flavor exists for.
- **`wg-quick up` printed "a naaf wstunnel relay is already running (pid N)"** →
  a second ws config is up (every client is offered both `-ws.conf` and
  `-wsnd.conf`, so this is easy to do). They share both the pidfile and
  `127.0.0.1:51820`; take the first one down. The refusal happens in the first
  `PreUp`, before anything is started, and the interface is torn back down —
  which is what keeps the *first* relay's pidfile pairing intact. A stale pidfile
  with no live process is not a collision and does not refuse.
- **`wg show` shows a handshake but no useful traffic** → the transport is fine
  and the problem is inside the tunnel. Rejoin §1 at step 5.

After `wg-quick down`, `pgrep -a wstunnel` must come back empty. If it does not,
the pidfile went missing before `PostDown` ran and the relay outlived the
interface; kill it by hand. An orphan holding `127.0.0.1:51820` breaks every
later `up` on that machine, which is why the guard refuses a second `up` rather
than letting the two configs overwrite each other's pidfile.

---

## 1b. Playbook: a site LAN is unreachable

Laptop stays on Naaf; Naaf is supposed to reach a remote WireGuard server
(UniFi, another hub) and forward `192.168.1.0/24` (or whatever the site lists).
The laptop must **not** have that remote's client config up — that is what this
feature replaces.

Work the path in order.

**1. Is the site a live peer?**
```bash
sudo wg show wg0                 # remote pubkey, endpoint, handshake, transfer
sudo sqlite3 /var/lib/naaf/naaf.db \
  'select name,enabled,endpoint,substr(pubkey,1,12) from sites;'
```
No peer → the site is disabled, has no networks, or apply did not run. Peer
present, no handshake → Naaf cannot reach the remote listen address (WAN
firewall, wrong endpoint), or the remote has not added *this* box's
`settings.server_pubkey` as a peer **with `Endpoint` set to this box**
(`endpoint_host:listen_port`) and a keepalive. UniFi VPN Server waits for
inbound UDP; if the remote cannot accept that, *it* must dial us. The Sites
page shows a paste-ready `[Peer]` block.

**2. Does the kernel send that dest into `wg0`?**
```bash
ip -4 route show proto 158       # one line per site CIDR, `dev wg0`
ip route get 192.168.1.50        # must come back `dev wg0`, not the WAN default
```
`wg syncconf` never installs routes. Missing proto-158 lines mean the helper
on the box is older than the app, or apply refused the dest (a site CIDR that
covers the default gateway or a non-wg local address would steal SSH — the
helper raises and leaves the connected route alone). Redeploy so both units
update together.

**3. Is spoke-to-spoke dropping it?**
```bash
sudo nft list table inet naaf
# set site_nets should contain the LAN
# `ip daddr @site_nets accept` / `ip saddr @site_nets accept` sit ABOVE
# `iifname "wg0" oifname "wg0" counter drop`
```
A packet laptop → Proxmox is `iif wg0 oif wg0`. Without those accepts it
hits the spoke drop.

**4. Will the remote accept the source address?**
On the remote peer for this box, `AllowedIPs` must include `wg_subnet`
(typically `10.8.0.0/24`). The stock UniFi client AllowedIPs is only the
assigned `/32`, which drops every packet from a laptop. Either widen it, or
turn **Masquerade** on for the site (then Proxmox sees Naaf's assigned
address and cannot initiate back).

**5. Did a site CIDR capture the transport?**
A site network that contains the remote endpoint (or, on a `split-ws`
client, a site CIDR that covers Naaf's own public address) routes the
handshake into the tunnel. The form refuses an IPv4 endpoint inside a site
CIDR; a hostname cannot be checked. Same journal lines as §1a.C:

```bash
journalctl -u naaf | grep AllowedIPs
```

**6. Split-tunnel client `AllowedIPs`**
Site CIDRs are folded into every split config automatically. Re-download
the client config after adding the site; an old file will not route the LAN
to Naaf. Full-tunnel clients already send everything.

```bash
# on the laptop
ip route get 192.168.1.50        # must be dev <naaf wg>
```

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
| Ruby version has no `rv` build | `30-ruby.sh` | `rv ruby list` shows what is published; provisioning fails loudly rather than falling back |
| `bundle exec ruby` → `command not found: ruby` | `00-lib.sh` | put `/opt/rubies/ruby-4.0.6/bin` on `PATH` |
| helper socket `EACCES` for the app | `deploy/naaf-helper.service` | `Group=naaf` so `RuntimeDirectory` makes `/run/naaf` root:naaf |
| app dies on first boot (wg0 not up yet) | `bin/naaf`, sysctl, `50-bringup.sh` | rescue boot `apply!`; `net.ipv4.ip_nonlocal_bind=1`; restart naaf after wg-quick |
| Ruby 4.0 compile OOMs on 1 GB | `05-swap.sh` | historical: Ruby is prebuilt now, swap is just headroom |
| bootstrap re-keys on re-run (destructive) | `50-bringup.sh` | skip bootstrap when `server_pubkey` already set |
| a re-rendered `/etc/nftables.conf` is never loaded | `20-system.sh` | the packaged unit is `Type=oneshot` + `RemainAfterExit=yes`, so `enable --now` short-circuits forever; `reload-or-restart` runs its `ExecReload` (the same `nft -f`), and only when `cmp` says the file changed |
| that reload flushes table `inet naaf` | `20-system.sh` | `/etc/nftables.conf` starts with `flush ruleset`, so the reload is followed by `systemctl try-restart naaf` to re-apply |
| acme.sh renewal cron missing, "re-run the step" is a no-op | `60-certs.sh` | the installer short-circuits on the binary; repair with `acme.sh --install-cronjob` instead. `cron` is not in the apt list |
| `NAAF_ENDPOINT_HOST=vpn.example.com.` empties the certificate store | `lib-certs.sh` | one trailing dot is stripped in `cert_slug` and per-SAN, so 60 and 65 derive the same slug |

**Boot ordering:** `naaf.service` is `After=wg-quick@wg0.service` (not `Requires`), so
on normal reboots systemd raises `wg0` before the app. Only the *first* bring-up starts
the app before `wg0` exists — hence the rescue + `ip_nonlocal_bind` + post-wg-quick
restart. `wg0.conf` is written by the app's boot `apply!` (the helper writes the file
before `wg syncconf`, which is expected to fail the first time with no interface).

---

## 3a. The dashboard is frozen

Every panel carries an **as of HH:MM:SS** stamp in the health strip. If it stops
advancing, the numbers on screen are stale — there is no client-side way to
notice a dead stream without JavaScript, so that stamp is the signal.

```bash
journalctl -u naaf | grep 'metrics collection failed'   # the collector died
journalctl -u naaf | grep 'metrics collecting'          # what it started with
curl -sN --max-time 5 http://127.0.0.1:8080/events      # 401 = your session lapsed
```

- **Stamp advances on reload but not on its own** → something between you and the
  box is buffering `text/event-stream`. Set `NAAF_METRICS_SSE=0` in
  `/etc/naaf/naaf.conf` and restart; the page then polls the same fragments.
- **`metrics collection failed` in the journal** → the collector task caught an
  exception; the message names it. The reactor is unaffected by design.
- **Everything reads `—`** → `/proc` is not readable. Check nobody has added
  `ProcSubset=pid` to `naaf.service`; that hides `stat`, `meminfo`, `net/dev`
  and `net/snmp` in one line and the samplers report unavailable, not an error.
- **Peer throughput lags the rest of the page** → expected. Peer counters come
  from `Reconciler#poll!`, the only reader of kernel peer state, so they refresh
  every `NAAF_RECONCILE_INTERVAL` (30 s by default) rather than every metrics
  tick. Lower that if you want a livelier per-client chart.

History is in memory and resets on restart. That is deliberate — see AGENTS.md.

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
