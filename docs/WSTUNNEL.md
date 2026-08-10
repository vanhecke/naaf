# Naaf — WireGuard over wstunnel

Naaf clients normally dial the hub over raw UDP. That fails on a network that
passes only tcp/443, and it fails when you are already inside someone else's
full tunnel and want a *split* tunnel into the naaf network alongside it.

[wstunnel](https://github.com/erebe/wstunnel) carries the WireGuard datagrams
inside a TLS WebSocket, so the outer path is an ordinary outbound TCP connection
to `:443` — which traverses both cases. This adds two client config flavors,
`split-ws` and `split-ws-nodns`, and the server side they need: a pinned wstunnel
daemon, off by default.

The certificate it serves comes from the box's certificate store, which is
deliberately **not** wstunnel's — [`CERTS.md`](CERTS.md) is that layer and this
file links to it rather than repeating it.

---

## 1. The packet path

```
wg-quick up laptop-ws.conf
  │
  ├─ PreUp:  wstunnel client  ── binds 127.0.0.1:51820/udp ──┐
  │                                                          │
  └─ WireGuard  Endpoint = 127.0.0.1:51820  ─────────────────┘
                                            │
                     TLS WebSocket, outbound tcp/443
                                            │
                                            ▼
       naaf-wstunnel.service on the hub  (DynamicUser, no state)
                                            │
                     plain UDP to 127.0.0.1:<listen_port>
                                            │
                                            ▼
                        the kernel's own WireGuard listener
```

Everything the tunnel carries is unchanged: `AllowedIPs`, DNS, extra routes and
the preshared key are exactly what the plain `split` flavor emits. What changes
is only how the datagrams travel.

Two ports are called 51820 in that diagram and they are unrelated. The client's
local relay port is a constant in `lib/naaf/config_builder.rb`
(`WS_LOCAL_PORT`); the hub's is `settings.listen_port`. Changing the WireGuard
port on the server does not move the local one.

---

## 2. Turning it on

Server side, in `naaf.conf`:

```
NAAF_WSTUNNEL_ENABLED=1
NAAF_WSTUNNEL_VERSION=10.6.2
NAAF_WSTUNNEL_PORT=443
NAAF_WSTUNNEL_SNI=
NAAF_WSTUNNEL_TLS_VERIFY=auto
```

```sh
./deploy.sh
```

A plain full deploy is the simple path and the one to use. **`./deploy.sh --step
65-wstunnel` on its own is not enough to enable the feature**, for two reasons:
`--step` neither syncs the repo nor reinstalls `naaf.conf`, and the base firewall
rule for tcp/443 is rendered by `20-system`, not by 65. The long way, if you want
it, is:

```sh
./deploy.sh --sync
for s in 20-system 60-certs 65-wstunnel; do ./deploy.sh --step $s; done
./deploy.sh --verify
```

`60-certs` runs first because 65 refuses to install a unit pointing at a
certificate that does not exist. Both run **after** `50-bringup`, because the
certificate has to be named for `endpoint_host || endpoint_v4` as they sit in the
settings table and `bootstrap.rb` only fills that in at step 50.

**Everything is off unless the flag is 1**, including the firewall port. An open
tcp/443 with nothing listening behind it is an advertisement, so the port, the
unit and the two client flavors appear together or not at all. `deploy.sh
--verify` section 8 asserts both branches.

**Flipping the flag re-loads the base firewall, and that costs a blink.**
`/etc/nftables.conf` is rendered from `naaf.conf` by `20-system`, and Debian's
`nftables.service` is a `Type=oneshot` with `RemainAfterExit=yes` — `systemctl
start` short-circuits on it forever, so installing a new file is not enough to
load it. When the rendered file actually differs, `20-system` runs `systemctl
reload-or-restart nftables` (that unit's `ExecReload` is the same `nft -f`) and
then `systemctl try-restart naaf`. The second half is not optional: the file
opens with `flush ruleset`, which takes table `inet naaf` — the spoke↔spoke
default-deny, the egress masquerade, every DNAT — down with it, and
`Reconciler#poll!` only re-applies on peer-set drift. `bin/naaf` runs
`Reconciler#apply!` at startup, so restarting the app is the re-apply. An
unchanged deploy skips all of this and never flushes.

Once it is up, `/clients` grows two more buttons — `split·ws` and
`split·ws·nodns` — beside the existing three. If you see a red **"wstunnel is
enabled but not provisioned"** banner there, the flag is set but no path prefix
has reached the running app: run `./deploy.sh --step 65-wstunnel`, which writes
`/etc/naaf/wstunnel.env` and restarts naaf.

### Turning it off

Set `NAAF_WSTUNNEL_ENABLED=0` and deploy. The unit is disabled and removed, the
firewall rule becomes a comment, and the flavors stop being offered. Two things
are deliberately **kept**: `/etc/naaf/wstunnel.env` (so an off/on cycle does not
invalidate every config you have issued) and the certificate store (it is not
wstunnel's to delete).

### Provider firewalls do not follow

If your box sits behind a provider-level firewall as well,
`deploy/providers/vultr/ensure-firewall.sh` opens tcp/`$NAAF_WSTUNNEL_PORT` only
when it *creates* the group. An existing group is reused, never reconciled — so
flipping the flag on a box that already has one leaves the host's nftables
accepting tcp/443 while Vultr silently drops it. Add the rule by hand or delete
the group.

---

## 3. The client

### 3.1 Install `wstunnel`

The config will not come up without it. Get the binary from the [releases
page](https://github.com/erebe/wstunnel/releases) and **use the same version the
server runs** — `NAAF_WSTUNNEL_VERSION`, 10.6.2 by default, and the provisioning
log for `65-wstunnel` prints what actually got installed. Nothing here promises a
protocol contract across major versions; keep the two the same and the question
never comes up.

Linux, mirroring exactly what `deploy/provision/65-wstunnel.sh` does on the
server:

```sh
VER=10.6.2; ARCH=amd64          # amd64 | arm64 | armv7
BASE=https://github.com/erebe/wstunnel/releases/download/v$VER
cd "$(mktemp -d)"
curl -fsSLO "$BASE/wstunnel_${VER}_linux_$ARCH.tar.gz"
curl -fsSLO "$BASE/checksums.txt"
grep " wstunnel_${VER}_linux_$ARCH.tar.gz\$" checksums.txt | sha256sum -c -
tar -xzf "wstunnel_${VER}_linux_$ARCH.tar.gz"
sudo install -o root -g root -m 0755 wstunnel /usr/local/bin/wstunnel
```

macOS is the same shape with the darwin asset for your architecture and
`shasum -a 256 -c -` in place of `sha256sum -c -`. Take the exact asset name off
the release page; the Linux names above are the ones this repo pins and verifies,
the others are not.

**Install it to `/usr/local/bin`, and check `sudo wstunnel --version` rather than
`wstunnel --version`.** wg-quick runs hooks as root, and root's `PATH` is not
yours: on Debian `sudo` replaces it with `secure_path` (which does include
`/usr/local/bin`), and a binary in `~/.local/bin`, `~/go/bin` or a Homebrew
prefix can be perfectly visible in your own shell and invisible to the hook.
That is exactly the failure the first `PreUp` line exists to catch, loudly,
instead of leaving you with an interface that never handshakes.

**Windows is not supported.** The hooks are POSIX shell.

### 3.2 wg-quick(8) only — there is no QR

The ws flavors emit `PreUp` and `PostDown` in `[Interface]`, and that makes them
importable by `wg-quick(8)` and by nothing else.

`wireguard-apple`'s parser allows exactly `privatekey`, `listenport`, `address`,
`dns` and `mtu` in `[Interface]` and **throws** `interfaceHasUnrecognizedKey` for
anything else; wireguard-android does the same. `PreUp` is one. So the iOS and
Android apps do not ignore these lines, they reject the whole file — which is why
`GET /clients/:id/qr/split-ws` returns **404 even when the transport is enabled**,
and why the QR button on `/clients` stays where it was, outside the flavor loop
and always pointing at plain `split`.

If you want a phone on this transport, the answer is a laptop or a router running
wg-quick, not a workaround.

Download names are short on purpose: wg-quick derives the interface name from the
basename and refuses anything outside `[a-zA-Z0-9_=+.-]{1,15}\.conf` **before**
reading a line of the file. The flavors map to `-ws.conf` and `-wsnd.conf`, with
the hostname truncated so the stem fits.

### 3.3 What the config actually contains

A rendered `split-ws` (endpoint host `vpn.example.com`, default TLS settings):

```ini
[Interface]
PrivateKey = …
Address = 10.8.0.2/32
DNS = 10.8.0.1
MTU = 1280
PreUp = command -v wstunnel >/dev/null 2>&1 || { echo "naaf: wstunnel is not on PATH - see docs/WSTUNNEL.md" >&2; exit 1; }; p=$(cat /var/run/naaf-wstunnel-51820.pid 2>/dev/null || true); case "$(ps -p "${p:-0}" -o comm= 2>/dev/null)" in *wstunnel) echo "naaf: a naaf wstunnel relay is already running (pid $p) - one ws config at a time per machine, take the other one down first" >&2; exit 1 ;; esac
PreUp = umask 077; nohup wstunnel client -P <prefix> -L 'udp://127.0.0.1:51820:127.0.0.1:51820?timeout_sec=0' wss://vpn.example.com:443 >/var/log/naaf-wstunnel.log 2>&1 & echo $! >/var/run/naaf-wstunnel-51820.pid
PostDown = p=$(cat /var/run/naaf-wstunnel-51820.pid 2>/dev/null || true); case "$(ps -p "${p:-0}" -o comm= 2>/dev/null)" in *wstunnel) kill "$p" 2>/dev/null || true ;; esac; rm -f /var/run/naaf-wstunnel-51820.pid

[Peer]
PublicKey = …
PresharedKey = …
Endpoint = 127.0.0.1:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
```

`split-ws-nodns` is the same file without the `DNS =` line.

Three hooks, and each one is there for a reason:

- **The guard, which checks two preconditions.** First, that `wstunnel` is on
  root's `PATH`: the relay is started with `&`, so a missing binary fails only in
  the child — the parent's async list returns 0 and you get an interface that
  comes up cleanly and silently never handshakes. `exit 1` trips wg-quick's
  `set -e` while its `trap 'del_if; exit' EXIT` is armed, so the half-built
  interface is torn down and you get a message instead. Second, that the pidfile
  does not already name a **live** wstunnel — see §3.5. Both refusals happen
  before anything is started, which is the point of putting them in the first
  hook.
- **The relay.** `nohup` and not a bare `&`, so a hand-run `sudo wg-quick up` in
  a terminal does not SIGHUP the transport when you close the window.
  `umask 077` before the redirect, so the logfile is not created under root's
  ambient umask. The `-L` bind address is **pinned to `127.0.0.1`** — never the
  short `udp://51820:…` form, whose default bind was never established; if it is
  `0.0.0.0` then a laptop running this flavor is an open UDP relay from whatever
  café LAN it is on straight into the hub's WireGuard port. `timeout_sec=0`
  disables wstunnel's UDP session idle timeout so a quiet tunnel is not expired
  out from under you. There is deliberately **no `-c 1`**: that flag delays the
  local UDP bind until the connection to the server succeeds, so an unreachable
  server would mean nothing ever binds while wstunnel retries with backoff.
- **`PostDown`.** Reads the pidfile, confirms the process is actually wstunnel,
  kills it, removes the file. Both `|| true` are load-bearing under wg-quick's
  `set -e`, and the `case` glob covers macOS printing argv[0] as exec'd and Linux
  truncating `comm` to 15 characters.

You can edit any of this by hand — it is a flat file and that is the point of
keeping one template per flavor. Just remember that re-downloading overwrites it.

### 3.4 The first handshake can take up to 5 seconds

This is expected, it is not a fault, and nobody should spend an afternoon on it.

wg-quick runs every `PreUp` hook **before** `set_config`, so no peer exists while
the hooks run and nothing is sent until the relay has already been launched. But
the relay is launched asynchronously, so if it has not finished
binding `127.0.0.1:51820` by the time `PersistentKeepalive` triggers the first
handshake, that datagram hits an unbound port and comes back ICMP
port-unreachable. WireGuard ignores ICMP errors and retries every 5 seconds, so
the worst case is one lost handshake.

There is deliberately **no wait loop** in the hook. No portable one-liner exists
— `ss` is Linux-only and macOS wants `netstat -an -p udp` — and the cost of
getting it wrong (a hook that blocks forever on a machine where the check does
not work) is far worse than five seconds.

If you are still at zero handshakes after ~15 seconds, that is a real fault:
[`TROUBLESHOOTING.md` §1a](TROUBLESHOOTING.md).

### 3.5 The logfile and the pidfile

```
/var/log/naaf-wstunnel.log          0600 root:root, TRUNCATED on every `up`
/var/run/naaf-wstunnel-51820.pid    the relay's pid, written by PreUp
```

The contract, in full:

- **The log is truncated, not appended** (`>`, not `>>`). Each `wg-quick up`
  starts a fresh one, so if you want to keep the evidence of a failed bring-up,
  copy it before you retry.
- **Treat the log as sensitive.** That is what the `umask 077` is for: it is
  root-only on disk, and you should assume it can name the endpoint you dial and
  the path prefix you dial it with. Do not paste it into a ticket unredacted.
- **The pidfile is named after the local port, not the interface.** wg-quick's
  `%i` expands to the config name on Linux but to the `utunN` device on macOS,
  and `%I` exists only on macOS — neither is stable, so neither appears anywhere
  in a hook. The consequence is real: **one ws tunnel at a time per machine.**
  Two of them would fight over both the pidfile and `127.0.0.1:51820`.
- **The second `up` is refused, loudly, by the guard hook.** `/clients` hands
  every client both a `-ws.conf` and a `-wsnd.conf`, so having two on disk is the
  normal state and bringing the second one up is an easy mistake. It now fails
  with *"a naaf wstunnel relay is already running (pid N) — one ws config at a
  time per machine, take the other one down first"* and the interface is torn
  back down. What it prevents is nastier than a duplicate: B's wstunnel used to
  die on `EADDRINUSE` while `echo $! >PIDFILE` recorded its pid anyway, so
  `down A` then read B's dead pid, killed nothing, and removed the pidfile —
  leaving **A's root-owned relay holding a TLS session to the hub and owning
  `127.0.0.1:51820` after every interface was down**, which silently breaks every
  later `up` until reboot. A *stale* pidfile (no live process) is not a collision
  and does not refuse. Per-client relay ports would not have helped: the
  constraint is this machine's one 51820.
- **`/var/run`, not `/run`** — macOS has no `/run`. Stale pids are bounded by the
  `ps`/`comm` check in `PostDown` and not by the filesystem: `/run` is a tmpfs on
  Linux so `/var/run` is empty at boot, but on macOS `/var/run` is an ordinary
  directory.
- **If the pidfile is missing at `PostDown` the relay survives the interface.**
  Nothing is killed and nothing errors. After a `wg-quick down`, `pgrep -a
  wstunnel` should come back empty.

### 3.6 `MTU = 1280`, and where it comes from

Every ws config carries `MTU = 1280`. It is a constant in ConfigBuilder, not a
`naaf.conf` key and **not** the `MTU` field in the Settings UI — changing that
value moves the plain flavors and leaves these alone, because it describes the
client's path and matches nothing on the server.

Per-datagram overhead added between WireGuard and the wire:

| layer | IPv4 outer | IPv6 outer |
|---|---:|---:|
| WireGuard data message (4 type/reserved + 4 receiver index + 8 counter + 16 Poly1305 tag) | 32 | 32 |
| WebSocket frame header, unmasked | 4 | 4 |
| TLS 1.3 record (5 header + 16 AEAD tag + 1 inner content type) | 22 | 22 |
| TCP header with timestamps | 32 | 32 |
| IP header | 20 | 40 |
| **total** | **110** | **130** |
| **1280 + overhead** | **1390** | **1410** |

1390 fits inside a 1400-byte outer path. 1410 does not — and `endpoint_v6` is a
supported family, so a single number has to cover both. Rather than pick one per
family, lean on the argument that generalises: **over TCP an oversized MTU costs
efficiency, never connectivity.** The outer stream just segments and reassembles,
unlike UDP where the same mistake is a black hole. So err low.

1280 is also the IPv6 minimum link MTU, and already the floor the Settings page
accepts, so it is the one value nothing downstream can object to.

---

## 4. The path prefix

wstunnel's server refuses any WebSocket upgrade that does not carry a configured
path prefix, so a scanner that finds tcp/443 finds a server that refuses
everything rather than a tunnel endpoint. That is the whole job it does.

It is generated by `65-wstunnel.sh` (24 random bytes, hex) into
`/etc/naaf/wstunnel.env`, `0640 root:naaf`, and read back into the web app's
environment by `EnvironmentFile=-/etc/naaf/wstunnel.env` in `naaf.service`. It is
**not** a `naaf.conf` key, and that is not an oversight: `deploy/install-config.sh`
iterates the *incoming* file only, so a key that exists on the box but is missing
from your local copy is dropped, re-appended empty by `40-app.sh`, and
regenerated here — silently invalidating every `split-ws` config ever issued.

### It is a shared secret, and it is visible

Be honest about what this buys. The prefix is **necessarily visible to anyone who
can read a client's config file or that client's journal**, because wg-quick
echoes every hook verbatim to stderr before running it. It is also in the
server's rendered unit (0644), in `/proc/<pid>/cmdline` on both ends, and in
anyone's `ps` output on the client machine.

**It is the same trust boundary as that client's own private key.** Anyone who
can read one can read the other, and the recovery for both is the same: delete
the client. What the prefix defends against is an untargeted scan of the internet
finding a tunnel endpoint on your :443. It does not defend against someone who
already has a copy of a config.

The one place it is kept out of is anything that *leaves* the box: `65-wstunnel`
logs the fact and never the value (`provision.sh` tees every step to a 0644 log
and `deploy.sh` tees the run back to `deploy/logs/` on your workstation), and
`verify.sh` reports a verdict — `generated`, `wstunnel's default`, `missing` —
and never prints it.

### Rotating it invalidates every issued ws config

There is no rotation command, because the operation is one line and the
consequence needs to be deliberate:

```sh
./deploy.sh --ssh -- 'rm -f /etc/naaf/wstunnel.env'
./deploy.sh --step 65-wstunnel
```

65 keeps an existing non-empty prefix and only generates when there is none, so
removing the file is the rotation. It then re-renders the unit, restarts
wstunnel, and `systemctl try-restart naaf` so the app stops handing out the old
value.

**Every `split-ws` config already in the field stops working at that moment** —
they carry the old prefix in a `PreUp` line and the server refuses their upgrade.
Each one needs re-downloading. And because naaf never stored the client private
keys (`clients` has no such column, structurally), a re-download outside the
one-shot window comes with `PrivateKey = REPLACE_WITH_YOUR_PRIVATE_KEY` and the
user has to paste their own key back in — or you delete and re-add the client.
Plan the rotation accordingly.

---

## 5. Why there is no full-tunnel ws flavor

`AllowedIPs = 0.0.0.0/0` would capture wstunnel's own TCP session to the server.
The relay's connection to `vpn.example.com:443` would be routed into the tunnel
that the relay is carrying, and the whole thing hangs — no handshake, no error,
no log line.

wg-quick's `not fwmark <table>` rule is what saves the plain `full` flavor from
exactly this, and it exempts **the kernel WireGuard socket**, not a userspace
process. wstunnel has `--socket-so-mark`, which could in principle join that
exemption, but:

- it is Linux-only (darwin wg-quick has no fwmark at all), and
- wg-quick picks the fwmark **dynamically**, so a config template generated on
  the server cannot know the number, and
- when it is wrong the failure mode is a silent hang.

Three strikes, so the flavor does not exist, and adding `0.0.0.0/0` to a `ws`
config's `AllowedIPs` by hand does **not** get you one: wg-quick will install its
fwmark rule, that rule will exempt the kernel WireGuard socket as designed, and
the relay's TCP session will be captured anyway. Making it work means pinning a
`/32` route to the server out the physical interface yourself, on every network
the machine joins. That is unsupported and it is not what these flavors are for.

### Not offering the flavor is not enough — the routes are audited

`AllowedIPs` is `wg_subnet` plus every row in `extra_routes` that applies to the
client, so "there is no full-tunnel ws flavor" was a claim a **Routes** entry
could break from the other side. Two shapes do it, and neither errors anywhere
else — the guard hook only checks `PATH`, so what you get is a `-ws.conf` that
comes up clean and silently never handshakes:

| the route | what wg-quick does with it |
|---|---|
| any `/0` | dispatches to `add_default()`: `not fwmark <table>` plus `suppress_prefixlength 0`. The fwmark exemption covers the kernel WireGuard socket, not userspace wstunnel — **and `suppress_prefixlength 0` takes the machine's own default route with it, so there is no network at all until `wg-quick down`** |
| anything *containing* the hub's public address — `203.0.113.0/24` for an endpoint of `203.0.113.7`, the natural "let me reach the hub's datacenter LAN" entry | plain `ip route add … dev wg0` in the main table, in front of the transport |

So `ConfigBuilder` audits every resolved route against `endpoint_v4`/`endpoint_v6`
before it renders, and for the **ws flavors it refuses**:

```
AllowedIPs route 0.0.0.0/0 is a default route, which would capture wstunnel's own
TCP session — that is why there is no full-tunnel-over-wstunnel flavor. Remove the
route or use the split flavor.

AllowedIPs route 203.0.113.0/24 contains the endpoint address, so it would route
wstunnel's own TCP session into the tunnel it carries. Narrow the route so it
excludes the endpoint.
```

Over HTTP that is a **500 `Internal error`** on the ws config download, with the
message in `journalctl -u naaf`. The plain flavors keep working, which is the
point: remove or narrow the route on the **Routes** page, or hand that client a
plain `split` config.

**Plain `split` and `split-nodns` are treated differently on purpose.** A `/0`
there is *fine* — the kernel WireGuard socket really is fwmark-exempt on that
path, which is how `split` plus a `/0` extra route works as a full tunnel today —
so refusing it would break a shipped, working configuration. A covering route
does break plain `split` too, but that hazard predates these flavors and it is a
false alarm whenever `endpoint_host` resolves somewhere other than `endpoint_v4`.
So plain split **logs a warning** (`journalctl -u naaf`, "an AllowedIPs route
contains the endpoint address") and still renders. ws raises; split warns.

The **covering** half compares against `endpoint_v4`/`endpoint_v6` in `settings`,
because the server cannot resolve `endpoint_host`. A box with `endpoint_host` set
and neither literal populated skips that half — there is nothing to compare
against and the audit must not invent a reason to refuse. The `/0` half needs no
address and always applies. A route that will not parse as a CIDR at all is also
refused for the ws flavors: it is a route the audit cannot clear, and `param_cidr`
means the UI cannot produce one.

---

## 6. TLS

### The embedded certificate is never used

wstunnel ships with a self-signed certificate compiled into the binary. It is
byte-identical on every deployment in the world, which makes it a perfect
fingerprint for anyone cataloguing TLS endpoints — the exact opposite of what
this transport is for. Every naaf box serves its own instead: the unit is
rendered with `--tls-certificate`/`--tls-private-key` pointing at the certificate
store, and `verify.sh` section 8 asserts the flag is present precisely so that
"we quietly fell back to the embedded one" cannot happen silently.

### Self-signed by default; ACME is the upgrade

`60-certs.sh` guarantees a self-signed EC P-256 pair for the endpoint before it
does anything else, unconditionally, so the transport always has something
loadable. That is a **complete, supported configuration**: a per-box fingerprint and
an encrypted transport. What it does not give you is a certificate a client can
verify against a public root — which is why `NAAF_WSTUNNEL_TLS_VERIFY=auto`
correctly declines to verify against it.

Turning on `NAAF_ACME_ENABLED=1` gets you a real Let's Encrypt certificate over
DNS-01 (never HTTP-01 — no inbound port is ever opened, and tcp/80 stays shut in
both branches). The delegation model, the second-provider-account containment
story, `NAAF_ACME_DOMAINS`, staging vs production and everything else about
issuance lives in **[`CERTS.md`](CERTS.md)**.

**It gets you nothing on a bare-IP box**, and that combination is worth naming
because it fails on the client rather than on the box: with no
`NAAF_ENDPOINT_HOST` the certificate is named for an address, no public CA
issues for one, `60-certs.sh` says so and keeps the self-signed pair — but
`auto` sees `NAAF_ACME_ENABLED=1` and emits `--tls-verify-certificate` anyway.
Set a hostname first, or pin `NAAF_WSTUNNEL_TLS_VERIFY=off`.

### Renewal restarts the transport, and that is forced

`naaf-wstunnel.service` reads both files through systemd's `LoadCredential=`, so
`key.pem` stays `0600 root:root` on disk and no persistent uid can read it.

The consequence: **the credentials directory is a start-time snapshot.**
wstunnel's own certificate file-watch cannot see a renewal, because the files it
is watching under `%d` never change. That is why the store's reload hook,
`/usr/local/sbin/naaf-cert-reload`, does a full `systemctl restart` rather than a
reload. It costs live TCP sessions that reconnect and a WireGuard handshake that
retries within 5 seconds, roughly every 60 days. That is the right trade against
a private key readable by a long-lived uid.

---

## 7. SNI

### The default is already your own domain

Dialing `wss://vpn.example.com:443` puts `vpn.example.com` on the wire as SNI
automatically. `NAAF_WSTUNNEL_SNI` is empty by default and empty is usually
right. Set it and every config gains `--tls-sni-override <value>`.

### Why it exists: decryption exclusions

PAN-OS and comparable NGFWs decide **whether to decrypt** by evaluating
decryption policy against the SNI in the ClientHello, *before* any decryption
happens. Every real deployment carries exclusions from that policy:

- **URL categories** that are excluded for legal or privacy reasons —
  `financial-services`, `health-and-medicine` and friends.
- **The built-in pinned-certificate exclusion list**, which exists because
  decrypting those sites breaks them.
- **Local no-decrypt rules** the organisation added itself.

An SNI that lands in an excluded category makes the firewall pass the session
through without decrypting it. That is the entire mechanism, and it is a
client-side choice: **wstunnel's server has no vhost routing, no SNI allowlist and
no SNI inspection of any kind.** It presents its one certificate regardless of
what arrives. That is also why there is no per-client SNI and no domains page — a
`clients` column would be state naaf stores and never uses. One `naaf.conf` key,
plus the commented block every `.conf` carries, is the whole surface.

### The honest caveat

Without the strong form below, a firewall that also inspects the **served**
certificate sees a name that contradicts the SNI. That is its own anomaly, and on
some deployments a louder one than not being decrypted. Do not treat a cover name
as invisibility.

### `NAAF_WSTUNNEL_TLS_VERIFY` — and yes, the two flags compose

`--tls-sni-override` and `--tls-verify-certificate` are **not** mutually
exclusive. wstunnel declares `conflicts_with` only between `--tls-sni-disable`
and `--tls-sni-override`, so these are two independent knobs and a config can
carry both.

| value | emits `--tls-verify-certificate` | when to use it |
|---|---|---|
| `auto` *(default)* | when `NAAF_ACME_ENABLED=1` **and** `NAAF_WSTUNNEL_SNI` is empty | verify exactly when the dialed name and the served certificate agree |
| `on` | always | the strong form, below |
| `off` | never | forcing it off against a self-signed certificate |

**The strong form** is `NAAF_WSTUNNEL_TLS_VERIFY=on` together with
`NAAF_WSTUNNEL_SNI` set to a cover domain **you actually hold a DNS-01
certificate for** — one you added to `NAAF_ACME_DOMAINS`, so the box serves it.
Then the SNI, the certificate and the client's verification all agree: an
inspecting firewall sees a coherent session for a domain in whatever category you
chose, and the client is still verifying a real certificate rather than trusting
whatever answers. This is the only configuration where the cover name buys
something and costs nothing.

ConfigBuilder refuses the one genuinely broken combination — verification on,
SNI overridden, ACME off — because `--tls-sni-override` also sets the name the
certificate is checked against, and the self-signed fallback is issued for the
endpoint, so verification against a cover name can never pass whatever the client
trusts. The refusal is an `ArgumentError` naming the keys; over HTTP it surfaces
as a **500 `Internal error`** on the config download, with the real message in
`journalctl -u naaf`.

`auto` reads `NAAF_ACME_ENABLED`, which is the operator's *intent* — not the
issuer of the certificate that actually got installed. `60-certs.sh` warns and
exits 0 with the self-signed fallback in several paths (no DNS token, no `git`,
a moved acme.sh tag, a bare-IP endpoint), and in those `auto` emits
`--tls-verify-certificate` against a certificate that can never verify. It is
kept optimistic deliberately: the only alternative signal would be an
achieved-issuer value that nothing writes today, and defaulting `auto` to off
whenever ACME is on would silently drop verification on every correctly
provisioned box — a loud failure traded for a quiet one. The loud failure is
`deploy/verify.sh` section 9, which asserts CA-issued whenever ACME is on and
exits nonzero on the same run, and `NAAF_WSTUNNEL_TLS_VERIFY=off` pins the
fallback behaviour in one setting.

### Everything that turns a ws download into a 500

Every value that lands in a shell command wg-quick runs **as root on a client's
machine** is whitelist-validated before a character of it is composed, and the
whitelists are anchored: a leading `-` would make the word an argv flag
(`--tls-sni-override -x` exits wstunnel in the child, where `&` hides it) and a
leading `~` is tilde-expanded in an unquoted word (`-P ~root` would reach the
server as `/var/root`). The full list of refusals, all of them `ArgumentError` →
**500 `Internal error`**, message in `journalctl -u naaf`:

- `NAAF_WSTUNNEL_PATH_PREFIX` unset or malformed — `65-wstunnel` has not run.
  The buttons are offered on `NAAF_WSTUNNEL_ENABLED=1` alone, so `/clients` puts
  the *"wstunnel is enabled but not provisioned"* banner above them for exactly
  this state; the download is a 500 until the step has run.
- a malformed `NAAF_WSTUNNEL_SNI`, or an out-of-range `NAAF_WSTUNNEL_PORT` /
  `settings.listen_port`, or a `NAAF_WSTUNNEL_TLS_VERIFY` that is not
  `auto`/`on`/`off`.
- verify on + SNI override + ACME off, above.
- an `extra_routes` row that would capture the transport (§5).
- **a box with no `endpoint_host` and no `endpoint_v4`** — "endpoint address is
  unset or malformed". The ws path asks for the v4 family, so an IPv6-only box
  has no ws flavor at all; give it a name in Settings. A bare IPv4 endpoint is
  fine and dials `wss://<address>:443`. (The bracketed v6 literal the host
  whitelist used to admit was unreachable for that reason, and brackets are bash
  pathname-expansion metacharacters in the unquoted `wss://…` word, so they are
  no longer accepted. Adding v6 means single-quoting that argv element first.)

None of these consumes the one-shot private key: the config route peeks, renders,
and only spends the stash once a complete response exists. A 500 on a ws download
leaves the freshly generated key available for the next one.

---

## 8. Checking it

`./deploy.sh --verify` covers the transport in section 8 and the store in section
9. With the flag on it asserts: the unit is active, something is listening on the
port, the base firewall allows it, the unit serves its own certificate from the
store through both `LoadCredential=` lines, it has no `ReadWritePaths`, it is not
running as root, and — the assertion that matters most — that
`--restrict-to 127.0.0.1:<port>` equals the port WireGuard is **actually**
listening on according to the database. With the flag off it asserts the port is
closed and the unit inactive. In both branches, that tcp/80 is not open.

By hand, from a client, to prove the served certificate is the box's own:

```sh
openssl s_client -connect vpn.example.com:443 -servername vpn.example.com </dev/null 2>/dev/null |
  openssl x509 -noout -subject -issuer -fingerprint
```

The fingerprint differs from a stock wstunnel with no `--tls-certificate`, and
the subject is this endpoint. Then bring a client up and watch it:

```sh
sudo wg-quick up ./laptop-ws.conf
sudo wg show                       # a handshake within ~5 s
ping -c3 10.8.0.1
sudo tail /var/log/naaf-wstunnel.log
ss -lunp '( sport = :51820 )'      # macOS: netstat -an -p udp | grep 51820
sudo wg-quick down ./laptop-ws.conf
pgrep -a wstunnel                  # must be empty
```

The `ss` line is worth running once per platform: it is the check that the relay
bound `127.0.0.1` and not `0.0.0.0`.

---

## 9. Things that will bite you

- **`--step 65-wstunnel` does not open the firewall.** The base firewall is
  rendered by `20-system`. Enabling the feature with `--step` alone gives you a
  healthy unit that nothing can reach.
- **`--step` alone neither syncs the repo nor installs `naaf.conf`.** Every recipe
  here that edits the config file starts with `./deploy.sh --sync`.
- **Rotating the path prefix is a fleet-wide reissue.** §4. There is no way to
  rotate it for one client — the prefix is a property of the server.
- **One ws tunnel at a time per machine.** The pidfile and the local relay port
  are both fixed constants, and the second `wg-quick up` now refuses rather than
  orphaning the first relay. §3.5.
- **The MTU field in Settings does not move these configs.** §3.6.
- **An extra route that covers the server's public IP, or any `/0`, makes the ws
  config refuse to render** (a 500 on the download) — and it hangs plain `split`
  too, where it only logs a warning. §5, and
  [`TROUBLESHOOTING.md` §1a](TROUBLESHOOTING.md).
- **A port forward cannot sit on tcp/`NAAF_WSTUNNEL_PORT` while the transport is
  enabled.** The DNAT would hand the transport's own port to a client and kill
  every ws client while the unit stayed active and the port stayed open, so the
  form refuses it (and refuses re-enabling an existing row on it). Turning
  wstunnel off makes tcp/443 an ordinary forward again.
- **No ws flavor on an IPv6-only box.** The transport dials the v4 family; with
  no `endpoint_host` and no `endpoint_v4` the download is a 500. §7.
- **`wstunnel --version` in your shell proves nothing.** The hook runs as root.
  Check with `sudo`.
- **Nothing in this document has been run against a live client on a real
  restricted network.** The server half is design-reviewed and unit-tested; the
  end-to-end walkthrough in the plan is the check that has not happened yet.
