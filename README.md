# Naaf

Naaf is a single-admin control plane for one WireGuard hub. The admin UI
manages clients, spoke-to-spoke port policy, inbound port forwards, split-tunnel
routes, remote sites, an optional internet exit, and a private DNS zone.
SQLite is the source of truth. WireGuard and nftables are projections of that
database, pushed through a small root helper.

## Contents

- [Architecture](#architecture)
- [Admin UI](#admin-ui)
- [Clients](#clients)
- [Config flavors](#config-flavors)
- [Sites and routed subnets](#sites-and-routed-subnets)
- [Spoke-to-spoke policy](#spoke-to-spoke-policy)
- [Port forwards](#port-forwards)
- [DNS](#dns)
- [Internet exit](#internet-exit)
- [wstunnel](#wstunnel)
- [SOCKS5 proxy](#socks5-proxy)
- [Certificates](#certificates)
- [Dashboard and peer status](#dashboard-and-peer-status)
- [Metrics](#metrics)
- [Backups and Litestream](#backups-and-litestream)
- [Deploying](#deploying)
- [Security](#security)
- [Operations](#operations)
- [Development](#development)
- [Configuration](#configuration)
- [Layout](#layout)

## Architecture

One Ruby process (4.0.6, YJIT on in production via `RUBY_YJIT_ENABLE`) runs
every control-plane task on one shared Async reactor:

| Task | What it does |
|---|---|
| Falcon | Admin UI. Roda routes, ERB views. Binds `settings.server_ip` and `127.0.0.1` on `NAAF_WEB_PORT` (default 8080). |
| async-dns | Resolver on `settings.server_ip`:`NAAF_DNS_PORT` (default 53). Needs `CAP_NET_BIND_SERVICE` and nothing else. |
| Reconcile loop | `Reconciler#poll!` every `NAAF_RECONCILE_INTERVAL` seconds (default 30). |
| Metrics collector | Samples `/proc` every `NAAF_METRICS_INTERVAL` seconds (default 2) into in-memory ring buffers. |
| Backup loop | `VACUUM INTO` every `NAAF_BACKUP_INTERVAL` seconds (default 3600) when `NAAF_BACKUP_ENABLED=1`. |

`bin/naaf` is `naaf.service` (`User=naaf`). Privileged work is `bin/naaf-helper`
(`naaf-helper.service`, root) on the Unix socket `NAAF_HELPER_SOCKET`
(`/run/naaf/helper.sock`). The helper accepts newline-delimited JSON and four
commands: `genkeys`, `apply`, `dump`, `ping`. `ping` only answers `{ok: true}`.
There is no shell string; every child is an argv array.

The database is `/var/lib/naaf/naaf.db` (Sequel + SQLite, WAL, `busy_timeout`
5000). A mutation writes a row, then `Reconciler#apply!`, then the helper, then
the kernel. The kernel is not read back to fill the database. Handshake time,
endpoint, and byte counters are the exception: `poll!` is the only caller of
`dump`, and it is the only parser of `wg show dump` (the first line of that
output is the server private key).

Five renderers are pure functions of the database. `apply` asks the helper to
install the first four:

| Renderer | Projection |
|---|---|
| WireGuard | `wg syncconf` on `NAAF_WG_INTERFACE` (default `wg0`), after `wg-quick strip`. Existing peer sessions stay up. |
| nftables | The whole table `inet naaf`, checked with `nft -c -f`, then applied with `nft -f`. |
| Routes | Extra `/32` addresses on `wg0`, and site destinations tagged `proto 158` so apply can diff them. |
| Exit | Optional second interface `NAAF_EXIT_INTERFACE` (default `wg-exit`): `wg syncconf`, policy routing table 159, and `ip rule` prefs. |
| ConfigBuilder | Client `.conf` text, rendered on download. It refuses a config that cannot work (`ArgumentError`, which the route turns into a 500). |

`apply`'s `exit` field is optional. A helper that predates it leaves client
internet on WAN masquerade. When an exit is up, an optional `exit.proxy` object
adds uid-scoped rules (prefs 15870 / 15875 / 15880) so `naaf-proxy` follows the
exit; an older helper ignores that key.

`ConfigBuilder` whitelists every value that lands in a `wg-quick` hook. Those
hooks run as root on the client. A leading `-` is an argv flag, a leading `~`
tilde-expands, and `[` globs, so the check is an anchored whitelist.

Data-plane daemons are separate systemd units, not reactor tasks:
`naaf-wstunnel.service` and `naaf-proxy.service`. The static base firewall is
`/etc/nftables.conf` (table `inet filter`). Application code does not write it.
Provisioning renders it once from `deploy/nftables.conf.template`.

The UI is ERB, vendored Bulma, and vendored htmx plus its SSE extension
(`vendor/htmx.min.js`, `vendor/htmx-ext-sse.min.js`). There is no application
JavaScript, no inline script, and no Node build.

## Admin UI

One bcrypt password, session cookie `NAAF_SESSION_COOKIE` (default
`naaf.session`), lifetime `NAAF_SESSION_DAYS` (default 7). Every state-changing
form is a POST with a CSRF token, then a redirect. **Re-apply state** in the
navbar is `POST /apply`.

| Page | Route | What it stores |
|---|---|---|
| Dashboard | `GET /` | Nothing. Live fragments; see [Dashboard](#dashboard-and-peer-status). |
| Clients | `/clients` | `clients`. Keys, enable, delete, config download, QR. |
| Exposed ports | `/exposed-ports` | `exposed_ports`. Spoke-to-spoke allow-list. |
| Port forwards | `/port-forwards` | `port_forwards`. WAN DNAT, with an enable toggle. |
| Sites | `/sites` | `sites`, `site_networks`, site-owned `dns_forwarders`. |
| Internet exit | `/exit` | `exits`. At most one row. |
| Routes | `/extra-routes` | `extra_routes`. Global or per-client CIDRs in `AllowedIPs`. |
| DNS | `/dns-records` | `dns_records` and admin-owned `dns_forwarders`. |
| Troubleshoot | `/troubleshoot` | Nothing. `ping`, `traceroute`, `curl`, and a flow tester. |
| Settings | `/settings` | Editable `settings` columns, and the admin password. |

## Clients

`POST /clients` inserts a row and calls `apply!`. The form takes a display
name and a hostname. The helper's `genkeys` always returns a private key, a
public key, and a preshared key. Leave the public-key field blank and that
keypair is the client's: the private key is handed out once and the public
key is stored. Paste a public key and the generated keypair is discarded; only
the preshared key is stored, and there is no private key to hand out.

IPAM (`lib/naaf/ipam.rb`) assigns the next free address in `settings.wg_subnet`.
It skips the network address, the broadcast address, and `settings.server_ip`,
and it reuses addresses freed by a delete.

The private key is not a column. It sits in the session under
`with_oneshot_privkey` until one successful download. `GET
/clients/:id/config/:flavor` builds the whole file inside that block and
deletes the key only after the response is complete. A render error leaves the
key in place. The QR route peeks and does not consume it, so a scan still
leaves a download. After the download the only recovery is to delete the client
and add it again.

Each client row shows the name, `<hostname>.<dns_domain>`, the VPN address,
enabled or disabled, last handshake, and a truncated public key. Disable
removes the peer from `wg0` on the next apply. A disabled client is not a
kernel peer. The client whose VPN address is the internet exit's endpoint
cannot be deleted, and cannot be disabled while that exit is enabled: IPAM
would give the address to someone else and the exit would dial them.

## Config flavors

`GET /clients/:id/config/:flavor` returns a `wg-quick` file. Unknown flavors
are 404. The five flavors are `split`, `split-nodns`, `full`, `split-ws`, and
`split-ws-nodns`. The two `ws` flavors are listed only when
`NAAF_WSTUNNEL_ENABLED=1`.

| Flavor | `AllowedIPs` | `DNS` | Transport |
|---|---|---|---|
| `split` | `wg_subnet`, plus `extra_routes` for that client (global and per-client), plus every enabled site's `site_networks` | `settings.server_ip` | UDP to `endpoint_host:listen_port`, or `endpoint_v4:listen_port` when the host is blank |
| `split-nodns` | same as `split` | omitted | same as `split` |
| `full` | `0.0.0.0/0` | `settings.server_ip` | same as `split` |
| `split-ws` | same as `split` | `settings.server_ip` | local `wstunnel` to TCP `NAAF_WSTUNNEL_PORT`; WireGuard endpoint `127.0.0.1:51820`; MTU 1280 |
| `split-ws-nodns` | same as `split` | omitted | same as `split-ws` |

`split` does not send internet traffic to the hub. Per-app egress for a split
client is the [SOCKS5 proxy](#socks5-proxy). `full` sends everything through
the hub; with an [internet exit](#internet-exit) enabled, that traffic leaves
via `wg-exit` instead of WAN masquerade.

The Clients page shows one QR button, for `split`. `GET /clients/:id/qr/:flavor`
also renders `split-nodns` and `full` as inline SVG (`rqrcode`). Both `ws`
flavors return 404: their `PreUp` / `PostDown` hooks make the iOS and Android
WireGuard apps reject the file. They are `wg-quick(8)` only. There is no
full-tunnel-over-wstunnel flavor. `AllowedIPs = 0.0.0.0/0`, or any extra route
that covers the endpoint address, would capture wstunnel's own TCP session.
`audit_transport_capture` raises for the `ws` flavors and logs a warning for
plain `split`.

`wg-quick` takes the interface name from the basename and refuses anything
outside 15 characters before `.conf`. Downloads are `<host>-split.conf`,
`<host>-nodns.conf`, `<host>-full.conf`, `<host>-ws.conf`, and
`<host>-wsnd.conf`, with the hostname truncated so the stem fits.

While `NAAF_WSTUNNEL_ENABLED=1` but `65-wstunnel` has not written
`/etc/naaf/wstunnel.env`, `/clients` shows a banner and still offers the `ws`
buttons. Every file they would produce dials a path the server rejects.

## Sites and routed subnets

A site (`/sites`) is a remote WireGuard server this hub dials. It is not a
client: it has no address on `wg_subnet`. The peer public key is the remote's.
The hub presents `settings.server_pubkey` on the other side. The row stores
endpoint (`host:port`), keepalive (default 25), an optional preshared key, an
optional assigned address (a `/32` installed on `wg0`), and a masquerade flag.

Networks live in `site_networks`. `Renderers::Routes` installs each CIDR on
`wg0` with `proto 158`. The same CIDRs are folded into every split client's
`AllowedIPs`, the same way `extra_routes` are, so clients send that LAN to the
hub and the hub cryptokey-routes it to the site. A site with no networks is
not installed as a kernel peer (WireGuard refuses empty `AllowedIPs`), and
`poll!` does not count it as drift.

The form and the helper both refuse a `/0` and any destination or address that
covers the default gateway or a non-`wg0` local IPv4. That check in the helper
is what keeps SSH and WAN reachability.

Masquerade is off unless the remote will not put `wg_subnet` in its
`AllowedIPs`. When it is on, `inet naaf` SNATs traffic toward that site's
networks. Return connections from the LAN then see the hub's assigned address,
not the laptop.

`/extra-routes` is the other half of split routing. A row with `client_id`
NULL applies to every client; a row bound to one client applies only to that
client. The page lists site networks so the split set is visible in one place;
those rows are edited on `/sites`. Disabled sites still show there, marked
disabled, and are omitted from the rendered `AllowedIPs`.

A site can also name a DNS server and a list of domains. Those become
`dns_forwarders` rows owned by the site. See [DNS](#dns).

## Spoke-to-spoke policy

Spoke-to-spoke forwarding is default-deny in the `inet naaf` forward chain.
`AllowedIPs` is only a hint on the client. Between `iifname wg0` and
`oifname wg0` the chain accepts, in order:

1. established and related conntrack state
2. ICMP echo-request
3. `ip daddr . tcp dport` in the interval set `vpn_tcp_allow`
4. the same for UDP in `vpn_udp_allow`
5. traffic to or from `site_nets`
6. `counter drop`

`/exposed-ports` fills those sets. A row is one client, `tcp` or `udp`, and a
single port or an inclusive range (`8000-8100`). Ranges that share a start, or
that overlap an existing range for the same client and protocol, are refused.
Deleting a client cascades its exposed ports. A disabled client's ports are
omitted from the sets because the renderer only walks enabled clients.

No base chain in `inet naaf` sets `policy drop`. That would override other base
chains on the same hook. The forward chain's policy is `accept`; the drop is
the explicit spoke-to-spoke rule.

## Port forwards

`/port-forwards` is inbound DNAT from `settings.wan_interface` to a client's
VPN address. Each row is a public port, `tcp` or `udp`, a target port, and an
enabled flag. The public port is unique per protocol. Disabled rows stay in
the database and emit no rule.

An enabled forward becomes, in prerouting:

```
iifname "<wan>" <proto> dport <public> dnat ip to <wg_ip>:<target>
```

The forward chain then accepts `iifname <wan> oifname <wg> ct status dnat`.
Postrouting masquerades `oifname <wg> ct status dnat` so a split-tunnel client
answers via the hub (hairpin) instead of its own default route.

The form refuses a forward on a port the box uses itself, and the enable
toggle re-checks on the way on: `tcp/22` (SSH), `udp/<listen_port>`
(WireGuard), and, when wstunnel is enabled, `tcp/NAAF_WSTUNNEL_PORT`. DNAT in
prerouting runs before the routing decision, so those forwards would hand the
box's own SSH, handshakes, or WebSocket clients to a spoke. `NAAF_WEB_PORT` is
not reserved: the admin UI does not bind the WAN address.

When an internet exit is enabled, replies to a port forward are marked so they
stay in the main table instead of following the exit's policy rule.

## DNS

`naaf.service` is the resolver for the tunnel. It listens on the gateway
address only. Client configs that set `DNS` point at that address. The zone
name is `settings.dns_domain` (default `vpn`).

`Zone#reload!` rebuilds three maps and swaps them in as whole objects. It runs
only from `Reconciler#apply!`. The maps are:

- **A records**, synthesized and then overlaid with static rows. For every
  client: `<hostname>.<domain>` and the bare `<hostname>`, both to `wg_ip`.
  Also the apex `<domain>` and `gateway.<domain>`, both to `server_ip`. A
  static `dns_records` row with the same name overrides the automatic one.
  Only type `A` is served.
- **PTR records** for each client address under `in-addr.arpa`.
- **Conditional forwarders.** Suffix match, longest suffix wins, the same rule
  dnsmasq uses. The local zone is consulted first, so a name inside
  `dns_domain` is never forwarded.

Anything the zone does not answer goes to `settings.dns_upstream` (default
`1.1.1.1`), or to the forwarder whose suffix matches. Admin-owned forwarders
are added on `/dns-records`. Site-owned ones are added on the site and shown
read-only on the DNS page. A disabled site contributes no forwarder: it is not
a kernel peer, so the rule would turn an ordinary lookup into a hang. A site's
resolver address has to sit inside one of that site's own networks, because
those are the only CIDRs `proto 158` routes.

async-dns 1.4.1 does not time out an upstream that accepts and never answers.
`DNSServer` wraps the passthrough in `NAAF_DNS_UPSTREAM_TIMEOUT` (default 4
seconds). `UpstreamTimeout` is an `Exception`, not a `StandardError`, so the
resolver's own `rescue` does not swallow it and then retry on TCP with no
deadline. A timeout is counted as `upstream_fail`.

`split-nodns` and `split-ws-nodns` never point the client at this resolver.

## Internet exit

`/exit` holds at most one `exits` row: a second WireGuard identity, on
`wg-exit`, whose `AllowedIPs` is `0.0.0.0/0`. `exits.privkey` is the hub's key
toward that peer. It is stored, never logged, and never rendered after the
one-time flash that shows the matching public key when the hub generated the
keypair.

Full-tunnel clients (`full`) are policy-routed into table 159:

| pref | rule |
|---|---|
| 15800 | `fwmark 159` looks up `main` (the exit's own UDP, and port-forward replies) |
| 15850 | from `wg0` to `wg_subnet` looks up `main` |
| 15900 | from `wg0` looks up table 159, whose default route is `wg-exit` |

`inet naaf` masquerades `wg_subnet` out `wg-exit`, clamps TCP MSS to the exit
MTU minus 40, and keeps the WAN masquerade rule for hub-originated traffic.
SSH, DNS passthrough, backups, and the Troubleshoot tools stay on the WAN.
The SOCKS proxy follows the exit. Split clients do not send their default
route here. A disabled or deleted exit removes the interface, the rules, and
table 159, and full-tunnel internet returns to WAN masquerade. A peer that is
up in the database but down on the wire black-holes full-tunnel internet until
someone disables the row.

Two ways to create the row:

- **Register with Cloudflare WARP** (`POST /exit/warp`). The hub generates a
  keypair and registers it with Cloudflare's client API
  (`lib/naaf/warp.rb`). The API is unofficial. A failure leaves no row.
- **Add manually.** Peer public key, endpoint host and port, the assigned
  IPv4 (no prefix), MTU (default 1280), keepalive, optional preshared key.
  Leave the private key blank to generate one.

The endpoint may be a hostname, or the VPN address of an **enabled client** on
this hub (not `server_ip`). In that case `wg-exit`'s UDP is hub-originated
traffic into `wg0`: tunnel-in-tunnel, no port forward at the far end. The form
requires that exit's MTU to fit inside `wg0`'s MTU minus 60 bytes of outer
IPv4, UDP, and WireGuard header (1360 when `wg0` is the default 1420). The
carrying client must stay on a split config. Client setup for that arrangement
is [docs/EXIT.md](docs/EXIT.md).

`wg setconf` is the only way the exit interface is programmed. The rendered
conf has no `MTU`, `Address`, `Table`, `DNS`, or hook lines; MTU is applied
with `ip link`. `wg-quick` is not used on `wg-exit`, because
`AllowedIPs = 0.0.0.0/0` would install a default route in `main` and take SSH
with it.

The page shows the handshake, endpoint, and transfer counters that `poll!`
writes onto the row.

## wstunnel

Off unless `NAAF_WSTUNNEL_ENABLED=1`. The flag, the unit, the base-firewall
TCP accept, and the two client flavors appear together. An open TCP port with
nothing listening is left closed on purpose.

`naaf-wstunnel.service` (`deploy/naaf-wstunnel.service`) terminates TLS on
`NAAF_WSTUNNEL_PORT` (default 443) and forwards the unwrapped datagrams to
`127.0.0.1:<listen_port>`. It runs as `DynamicUser`, not as `naaf`, so a
compromise of the public listener is not a compromise of `naaf.db`. The
binary version is `NAAF_WSTUNNEL_VERSION` (default 10.6.2). The path prefix
is generated on the box into `/etc/naaf/wstunnel.env` (mode 0640) and is
deliberately not a `naaf.conf` key: a blank key in the operator's file would
be regenerated on every deploy and invalidate every issued `split-ws` config.

Client hooks bind `127.0.0.1:51820` (`WS_LOCAL_PORT` in
`lib/naaf/config_builder.rb`). That port is a machine-global constant, so one
host runs one `ws` tunnel. A second `wg-quick up` is refused while the pidfile
names a live relay. The client needs the same `wstunnel` version on `PATH`
for root, which is who `wg-quick` runs hooks as.

`NAAF_WSTUNNEL_TLS_VERIFY` is `auto`, `on`, or `off`. `auto` verifies when ACME
is on and `NAAF_WSTUNNEL_SNI` is blank. `NAAF_WSTUNNEL_DNS_RESOLVER` (default
`dns://1.1.1.1`) is how the relay resolves the endpoint before the tunnel's
own DNS exists.

Packet path, client install, and the firewall reload that enabling the flag
causes: [docs/WSTUNNEL.md](docs/WSTUNNEL.md). A `split-ws` client that will
not connect: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) §1a.

## SOCKS5 proxy

On unless `NAAF_PROXY_ENABLED=0`. `naaf-proxy.service` runs `microsocks` as
`NAAF_PROXY_USER` (default `naaf-proxy`), bound to `settings.server_ip` on
`NAAF_PROXY_PORT` (default 1080). It does not bind `0.0.0.0` or the WAN
address. The user is not `naaf`: that uid owns the database. TCP `CONNECT`
only. The base firewall does not grow a hole; traffic from `wg0` is already
accepted.

```bash
curl --socks5-hostname <server_ip>:1080 https://example.com
```

`<server_ip>` is `settings.server_ip` (`10.8.0.1` in `naaf.conf.example`).
`gateway.<dns_domain>` resolves to the same address. With no internet exit,
destinations see the WAN address. With an exit enabled, the proxy uid follows
table 159. SSH, ACME, Litestream, and the Troubleshoot tools do not.

`NAAF_PROXY_ENABLED=0` and `./deploy.sh --step 66-socks` remove the unit. The
package and the user stay. Detail: [docs/PROXY.md](docs/PROXY.md).

## Certificates

`deploy/provision/60-certs.sh` owns `/etc/naaf/certs`. Every box gets its own
certificate, self-signed by default, so `naaf-wstunnel` does not serve the
certificate compiled into the `wstunnel` binary. `NAAF_ACME_ENABLED=1` adds
Let's Encrypt over DNS-01. TCP port 80 stays closed. The DNS API token is not
a `naaf.conf` key; `deploy.sh` ships it to `/etc/naaf/acme.env` (mode 0600,
root:root). A CA failure logs a warning and leaves the self-signed certificate.
The step does not fail the deploy.

wstunnel is the consumer that exists today. It registers under the
certificate's `consumers.d/` and is reloaded by `naaf-cert-reload` on renewal.
The store, the slug rules, and adding another consumer:
[docs/CERTS.md](docs/CERTS.md).

## Dashboard and peer status

`GET /` is server-rendered HTML. With `NAAF_METRICS_SSE=1` (the default) one
`EventSource` on `GET /events` pushes the same fragments the page was painted
with. `NAAF_METRICS_SSE=0` polls `GET /metrics/<name>` every
`NAAF_METRICS_POLL_INTERVAL` seconds (default 5) instead. Each panel is also
that GET, so a panel can be fetched without the reactor's SSE stream. The
`sse-connect` wrapper stays outside every swap target.

Panels:

| Fragment | Contents |
|---|---|
| `health` | Clients up, sites up, DNS rate, reconcile age or "reconcile failing", backup age, config-drift count. |
| `kpis` | `wg0` throughput in and out, DNS queries/s, CPU and load, memory, conntrack table used. |
| `pipeline` | WAN packets/s (before netfilter) → UDP datagrams/s delivered to a socket → `wg0` packets/s decrypted. A stalled reading is the firewall symptom in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) §1 step 3. |
| `clients` | Every client and every site: handshake, endpoint, bytes, sparkline. Up means enabled, installed (a site needs at least one network), and a handshake within the last 3 minutes. |
| `dns` | Rate, fraction answered locally, upstream p50/p95, outcome counters, and (unless `NAAF_METRICS_DNS_NAMES=0`) top names. |
| `talkers` | Peers ranked by throughput. Not destinations. Per-flow byte counts are not collected. |
| `interfaces` | Per-interface counters from `/proc/net/dev`, tagged wan / tunnel / exit. |
| `policy` | Subnet, endpoint, DNS upstream, and counts of clients, exposed ports, forwards, sites, routes, records, forwarders. Rendered once when SSE is on. |
| `app` | Process RSS and CPU, Ruby version, YJIT, database and WAL size, last backup, last reconcile. The reconcile-failure line is the exception class only. |

`poll!` is what marks a peer online. The dashboard reads `Metrics::PeerStats`,
which that loop publishes. It does not call the helper. The internet exit is
shown on `/exit` from the row `poll!` updates, not in the peer table.

`/troubleshoot` runs `ping`, `traceroute`, and `curl` as the `naaf` user when
`NAAF_DIAG_ENABLED=1`. Paths come from a fixed candidate list, arguments from
an anchored whitelist, concurrency from `NAAF_DIAG_CONCURRENCY` (default 2),
and a hard kill at `NAAF_DIAG_TIMEOUT` (default 10s). `curl` refuses
`169.254.0.0/16`. `NAAF_DIAG_ENABLED=0` removes the three tools. The flow
tester stays: it walks the rendered rules and the client's `AllowedIPs` and
names the line that decides a destination. It does not send a packet.

## Metrics

History is in-memory ring buffers (`NAAF_METRICS_HISTORY` samples, default
180, so six minutes at a 2-second interval). Nothing is written to
`naaf.db`. A restart clears the charts. Peer throughput is only as fresh as
`NAAF_RECONCILE_INTERVAL`, because peer byte counters come from `poll!`.

The collector is its own reactor task. A reconcile failure does not stop
sampling, and a slow sample does not delay a reconcile. DNS counters rotate
by swapping a whole frozen object, so a DNS fiber and a render fiber do not
share a mutable hash.

`NAAF_METRICS_DNS_NAMES=0` keeps aggregate DNS rates and drops per-name and
per-client query counts.

## Backups and Litestream

`naaf.db` holds `settings.server_privkey`, `exits.privkey` when an exit
exists, every peer, every firewall rule, and the admin password hash.

Snapshots are on by default. `NAAF_BACKUP_ENABLED`, `NAAF_BACKUP_DIR`
(`/var/lib/naaf/backups`), `NAAF_BACKUP_INTERVAL` (3600), `NAAF_BACKUP_KEEP`
(24). Each snapshot is `VACUUM INTO` a `.tmp` name, `chmod 0600`, then
renamed to `naaf-<timestamp>.db`. Rotation runs before the write and only
deletes names that match that pattern. Settings shows the newest snapshot's
name and size. There is no download route. Copy one with `scp`.

Litestream is off unless `NAAF_LITESTREAM_ENABLED=1`, installed by
`./deploy.sh --step 45-litestream` at `NAAF_LITESTREAM_VERSION` (default
0.5.16). `NAAF_LITESTREAM_REPLICA_TYPE` is `file` or `s3`. Object-store
credentials go in `/etc/naaf/litestream.env`, not in `naaf.conf`. The shipped
intervals (`NAAF_LITESTREAM_SYNC_INTERVAL=1h` and the L0–L3 / snapshot keys
in `naaf.conf.example`) are hourly so an R2 replica stays inside the free
Class A allowance. The replica is not encrypted.

Restore, the migration recipe (restore the database before `50-bringup`, then
`bin/bootstrap.rb --refresh-network`, then repoint `endpoint_host`), and the
Litestream provider table: [docs/BACKUP.md](docs/BACKUP.md).

## Deploying

Any Debian 13 host reachable as root over SSH. `./deploy.sh` rsyncs the tree
to `/opt/naaf`, installs `naaf.conf` as `/etc/naaf/naaf.conf` (mode 0640,
root:naaf, workstation-only section stripped), runs every provisioning step,
and runs `deploy/verify.sh`.

```bash
cp naaf.conf.example naaf.conf
# set NAAF_SSH_HOST, and NAAF_SESSION_SECRET if you are not letting 40-app.sh fill it
./deploy.sh                 # provision NAAF_SSH_HOST, then verify
./deploy.sh --create        # NAAF_PROVIDER creates a box, then the same deploy
./deploy.sh --update        # rsync and restart; no provisioning
./deploy.sh --verify        # re-run deploy/verify.sh
./deploy.sh --sync          # push code and naaf.conf; run nothing
./deploy.sh --step 30-ruby  # one provisioning step; does not sync
./deploy.sh --ssh -- 'journalctl -u naaf -n 100 --no-pager'
```

`--step` does not sync and does not reinstall `naaf.conf`. A change to the
file reaches the box only after `./deploy.sh --sync` or a full `./deploy.sh`.
Use a full deploy when the change touches a unit, the nftables template, or
the Ruby version.

Provisioning order: `05-swap`, `10-packages`, `20-system`, `30-ruby`,
`40-app`, `45-litestream`, `50-bringup`, `60-certs`, `65-wstunnel`,
`66-socks`. `45-litestream` and `65-wstunnel` no-op unless their enable flag
is `1`. `66-socks` no-ops when `NAAF_PROXY_ENABLED=0`. `50-bringup` generates
the server keypair once, guarded on `settings.server_pubkey`, which is why a
re-deploy does not ask for the admin password again and why restoring a
database first keeps the old identity. Ruby comes from `rv` as a
checksum-verified prebuilt tarball (`NAAF_RUBY_VERSION`, `NAAF_RV_VERSION`).

`NAAF_PROVIDER` selects `deploy/providers/<name>/create-box.sh` (the tree
ships `vultr`). `NAAF_DNS_PROVIDER` selects `update-record.sh` (the tree ships
`dnsimple`). Both are examples. A provider script prints an address on stdout
and does not embed provisioning. With a DNS provider set, `NAAF_DNS_NAME` in
`NAAF_DNS_ZONE` is pointed at the box on every full deploy, and `--create`
copies that name into `NAAF_ENDPOINT_HOST`.

The admin password is prompted once on first deploy (or taken from
`NAAF_ADMIN_PASSWORD` for an unattended bootstrap). It is shipped to a
root-only file the box deletes as it reads it, then bcrypt-hashed into
`settings.admin_pw_hash`.

First login, before any client exists:

```bash
ssh -L 8080:127.0.0.1:8080 root@<host>
# http://localhost:8080
```

After a client is up, the UI is `http://<server_ip>:8080` on the tunnel.
`NAAF_WEB_PORT` changes the port on both binds.

What each step does, the ACME token hand-off, and migrating a box:
[deploy/DEPLOY.md](deploy/DEPLOY.md).

## Security

`naaf.service` runs as `NAAF_USER` (default `naaf`) with
`AmbientCapabilities=CAP_NET_BIND_SERVICE` and
`CapabilityBoundingSet=CAP_NET_BIND_SERVICE`. It does not have
`CAP_NET_ADMIN`. The helper socket is mode 0660, `root:<NAAF_GROUP>`. Group
membership is the authorization. The web process is a member; anything else
in that group can drive `wg` and `nft` through the same four commands.

The admin UI binds `settings.server_ip` and `127.0.0.1`. The SOCKS proxy binds
`settings.server_ip` only. DNS binds `settings.server_ip` only.

Client private keys are generated in the helper, rendered into one download
and one QR peek, and discarded. `clients` has no private-key column.
`server_privkey` and `exits.privkey` stay in the database. They are not logged,
not put in a view, and not put in an error string. `Reconciler#failed!` stores
the exception class. Helper stderr can echo key material from `wg syncconf`,
and that string is what the class-only field is keeping off the page and off
the SSE stream.

Spoke-to-spoke traffic is default-deny, as [above](#spoke-to-spoke-policy).
The app regenerates only table `inet naaf`. `/etc/nftables.conf` is the table
that keeps SSH. Snapshots and Litestream replicas contain the server private
key; treat a copy as that key. Reporting a vulnerability:
[SECURITY.md](SECURITY.md).

## Operations

```bash
systemctl status naaf naaf-helper wg-quick@wg0
systemctl status naaf-wstunnel naaf-proxy   # present only when those flags installed them
wg show wg0
wg show wg-exit          # only while an exit row is enabled and applied
nft list table inet naaf
ip -4 route show proto 158
ip -4 route show table 159
ip -4 rule show
journalctl -u naaf -f
```

`nft list tables` on a healthy box is `inet filter` and `inet naaf`. An
`ip filter` or `ip6 filter` table means `ufw` (or another iptables-nft
firewall) is loaded. Provisioning disables and masks `ufw`, because a cloud
image's rules drop UDP `listen_port`, tunnel DNS, and forwarded traffic even
when `ufw status` says inactive. `net.ipv4.ip_forward` stays at 1.

`Reconciler#poll!` re-applies when the peer set drifts. It does not notice a
missing `inet naaf` table. A hand-run `nft -f /etc/nftables.conf` flushes the
ruleset; `systemctl restart naaf` or `POST /apply` puts the table back.

When a client cannot handshake, tunnel DNS times out, or full-tunnel TCP dies,
start with [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The dashboard
packet-pipeline strip charts the same UDP-delivery check that playbook uses.
Other sections there: `split-ws` (§1a), sites (§1b), an exit that runs through
a client (§1c), and a second spoke on the same box in a network namespace (§2).

## Development

Ruby 4.0.6 and Bundler. `rv ruby install` matches what the box runs. Tests do
not need root, a WireGuard interface, or a helper socket: renderers, IPAM,
`Zone`, `ConfigBuilder`, backup, and the helper's validators are exercised
with `run!` stubbed.

```bash
bundle install
cp naaf.conf.example naaf.conf && chmod 600 naaf.conf
ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'   # NAAF_SESSION_SECRET

bundle exec sus
bundle exec standardrb --fix
bin/ci
```

`bin/ci` is the gate: Standard, the `sus` suite, `shellcheck` on `deploy.sh`
and the provisioning scripts, the `naaf.conf` grammar (no `export`, no
`$VAR`), a require-free `lib/naaf/config.rb`, sha384 pins for the two vendored
scripts, and `nft -c -f` on a rendered `inet naaf` including a non-empty
`site_nets`. On a workstation without `nft` or `shellcheck` those two checks
skip. In CI a skip fails the job.

`bundle exec ruby bin/naaf` binds the configured WireGuard address and UDP 53,
so the process is run on the target host. `bin/ci` does not prove an apply
against a live kernel. Conventions, the helper boundary, and the Never list:
[AGENTS.md](AGENTS.md). How to change the code: [CONTRIBUTING.md](CONTRIBUTING.md).

## Configuration

One file, `naaf.conf`, copied from `naaf.conf.example`. Grammar is the
intersection of systemd `EnvironmentFile=`, `set -a; . file`, and
`lib/naaf/config.rb`: `KEY=value`, no `export`, no `$VAR`. Precedence is
environment, then the file, then the default in `config.rb`. An empty value
falls through to the default. `bin/ci` enforces the grammar.

Keys that mirror a `settings` column seed the database on first boot only.
After that the database wins, the Settings page edits it, and boot logs
`Config.drift` when the file disagrees. Seeded, then read-only in the UI
because changing them rebinds listeners or invalidates every client config:
`NAAF_WG_INTERFACE`, `NAAF_WG_SUBNET`, `NAAF_SERVER_IP`, `NAAF_LISTEN_PORT`.
Seeded, then editable: `NAAF_WAN_INTERFACE`, `NAAF_DNS_UPSTREAM`,
`NAAF_DNS_DOMAIN`, `NAAF_MTU`, `NAAF_ENDPOINT_HOST`, `NAAF_ENDPOINT_V4`,
`NAAF_ENDPOINT_V6`. `NAAF_ENDPOINT_HOST` is the name baked into client
`Endpoint` lines. Blank means clients dial `endpoint_v4` and stay pinned to
that address.

These groups are read from the file on every start and are not `settings`
columns. The unit and the base firewall are rendered from the same file at
provision time:

- Web, DNS, reconcile, session: `NAAF_WEB_PORT`, `NAAF_DNS_PORT`,
  `NAAF_DNS_UPSTREAM_TIMEOUT`, `NAAF_RECONCILE_INTERVAL`, `NAAF_SESSION_SECRET`,
  `NAAF_SESSION_COOKIE`, `NAAF_SESSION_DAYS`.
- Metrics and the Troubleshoot tools: `NAAF_METRICS_INTERVAL`,
  `NAAF_METRICS_HISTORY`, `NAAF_METRICS_SSE`, `NAAF_METRICS_POLL_INTERVAL`,
  `NAAF_METRICS_DNS_NAMES`, `NAAF_DIAG_ENABLED`, `NAAF_DIAG_TIMEOUT`,
  `NAAF_DIAG_CONCURRENCY`.
- Backups and Litestream: the `NAAF_BACKUP_*` and `NAAF_LITESTREAM_*` keys.
  Access keys stay in `/etc/naaf/litestream.env`.
- Exit interface name: `NAAF_EXIT_INTERFACE`.
- wstunnel: `NAAF_WSTUNNEL_ENABLED`, `NAAF_WSTUNNEL_VERSION`,
  `NAAF_WSTUNNEL_PORT`, `NAAF_WSTUNNEL_SNI`, `NAAF_WSTUNNEL_TLS_VERIFY`,
  `NAAF_WSTUNNEL_DNS_RESOLVER`. The path prefix is
  `/etc/naaf/wstunnel.env`, not a key here.
- Proxy: `NAAF_PROXY_ENABLED`, `NAAF_PROXY_PORT`, `NAAF_PROXY_USER`.
- Certificates: `NAAF_CERT_DIR`, `NAAF_ACME_ENABLED`, `NAAF_ACME_EMAIL`,
  `NAAF_ACME_SERVER`, `NAAF_ACME_DNS_API`, `NAAF_ACME_CHALLENGE_ALIAS`,
  `NAAF_ACME_DOMAINS`, `NAAF_ACME_SH_VERSION`, `NAAF_ACME_SH_COMMIT`. The DNS
  token is `/etc/naaf/acme.env`.

Below the workstation-only marker, stripped before install: `NAAF_SSH_HOST`,
`NAAF_SSH_USER`, `NAAF_SSH_KEY`, `NAAF_RUBY_VERSION`, `NAAF_RV_VERSION`,
`NAAF_SWAP_GB`, `NAAF_PROVIDER`, `NAAF_DNS_PROVIDER`, and the provider-specific
names documented in the example (`NAAF_REGION`, `NAAF_PLAN`, `NAAF_DNS_ZONE`,
`NAAF_DNS_NAME`, and the rest of that block). `NAAF_ADMIN_PASSWORD` is not a
key in the example. Export it only for an unattended first boot.

## Layout

```
naaf.conf.example       every key, with the comments that are the spec
bin/naaf                reactor: web, DNS, reconcile, metrics, backups
bin/naaf-helper         root helper, four JSON commands
bin/bootstrap.rb        first boot: server keys, admin password, endpoint
bin/ci                  standardrb, sus, shellcheck, conf grammar, nft -c -f
lib/naaf/               app, config, db, reconciler, zone, ipam, backup,
                        config_builder, helper client, diagnostics, flow, warp
lib/naaf/renderers/     wireguard, nftables, routes, exit, svg
lib/naaf/metrics/       rings, /proc, DNS counters, peer stats, SSE hub
db/schema.rb            settings, clients, exposed_ports, port_forwards,
                        dns_records, dns_forwarders, extra_routes, sites,
                        site_networks, exits
views/                  ERB pages and the five client-config templates
vendor/                 naaf.css, naaf.js, htmx.min.js, htmx-ext-sse.min.js
test/                   sus tests
deploy.sh               the one deploy command
deploy/                 units, nftables template, provision steps, verify.sh
deploy/DEPLOY.md        deploy runbook
docs/BACKUP.md          snapshots, Litestream, restore, migration
docs/CERTS.md           certificate store and DNS-01
docs/EXIT.md            internet exit through one of this hub's clients
docs/PROXY.md           SOCKS5 proxy
docs/TROUBLESHOOTING.md handshake, DNS, full-tunnel, ws, sites, exit
docs/WSTUNNEL.md        TLS WebSocket transport
```
