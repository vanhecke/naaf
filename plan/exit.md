# Internet exit

A second WireGuard interface that full-tunnel clients leave through, so
destinations see a WARP (or other upstream) address instead of this box's WAN
IP.

```
Laptop (full) ---> Naaf (wg0) ---> wg-exit ---> Warp ---> Internet
```

Hub-originated traffic stays on the VPS WAN. Split clients never send internet
to the hub and are unchanged.

Do not implement until this plan is approved. Branch: `feat/internet-exit`.

---

## Decisions (do not relitigate)

1. **Name.** UI: *Internet exit*. Table: `exits`. Route: `/exit`. Not "relay"
   (we decrypt), not "upstream" (DNS), not "egress" (jargon).
2. **Second interface `wg-exit`.** WARP is a WireGuard *client* config with its
   own private key. `wg0` already has `settings.server_privkey`. One iface, one
   identity. A dedicated iface also leaves the spoke-deny chain intact
   (`iif wg0` / `oif wg-exit`) instead of punching a hole in it.
3. **Clients only.** Only forwarded traffic that arrived on `wg0`. SSH, the
   WARP handshake, ACME, Litestream, and Troubleshoot ping/curl stay on the
   VPS WAN.
4. **At most one exit.** One row. Enable/disable/replace, no fleet of uplinks.
5. **IPv4 only.** WARP's IPv6 address is ignored.
6. **No auto-fallback.** A down peer blackholes client internet on purpose. A
   silent leak of the VPS IP would be worse. Disable the exit to restore WAN
   masquerade.
7. **Helper vocabulary unchanged.** Still `genkeys` / `apply` / `dump` / `ping`.
   The new work is an optional `exit` field on `apply`, plus an optional
   `exit_dump` on `dump`.

---

## Why this is not a site

A WARP-like peer *looks* like a site (hub dials, remote pubkey, assigned `/32`
outside `wg_subnet`, masquerade). Every existing site pipe then breaks:

| Path | What `/0` would do |
|---|---|
| `param_site_cidr` | Refuses prefix 0 ("would steal WAN egress") and overlap with `wg_subnet` |
| Helper proto 158 | Refuses `/0` and any dest covering the default gateway or a non-wg local IPv4. Last line, on purpose, as root |
| `site_nets` | `0.0.0.0/0` in the interval set accepts **all** wg→wg, including spoke↔spoke |
| ConfigBuilder | Folds every enabled site LAN into split AllowedIPs → every split becomes full; every `*-ws` download raises `ArgumentError` → 500 |
| Flow | Would classify the entire internet as `:site` |
| nftables today | Laptop→internet is `iif=oif=wg0` to a public dest → misses exposed_ports and `site_nets` → `counter drop` |
| Port-forward replies | Reply dest is a public IP; a new default via wg0 sends it into WARP instead of back out WAN |

`Renderers::WireGuard` *can* emit `AllowedIPs = 0.0.0.0/0` on a site peer — it
does not special-case prefix 0, and the helper does not parse AllowedIPs in
`wg_conf`. Cryptokey routing is not the problem. Installing `/0` as a proto-158
dest on `wg0`, folding it into client configs, and putting it in `site_nets`
are.

AGENTS.md **Never:** "NEVER install a site dest or extra `/32` that covers the
default gateway or a non-wg local address. A `/0` site dest is the same class
of bug." This feature must not relax that.

---

## Ask first (this plan is the ask)

| Item | What |
|---|---|
| Schema | New `exits` table |
| Widen `apply` | `ip link add type wireguard`, `wg setconf`/`syncconf` on a second iface, `ip rule`, `ip route table 159` |
| Secret | `exits.privkey` — hub identity toward the remote, same class as `server_privkey`. Not a client key. Never log, never render. It rides into every `VACUUM INTO` snapshot and, with Litestream 0.5 (no encryption), sits in the object-store replica in plaintext next to `server_privkey`. Same blast radius, one more key in it — say so in `docs/BACKUP.md` |

Not a new helper command. Extra JSON fields stay optional; an older helper
silently skips them and client internet stays on WAN. Redeploy updates the
helper. Document that degradation; do not invent a capability bit.

Not a new gem. WARP registration is stdlib `Net::HTTP`. Under Falcon the
socket waits are fiber waits.

---

## Never (must not violate)

- `wg-quick` on `wg-exit`. `AllowedIPs = 0.0.0.0/0` would install a default
  route in **main** and steal SSH. `wg setconf` / `syncconf` only.
- A wg-quick-compatible conf anywhere on disk, `/etc/wireguard/` above all.
  The conf lives only in a `Tempfile.create` for the length of the
  `wg syncconf` call, mode 0600, and is gone after it. An operator (or
  `systemctl enable wg-quick@wg-exit`) must not be one file away from a
  lockout, and the surest way to guarantee that is for the file not to exist.
- An `MTU =` (or `Address =`, `Table =`, `DNS =`, `PreUp`/`PostUp`) line in
  the exit conf. `wg setconf` rejects the whole file on any of them, and there
  is no `wg-quick strip` on this path.
- `/0` as a proto-158 dest, a `site_networks` row, or an element of
  `site_nets`.
- Folding the exit into ConfigBuilder split AllowedIPs.
  `audit_transport_capture` is unchanged.
- `policy drop` on a base chain in `inet naaf`.
- Writing outside `table inet naaf` from application code. `wg-exit` has no
  listen port; `/etc/nftables.conf` does not change. Do not add
  `iifname wg-exit accept` on input.
- A new helper command.
- Storing or logging a *client* private key. `exits.privkey` is the other
  class, and still never lands in a view, a flash, an SSE fragment, or
  `Reconciler#failed!` (class only).
- Reading `wg show dump` anywhere but `Reconciler#poll!`. Line 1 of
  `exit_dump` is the exit private key.
- Binding the admin UI anywhere but the WireGuard IP and `127.0.0.1`.
- Node, npm, a third vendored script, inline `<script>`.

---

## Data model

`exits` — additive `create_table?`. `alter_existing!` is untouched.

```ruby
db.create_table?(:exits) do
  primary_key :id
  String :name, null: false, default: "Internet exit"
  String :provider, null: false, default: "manual"  # manual | warp
  String :privkey, null: false   # OURS toward the remote
  String :pubkey, null: false    # THEIRS
  String :psk
  String :endpoint, null: false  # host:port
  String :address, null: false   # assigned IPv4 host, no prefix
  Integer :keepalive, null: false, default: 25
  Integer :mtu, null: false, default: 1280
  TrueClass :enabled, null: false, default: true
  String :notes
  DateTime :created_at
  DateTime :last_handshake_at
  String :observed_endpoint
  Bignum :rx_bytes, default: 0
  Bignum :tx_bytes, default: 0
end
```

At most one row, enforced in the route, not a CHECK. Insert refused if a row
exists; replace is delete-then-add or an update of the same row.

`assert_unused_pubkey!` must also refuse an exit pubkey that belongs to a
client, a site, or `settings.server_pubkey`. The reverse: adding a client or
site must refuse the exit's pubkey.

**Iface name is not in the DB.** `NAAF_EXIT_INTERFACE=wg-exit` lives in
`lib/naaf/config.rb` DEFAULTS (require-free; the helper loads that file as
root). Same reason wstunnel's port is not a settings column: the helper and
the app must not be able to disagree, and nothing in the UI should rename it.

`reset_db!` must delete `:exits` (no FK; order with the other wipes is free).

Address validation (form **and** helper):

- IPv4 host, not a CIDR.
- Not inside `wg_subnet`.
- Not a site `address`.
- **Not inside any `site_networks` CIDR**, and the converse in
  `param_site_cidr`: a new site network containing the exit address is
  refused. Both directions, as with the pubkey rule. This is not theoretical —
  WARP hands out `172.16.0.x`, and a site with `172.16.0.0/24` is ordinary.
  The `/32` connected route on `wg-exit` would win over the proto-158 `/24` on
  wg0 and silently break exactly one host behind that site.
- `raise_if_steals!` (default gateway or a non-wg, non-exit local IPv4 — see
  the `local_v4_except_wg` note in the apply path).

---

## Routing

There is no policy routing on the hub today. Full-tunnel client traffic hits
the main-table default and leaves via WAN masquerade. Cryptokey `AllowedIPs`
only applies to packets already leaving a WireGuard iface, so without a route
*into* `wg-exit`, internet still goes WAN even if the exit peer exists.

```
pref 15800  fwmark 159 lookup main                 # port-forward replies
pref 15850  iif wg0 to $wg_subnet lookup main      # spoke↔spoke, DNS, admin UI
pref 15900  iif wg0 lookup 159                     # everything else from the tunnel
```

Table 159:

- each enabled site CIDR → `dev wg0`
- each enabled site `address` as a `/32` → `dev wg0` (a site's SNAT address is
  not always inside its own networks; without this it would leave via the exit)
- `default` → `dev wg-exit`

Never `default` in main. Never proto 158 `/0`. Proto 158 stays the site-LAN
tag on main; table 159 is a different number on purpose.

Hub sockets are not `iif wg0`, so they never hit these rules. The WARP
handshake is hub-originated UDP to `engage.cloudflareclient.com` and uses the
WAN default. No endpoint exemption is required (that would be load-bearing on
the same-iface design we rejected).

Port-forward replies: src is the client, dest is a public IP, `iif wg0`.
Without a mark they would follow pref 15900 into WARP. Mark the connection on
WAN ingress and restore the mark before the routing decision (see nftables).

Site traffic that misses pref 15850 (dest is a site LAN, not `wg_subnet`)
hits table 159; the copied site CIDR sends it back to `wg0`. If table 159
only had `default`, site LANs would leave via WARP.

`extra_routes` still install nothing on the hub. A global `0.0.0.0/0` extra
route already turns split into full; those packets then follow the same
`iif wg0` path as a `full` client and leave via the exit when one is up.

---

## Apply path

```
DB write → Reconciler#apply! → helper apply → kernel
```

Fifth renderer, still a pure function of the DB. AGENTS.md today names four;
update it.

`Renderers::Exit.desired(db)` returns `nil` when there is no row or it is
disabled, otherwise:

```ruby
{
  conf: "...",            # [Interface] PrivateKey + [Peer] ... — no MTU line
  dev: "wg-exit",
  address: "172.16.0.2",
  mtu: 1280,              # applied with `ip link`, never written into conf
  table: 159,
  mark: 159,
  routes: [
    {dst: "192.168.1.0/24", dev: "wg0"},   # enabled site CIDRs
    {dst: "192.168.2.2/32", dev: "wg0"},   # enabled site addresses
    {dst: "default",        dev: "wg-exit"}
  ],
  rules: [
    {pref: 15800, spec: ["fwmark", "159", "lookup", "main"]},
    {pref: 15850, spec: ["iif", "wg0", "to", wg_subnet, "lookup", "main"]},
    {pref: 15900, spec: ["iif", "wg0", "lookup", "159"]}
  ]
}
```

Exit conf shape (IPv4 only, no `ListenPort`, no `Table=`, no hooks):

```
[Interface]
PrivateKey = <exits.privkey>

[Peer]
PublicKey = <exits.pubkey>
PresharedKey = ...          # only if set
AllowedIPs = 0.0.0.0/0
Endpoint = <exits.endpoint>
PersistentKeepalive = 25
```

**This file is `wg setconf` grammar, not wg-quick grammar, and the difference
is load-bearing.** `wg(8)` accepts only `PrivateKey` / `ListenPort` / `FwMark`
in `[Interface]` and `PublicKey` / `PresharedKey` / `AllowedIPs` / `Endpoint` /
`PersistentKeepalive` in `[Peer]`; anything else is a hard parse failure
(`Line unrecognized: 'MTU=1280'`, exit 1, before the netlink call). The wg0
path survives an `MTU =` line only because `cmd_apply` runs `wg-quick strip`
first, and this path deliberately does not. So **no `MTU =`** here — the helper
sets it with `ip link set … mtu` at step 5, which is the only place it belongs.
`mtu` stays a top-level field on `Exit.desired`.

Same reason there is no `Address=` — the helper installs the `/32` with
`ip addr`, as with site extras. Keeping both out means a stray `wg-quick`
still would not have a complete recipe (the `/0` AllowedIPs is already enough
to be dangerous, which is why the conf never lands in `/etc/wireguard/`).

`PersistentKeepalive` is not cosmetic either: it holds the WAN-side UDP
conntrack entry open so the remote's replies keep matching the base firewall's
`ct state established,related accept`. Without it the exit dies roughly
30 seconds after the last packet.

`Reconciler#apply!` already sends `routes` / `addresses` from
`Renderers::Routes.desired`. Add `exit:` from `Renderers::Exit.desired`.
`HelperClient#apply` gains `exit: nil`.

**`local_v4_except_wg` must exclude `$EXIT_IF` too.** It skips only `WG_IF`
today, so the moment step 4 puts `172.16.0.2/32` on `wg-exit` that address
joins `steal_targets` — and the *next* apply's `raise_if_steals!("exit
address", "172.16.0.2")` matches the exit's own address and raises. Enabling
the exit would brick `apply!` from the second reconcile onward, surfacing as a
bare `Naaf::HelperClient::Error` because `failed!` keeps the class only. One
extra `next if` in that method; it is not implied by "add `sync_exit`", so it
is called out here.

Side effect of the same list, and intended: with the exit up, a site network
covering the exit address is refused by the helper as a steal. The form should
refuse it first (see Data model).

`cmd_apply` after the existing site addr/route sync:

**up** (`exit` present):

1. `ip link add $EXIT_IF type wireguard` (ignore EEXIST). Refuse if
   `$EXIT_IF` equals `WG_IF` or fails `IFACE_NAME`.
2. Render the conf into a `Tempfile.create`, mode 0600, size-capped like
   `wg_conf`. **Not** a file under `/run/naaf`: nothing needs it after the
   call, `wg setconf` only wants a path, and `cmd_apply` already does exactly
   this for the wg0 `syncconf`. A tempfile *removes* the "one
   `systemctl enable wg-quick@wg-exit` away from a lockout" hazard instead of
   documenting it.
3. `wg syncconf $EXIT_IF <path>`. Always `syncconf` — it works on a freshly
   created interface with no private key, so the setconf/syncconf branch buys
   nothing but a second code path. **Never** `wg-quick`.
4. `ip addr replace $address/32 dev $EXIT_IF` (steal-check first).
5. `ip link set $EXIT_IF up mtu $mtu`.
6. Diff table 159 against `routes`. `default` is allowlisted only when
   `dev == $EXIT_IF`. Site CIDRs and site `/32`s in this table must be
   `dev == WG_IF` and pass `valid_v4_cidr?` + `raise_if_steals!` (same as
   proto 158).
7. Reconcile the three `ip rule`s **by pref *and* spec**. Parse
   `ip -4 rule show`, normalize, and replace only the prefs whose spec
   differs. Matching on pref alone leaves a stale `to <old wg_subnet>` on
   pref 15850 forever after a subnet change, because the pref is still
   present; and `ip rule add` is not idempotent, so re-adding duplicates.
   Do **not** blanket delete-then-add every apply — that opens a window where
   `iif wg0` falls through to `main` and leaks the VPS IP, which is exactly
   what decision 6 refuses to allow.

**down** (`exit` absent/null):

1. Delete prefs 15800 / 15850 / 15900 if present.
2. `ip route flush table 159`.
3. `ip link del $EXIT_IF` if it exists.

Order in `cmd_apply` stays: wg0 `syncconf`, `nft -f`, site addrs/routes,
**then** `sync_exit`. On disable, nft has already dropped the
`oifname wg-exit` masquerade; `iif wg0 oif wg-exit` still falls through to
`policy accept` until the iface is deleted. Brief window, then WAN
masquerade matches again. Do not reorder to "delete iface first" — that
would blackhole mid-apply while rules still point at it.

`dump` stays one command. When `$EXIT_IF` exists, also return `exit_dump`
(`wg show $EXIT_IF dump`). Omit the key when the iface is absent (disabled,
or an old helper). `poll!` parses it the same way as the wg0 dump and writes
handshake / rx / tx / `observed_endpoint` on the exits row. The wg0
expected-peer set does **not** include the exit pubkey — different iface;
counting it would `apply!` forever.

`HelperClient#dump` is `call("dump")["dump"]` today and has nowhere to put a
second key. **Change it to return the whole response hash** and have `poll!`
reach for `["dump"]` / `["exit_dump"]`. One accessor, not two: AGENTS.md's
rule is that the dump is read in exactly one place, and a second reader is one
more seam for line 1 of either dump — both of which are private keys — to
escape through. `poll!` stays the only caller.

**No exit drift detection in v1, and no capability bit.** `poll!` re-applies
only on wg0 peer-set drift; if `wg-exit` is deleted out from under the app
while the row is enabled, nothing notices until the next `apply!`. That is
deliberate. The obvious rule — "an enabled exit with no `exit_dump` is drift"
— cannot distinguish a deleted interface from an **older helper that never
sends the key**, and would `apply!` forever on exactly the box this plan
promises will degrade silently. Recovery is `POST /apply` or a restart
(`bin/naaf` applies at startup). Say so in `docs/TROUBLESHOOTING.md`.

---

## nftables (`inet naaf` only)

Spoke block is unchanged. When an enabled exit exists, add:

```
chain forward {
  # ... existing wg↔wg block, including counter drop ...
  # ... existing WAN→wg DNAT accepts ...

  iifname "#{wg}" oifname "#{exit_if}" tcp flags syn / syn,rst tcp option maxseg size set #{mtu - 40}
  iifname "#{exit_if}" oifname "#{wg}" tcp flags syn / syn,rst tcp option maxseg size set #{mtu - 40}
  iifname "#{wg}" oifname "#{exit_if}" accept
}

chain mangle_prerouting {
  type filter hook prerouting priority mangle; policy accept;
  iifname "#{wan}" ct mark set 159
  ct mark 159 meta mark set 159
}

chain postrouting {
  ip saddr #{net} oifname "#{wan}" masquerade            # stays — disable path + hub
  oifname "#{wg}" ct status dnat masquerade              # stays
  ip saddr #{net} oifname "#{exit_if}" masquerade        # new
  # existing per-site SNAT ...
}
```

Every interface name is interpolated from `Naaf.settings` / `Config`, never a
literal. `eth0` is the DEFAULTS seed and is wrong on most boxes — the WAN NIC
is discovered at bootstrap (`Renderers::Nftables` already reads
`s[:wan_interface]`).

**MSS clamp, both directions, at an explicit size.** An MSS option in a SYN
advertises what the *sender is willing to receive*, so a clamp on
`wg0 → wg-exit` only constrains internet→client. Client→internet is set by the
SYN-ACK arriving on `wg-exit`, which that rule never sees. The mirror rule with
`rt mtu` does not fix it either: for `wg-exit → wg0` the egress route MTU is
wg0's 1420, not the 1280 bottleneck the data will actually cross. So clamp both
directions to `exits.mtu - 40`, which the renderer already has. Use the masked
form `syn / syn,rst`; nft's bare `tcp flags syn` is an exact match on the flags
field and will not match a SYN-ACK. Without this the client→internet direction
falls back to PMTUD, which is the black hole MSS clamping exists to prevent.

`iifname` / `oifname` match by **name**, so this ruleset applies cleanly while
`wg-exit` does not yet exist. That is what makes the `nft -f` → `sync_exit`
ordering safe; do not switch to `iif` / `oif` (ifindex).

The mark scheme is deliberately broad: every WAN-inbound connection gets
`ct mark 159`, not just the DNAT'd ones, because at `priority mangle` (-150)
`dstnat` (-100) has not run yet and `ct status dnat` is not set on the first
packet. Nothing else consumes the mark, and the only rule that reads it needs
`iif wg0`, so hub-terminated connections are unaffected.

One consequence to document, not fix: connections that already existed when
the exit was enabled carry no `ct mark`, so port-forward replies on those take
pref 15900 into the exit until they expire. New connections are correct.

WAN masquerade stays even when the exit is up: hub-originated traffic and
the disable path both need it. Do not SNAT `ip daddr 0.0.0.0/0 oif wg0` —
that would SNAT spoke↔spoke.

Empty `site_nets` is unchanged. The exit is **not** a site net.

No change to `/etc/nftables.conf` and none needed: its input chain opens with
`ct state established,related accept`, which is what lets the remote's replies
reach the exit socket's ephemeral source port.

---

## ConfigBuilder

Untouched. `full` is already exactly `0.0.0.0/0`. Split / split-ws keep
`wg_subnet` + extra_routes + enabled site LANs. `audit_transport_capture`
still raises for ws `/0` and still warns for split covering the endpoint.

An exit is not a site LAN. Do not select `exits` anywhere in
`allowed_ips`.

---

## WARP register

`POST /exit/warp` (CSRF, session, the usual `submit`):

1. Refuse if an `exits` row already exists.
2. `helper.genkeys` → keep `private_key` + `public_key`, drop the PSK
   (WARP does not use one).
3. `Naaf::Warp.register(public_key)` — stdlib `Net::HTTP` POST to
   `https://api.cloudflareclient.com/v0a737/reg` with the same JSON as
   [warp-register.sh](https://raw.githubusercontent.com/lanrat/wireguard-warp-generator/refs/heads/main/scripts/warp-register.sh):

   ```json
   {
     "key": "<pubkey>",
     "install_id": "",
     "warp_enabled": true,
     "tos": "<utc now %Y-%m-%dT%H:%M:%S.000+00:00>",
     "type": "Linux",
     "locale": "en_US"
   }
   ```

   Send the script's **headers** as well as its body — `Content-Type:
   application/json`, `CF-Client-Version`, and the matching `User-Agent`. The
   endpoint rejects a request without the client-version header, and under the
   "fail loudly" rule below that arrives as an unexplained 403 on first use.
   Pin them next to the path; they version together.

4. Require `config.peers[0].public_key`, `config.peers[0].endpoint.host`,
   `config.interface.addresses.v4`. Anything missing or `null` is a
   `ValidationError`, not a 500. IPv6 address ignored.

   `endpoint.host` (`engage.cloudflareclient.com:2408`), not `endpoint.v4`,
   deliberately: the name is what survives Cloudflare moving an anycast
   address. The cost is that `wg syncconf` resolves it in userspace on every
   apply, so the helper depends on the box's resolver, and on a dual-stack box
   it may resolve to v6 — which is fine, the outer transport is unrelated to
   the IPv4-only decision about the tunnel's own addressing. If the box has no
   working resolver at apply time, store the `v4` literal by hand instead;
   the manual path exists for that.
5. Insert `provider=warp`, persist `privkey`. Never put the privkey (or the
   raw API body) in the flash, the journal at info, or the redirect.
6. `reconciler.apply!`.

The Cloudflare client API is unofficial and can break. Fail loudly. Never
re-register on boot — the privkey in the DB is what reconnects.

No WARP+ / license / token storage. The API returns a token; we do not keep
it. No periodic refresh.

Timeout: 10s. Under Falcon, `Net::HTTP` waits are fiber waits (scheduler
hooks the socket). Tests stub `Naaf::Warp.register`. No `curl`, no helper
command, no new gem.

Manual path: paste `PrivateKey`, peer `PublicKey`, `Endpoint`, `Address`
(the script's stdout). "Generate a keypair" is allowed (`helper.genkeys`)
and the privkey is stored and never shown again — same rule as
`server_privkey`, not the client oneshot stash.

---

## UI

`/exit` — nav item **Internet exit**, between Sites and Routes.

Empty state: manual form + button "Register with Cloudflare WARP".

Populated: name, provider chip, enabled chip, endpoint, address, MTU,
keepalive, last handshake, pubkey truncated. Enable / disable / delete
(delete behind `<details>` like sites). Edit of pubkey / endpoint / address
/ keepalive / mtu / notes. No privkey field after insert. No QR. No
download.

Copy, on the page:

- Full-tunnel clients leave via this peer. Destinations see its address,
  not this box.
- Split clients do not send internet here.
- This box's own traffic (SSH, DNS passthrough, backups, Troubleshoot)
  stays on the VPS.
- A down peer blackholes client internet. Disable to restore WAN
  masquerade.
- Everything a full client sends that is not the VPN subnet, a site network
  or this box itself goes here — including the VPS's own network neighbours.
  Reaching this box's admin UI on its public address still works (the `local`
  table is consulted before these rules).

Flow tester, **both** internet-bound branches: when an enabled exit exists the
egress step quotes `ip saddr <wg_subnet> oifname "<exit-if>" masquerade` and
names the exit; when disabled or absent, keep today's WAN masquerade line.

- `to_internet` — the obvious one.
- `to_extra` — less obvious and equally wrong if skipped. It currently tells
  the operator the packet "follows its default route out of `<wan>`,
  masqueraded" and quotes the WAN rule. A global `/0` extra route turns split
  into full (see Routing), and those packets take the same `iif wg0` path and
  leave via the exit. Leaving `to_extra` alone makes the flow tester lie in
  the one case this plan already identified.

Metrics: `role_of` grows `:exit` for `NAAF_EXIT_INTERFACE` — independent of
the rest and fine as-is.

Peer stats need a decision, because **publishing the exit into `PeerStats` on
its own renders nothing.** `Metrics::Collector` builds its peer list only from
`raw[:clients]` and `raw[:sites]`, and `retain_series!` keeps
`peer.<pubkey>.*` rings for those same two sources; a third entry in the
sample is a key nothing reads. Either:

- **(a)** extend the collector — `raw[:exit]`, a `peer_entry(kind: :exit, …)`,
  and the exit pubkey in `retain_series!`'s `live` list, so it appears in top
  talkers the way a site does; or
- **(b)** drop the `PeerStats` publish and show the exit's handshake / rx / tx
  on `/exit` only, straight off the row `poll!` already writes.

Pick **(b)** for stage 4 and (a) later if the dashboard wants it. What must
not ship is the middle: a publish that reads as done and is a no-op.

---

## Files

| Path | Change |
|---|---|
| `db/schema.rb` | `exits` |
| `lib/naaf/config.rb` | `NAAF_EXIT_INTERFACE` default `wg-exit` |
| `lib/naaf/renderers/exit.rb` | new, pure |
| `lib/naaf/renderers/nftables.rb` | exit forward / NAT / mark / MSS |
| `lib/naaf/helper_client.rb` | optional `exit:` on `apply`; `dump` returns the whole response hash |
| `bin/naaf-helper` | `sync_exit`; optional `exit_dump`; `local_v4_except_wg` excludes `$EXIT_IF` |
| `lib/naaf/reconciler.rb` | pass `exit:`; parse `exit_dump`; do not count exit in wg0 expected set |
| `lib/naaf/warp.rb` | register client (body **and** headers) |
| `lib/naaf/app.rb` | `/exit` routes + validators; `assert_unused_pubkey!` covers exits; `param_site_cidr` refuses the exit address |
| `lib/naaf/flow.rb` | internet egress via exit — `to_internet` **and** `to_extra` |
| `lib/naaf/metrics/collector.rb` | `:exit` role (peer stats: see UI, option (b) ships nothing here) |
| `views/exit.erb` | page |
| `views/layouts/app.erb` | nav |
| `test/helper.rb` | wipe `:exits` |
| `AGENTS.md` | fifth renderer; `apply` projects four things, not three; table 159; never wg-quick on exit; no `MTU=` in a `setconf` file; `exits.privkey` |
| `docs/TROUBLESHOOTING.md` | new section: client internet dead with exit enabled; no exit drift detection, recovery is `POST /apply` |
| `docs/BACKUP.md` | snapshots now carry a second private key (`exits.privkey`), not only `server_privkey` |
| `naaf.conf.example` | commented `NAAF_EXIT_INTERFACE=wg-exit` |

No new systemd unit. No `deploy/nftables.conf.template` change. No
`wg-quick@wg-exit`. Bring-up stays helper → bootstrap → naaf `apply!` →
`wg-quick@wg0`; `apply!` is what creates `wg-exit`.

---

## Tests

Each behavior, then `bin/ci`. Do not delete the tests that pin today's `/0`
refusals — extend them.

| File | Pin |
|---|---|
| `test/renderers_exit_test.rb` | enabled → conf has their pubkey, `AllowedIPs = 0.0.0.0/0`, our privkey, no `ListenPort`, no `Table=`; **the conf contains no `MTU`, `Address`, `DNS`, `PreUp` or `PostUp` line** — i.e. it is pure `wg setconf` grammar, and this is the guard against someone "fixing" `MTU` back in; disabled / missing → `nil`; table 159 site CIDRs *and* site `/32`s point at `wg0`, `default` at `wg-exit`; rules are the three prefs |
| `test/renderers_nftables_test.rb` | spoke `counter drop` still present; no `/0` in `site_nets`; `oifname "<exit>" masquerade` only when enabled; mangle mark 159 only when enabled; **MSS clamp present in both directions at `mtu - 40`**; every iface name comes from settings, no literal `eth0`; WAN masquerade still present; never `policy drop`; `nft -c -f` including enabled exit + non-empty `site_nets` |
| `test/helper_test.rb` | proto 158 `/0` still `"invalid site route"`; table 159 `default` on `$EXIT_IF` allowed; `default` on `wg0` or in main refused; **`local_v4_except_wg` filters a `wg-exit` line out of stubbed `ip -4 -o addr show` output** — note the existing harness overrides `steal_targets` wholesale, so a test written against *that* seam passes with the bug present and proves nothing; **two applies in a row with the same `exit` payload both succeed**; no `wg-quick` argv containing `$EXIT_IF`; **a changed `wg_subnet` replaces pref 15850 rather than leaving the old spec**; missing `exit` key is a no-op; down path deletes link + three prefs + flushes 159 |
| `test/config_builder_test.rb` | split AllowedIPs unchanged with an exit row present; ws still refuses `/0` |
| `test/app_test.rb` | second insert refused; WARP stub persists privkey and the body never contains it; toggle/delete call `apply!`; client/site insert refuses the exit pubkey; **exit address inside a `site_networks` CIDR refused, and a site network covering the exit address refused** |
| `test/flow_test.rb` | client→internet quotes wg-exit masquerade when on, WAN when off; **same for the `to_extra` branch** |
| `test/reconciler_test.rb` | exit pubkey not in wg0 expected set; `exit_dump` updates handshake; a response with **no** `exit_dump` key does not trigger `apply!` (the old-helper case); `apply!` forwards `Exit.desired` |
| `test/warp_test.rb` | parses a fixture response; **sends `CF-Client-Version` and `User-Agent`**; missing peer key / address / endpoint raises; IPv6 ignored; does not persist a token |

`bin/ci` already runs `nft -c -f` on renderer output. Add an enabled-exit
fixture to that set — the MSS clamp and the mangle chain are new syntax that
nothing else checks.

---

## Privilege check

| Surface | Verdict |
|---|---|
| Helper commands | Unchanged. `exit` on `apply` and `exit_dump` on `dump` are optional fields |
| `apply` side effects | Widened: second WireGuard iface, `ip rule`, table 159. This plan is the approval |
| Root in the web process | None. WARP HTTPS is unprivileged. `genkeys` stays in the helper |
| `/etc/nftables.conf` | Untouched |
| `ip_forward` | Untouched |
| Client private keys | Untouched. `exits.privkey` is the hub-toward-remote key |
| Older helper | Silently skips `exit`. Safe (WAN still works). Document, do not detect |

---

## Out of scope

- IPv6
- Multiple exits
- Hub-originated traffic through the exit
- Auto-fallback when the handshake is stale
- Kill-switch that blocks WAN if the exit dies (locks clients off internet)
- WARP+ / license redeem / stored API token
- Full-tunnel-over-ws
- A fifth helper command
- Anything in `/etc/nftables.conf`
- Renaming `wg-exit` from the UI
- Re-register on boot or on a timer

---

## Implementation order

One branch, `feat/internet-exit`. Each stage ends at green `bin/ci` and its
own commit.

1. Schema + `Renderers::Exit` + helper `sync_exit` / `exit_dump` +
   `local_v4_except_wg` excluding `$EXIT_IF` (the privilege boundary). Tests
   that pin `/0` on proto 158 still pass.
2. Nftables renderer (bidirectional MSS clamp, mangle mark, exit SNAT) +
   `nft -c -f`.
3. Reconciler + HelperClient wiring, including `dump` returning the full
   hash. Expected-peer set unchanged; no exit drift detection.
4. `/exit` UI, validators (address vs. site networks, both directions),
   `Naaf::Warp` with its headers, pubkey uniqueness.
5. Flow (`to_internet` **and** `to_extra`), metrics role, Troubleshoot copy,
   AGENTS.md, TROUBLESHOOTING.md, BACKUP.md.
6. `bundle exec standardrb --fix` and `bin/ci`.

On a box, before calling it done: `apply!` **twice** with the exit enabled
(the single-apply case hides the steal-check self-collision), a continuous
spoke↔spoke ping across both applies, `curl -4` from a full client showing the
upstream address while the same `curl` on the hub still shows the VPS IP, and
then disable and confirm client internet returns via WAN masquerade.

Commits: `<type>: <imperative ~60 chars>`. No Co-authored-by.
