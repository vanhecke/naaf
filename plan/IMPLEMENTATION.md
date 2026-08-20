# Naaf — F1–F7 consolidated implementation plan

Supersedes `plan/FEATURES-F1-F7.md` and `plan/grok.md`. Where those two disagreed,
the resolution and its reason are recorded here.

## Context

Seven features against `naaf` (Roda + Falcon + async-dns on one shared Async reactor,
Sequel/SQLite as the single source of truth, a root helper daemon as the only privileged
code):

| ID | Ask |
|----|-----|
| F1 | Per-domain upstream DNS (`*.example.com` → `9.9.9.9`) |
| F2 | A DNS server attached to a site (`*.roomkoetje.be` → `192.168.1.85`) |
| F3 | Site-owned forwarders shown read-only inside F1 |
| F4 | Site-generated routes shown read-only on the Routes page |
| F5 | A Troubleshoot page: ping, traceroute, curl, and a route/flow tester |
| F6.1 | Exposed ports grouped per client |
| F7.1 | Dashboard: sites listed as peers |
| F7.2 | Dashboard: top talkers beside DNS |

Two problems drive most of this. First, the box can already reach site LANs but has no way
to *resolve* names in them, and there is no way to send one domain to a different resolver —
F1/F2 fix that; F3/F4 make what a site silently generates visible instead of asking the
operator to trust a sentence in the page copy. Second, when something does not work there is
no in-UI way to find out why: today it is `ssh` plus `docs/TROUBLESHOOTING.md`. F5 puts the
first three steps of that playbook, plus a static reachability analysis, in the admin UI. F7
closes two gaps in the dashboard's own honesty — sites are measured but never shown, and
there is no per-peer bandwidth ranking.

---

## Decisions taken (approved — do not relitigate)

1. **Diagnostics subprocesses run in the web process, unprivileged.** They are unprivileged
   binaries (Debian ships `/usr/bin/ping` with `cap_net_raw+ep`; traceroute's default UDP
   mode needs no privilege; curl needs none). Running them as root behind the helper socket
   would be strictly worse and would widen a four-command root vocabulary for no gain.
   **The helper vocabulary stays at four: `genkeys` / `apply` / `dump` / `ping`.**
   AGENTS.md gets an explicit amendment (stage 7) rather than a silent contradiction.
2. **Top talkers is per peer.** Per-destination bytes are unreachable without root:
   `/proc/net/nf_conntrack` is `0440 root:root` (see `lib/naaf/metrics/proc_fs.rb`) and `nft`
   counters need `CAP_NET_ADMIN` *and* would reset on every `apply` (which deletes and
   recreates `table inet naaf`). The panel says so in copy rather than implying it measured
   something it did not. **No helper `conntrack` command, no `nf_conntrack_acct` sysctl.**
   The deferred design for that is recorded under "Out of scope" so the reasoning is not lost.
3. **One branch, one pass.** Work in a git worktree off `main`, branch `feat/f1-f7`. The
   stages below are an ordering, not separate branches — but each stage ends at a green
   `bin/ci` and its own commit, so a stage that goes wrong is one `git revert` away.
4. **One new table** (`dns_forwarders`) — additive; `create_table?` covers it,
   `alter_existing!` is untouched. This is the AGENTS.md "Ask first: schema changes" item and
   it is approved. No column is added to `sites`; no second table for site domains.
5. Conditional forwarding is a **third section on `/dns-records`** (nav label → "DNS"), not a
   new page.
6. The flow tester renders a **step list**, no new SVG primitive, and is a **GET** (pure read,
   bookmarkable, no CSRF token needed).
7. `curl` **refuses `169.254.0.0/16`**; ping and traceroute do not.

---

## Corrections to the source plans (verified against the installed code)

**`plan/grok.md` is wrong about upstream failure.** It states that if a site DNS server is
unreachable "async-dns fails that query (ServFail) and the rest of the resolver is
unaffected". It does not. async-dns 1.4.1 has **no timeout anywhere on the upstream path**:

```
gems/async-dns-1.4.1/lib/async/dns/resolver.rb:223
    def try_datagram_server(request, socket)
      socket.sendmsg(request.packet, 0)
      data, peer = socket.recvfrom(UDP_MAXIMUM_SIZE)   # <- bare, no deadline
```

`Resolver#query` → `dispatch_query` → `try_server` → `try_datagram_server` adds no deadline of
its own either. A dead upstream parks the query fiber and its UDP socket **forever**. This is
latent today with one upstream; F2 makes it routine, because a site with a down tunnel means
every query for that domain leaks a fiber and a socket. **Fixing it is a hard prerequisite for
F2 and is scheduled in stage 4.**

Everything else both plans assert about the codebase was checked and holds: `HelperClient#call`
does hold a `Mutex`; the helper is thread-per-connection; `Reconciler#poll!` already records
site handshake/traffic into `PeerStats`; `extra_routes` install no hub route; the forward chain
order is as both quoted; htmx is 2.0.10 so `hx-disabled-elt` and `htmx-indicator` are available;
`Async::Scheduler#with_timeout` and `Async::Semaphore` both exist in async 2.43.0.

---

## Reuse, do not reinvent

| Need | Already exists |
|------|----------------|
| Anchored hostname class | `App::HOSTNAME` (`lib/naaf/app.rb:431`) — every label starts alphanumeric, so `1.168.192.in-addr.arpa` matches and a leading `-` cannot arrive |
| IPv4 / port / CIDR validation | `App#param_ipv4`, `#param_port`, `#param_cidr`, `#param_port_range`, `#param_host` |
| CIDR overlap / merge | `IPAM.overlap?`, `IPAM.parse_v4`, `IPAM.merge_v4_cidrs` |
| Write-then-apply-then-redirect | `App#submit(path)` |
| Read-only-section UI pattern | "Automatic records" block in `views/dns_records.erb` |
| Per-client split routes | `ConfigBuilder#allowed_ips(flavor)` |
| Desired kernel routes | `Renderers::Routes.desired(db)` |
| Meter / progress bar | `<progress class="progress is-small">` as in `views/metrics/kpis.erb`; `.progress` already styled |
| Tile state colour | `.box.naaf-warn` / `.box.naaf-alert` in `vendor/naaf.css` |
| Number formatting | `Naaf::Format.bps/bytes/compact/pct/ago/dash`; `Metrics::Num.pct/rate` |
| Fragment render without layout | `render("metrics/#{name}", locals: {...})` as in `app.rb:543` |
| Async test harness | `Sus::Fixtures::Async::ReactorContext`, as in `test/metrics_hub_test.rb` |

---

# Stage 1 — F6.1: exposed ports grouped per client

View and route only. No schema, no renderer, no apply path — `Renderers::Nftables` reads the
table directly and is untouched.

### `lib/naaf/app.rb` — `r.on "exposed-ports"` / `r.get true`

```ruby
r.get true do
  @clients = Naaf.db[:clients].order(:name).all
  rows = Naaf.db[:exposed_ports].order(:proto, :port).all
  by_client = rows.group_by { |row| row[:client_id] }
  # Every client gets a group, empty ones included: "this client exposes nothing"
  # is the answer to the question the page is usually opened with.
  @groups = @clients.map { |c| {client: c, rows: by_client.delete(c[:id]) || []} }
  # The FK cascade should make this impossible, but a grouped view that silently
  # drops a row is worse than one that shows an orphan.
  @orphans = by_client.values.flatten
  view("exposed_ports")
end
```

`@rows` stays available to the add form's client `<select>` via `@clients`; if the current view
reads `@rows`, replace those reads rather than keeping both.

### `views/exposed_ports.erb`

One Bulma `.box` per client: name, `<code>` VPN IP, a count chip, then a narrow
proto / port(s) / description / delete table. A client with nothing exposed renders one grey
line: *"No ports exposed. Other spokes cannot reach this client."* Add form unchanged at the
bottom. Keep the existing global empty state for the no-rows-at-all case ("No exposed ports.
Spoke-to-spoke traffic is fully denied."). Render `@orphans` in a final `.box.naaf-warn` only
when non-empty.

> Resolution: `FEATURES-F1-F7.md` shows every client; `grok.md` shows only clients that have
> rows. Every client wins — the page is opened to answer "what can reach this machine", and an
> absent client reads as "I have not looked yet" rather than "nothing".

### Tests — `test/app_test.rb`

GET `/exposed-ports` with two clients and mixed ports: each client's name appears as a heading
**before** that client's ports, document order is grouped (not a flat interleave), and a client
with no rows renders the per-client empty line.

**Commit:** `feat: group exposed ports by client`

---

# Stage 2 — F4: site networks read-only on Routes

Site networks are already folded into every split `AllowedIPs` by `ConfigBuilder#allowed_ips`,
and `views/extra_routes.erb` already tells you not to add them by hand. Make it visible.

Do **not** insert `site_networks` rows into `extra_routes`. That would create a second source of
truth and a delete button that does not disable the site route.

### `lib/naaf/app.rb` — `r.on "extra-routes"` / `r.get true`

Load `@site_routes`: `site_networks` joined to `sites`, ordered by site name then CIDR,
carrying `sites.enabled` and `sites.id`.

While both lists are in hand, flag a manual route a site already covers:

```ruby
@redundant = @rows.to_h { |row|
  [row[:id], @site_routes.find { |s| s[:enabled] && IPAM.overlap?(row[:cidr], s[:cidr]) }]
}.compact
```

A disabled site's networks are not installed, so they do not count as covering anything.

### `views/extra_routes.erb`

A **"From sites"** section **above** the manual table, read-only, same treatment as "Automatic
records": scope tag `site` + site name, CIDR, a "managed on Sites →" link, **no delete button**.
Disabled sites carry a `disabled` chip. A redundant manual row renders
`<span class="tag is-warning is-light">also routed by site X</span>`.

Extend the intro copy: site networks are folded into split configs automatically and are listed
here so the split-tunnel set is visible in one place. The existing empty-extra-routes
notification must not claim "split configs route only the VPN subnet" when site rows exist —
branch that copy on `@site_routes.any?`.

### Tests — `test/app_test.rb`

A site with `192.168.1.0/24` appears as `<code>` on GET `/extra-routes`; no delete form exists
for it; an overlapping manual route carries the redundancy tag; a disabled site's network does
not produce a redundancy tag. Existing extra-route CRUD tests stay green.

**Commit:** `feat: show site networks read-only on Routes`

---

# Stage 3 — F7.1 + F7.2: sites as peers, and top talkers

`Reconciler#poll!` already calls `record_peer!` for `@db[:sites]` and writes those entries into
the same `measured` hash keyed by pubkey, so `Metrics::PeerStats` carries site throughput today
— the collector is the only thing ignoring it. **No new reader of `wg show dump`**; that stays
`Reconciler#poll!`'s alone (AGENTS.md "Never").

### `lib/naaf/metrics/collector.rb`

**`sample`** adds `sites:` — `@db[:sites].order(:name).all` plus their networks (the collector
tick is already the only place that touches the DB; this is one extra query, not on the render
path).

**`peer_sections`** builds site entries alongside client ones. Per site:

- `kind: :site` (clients gain `kind: :client`)
- `name`, `enabled`, `last_handshake_at`
- `endpoint`: `m&.dig(:endpoint) || site[:observed_endpoint]` — same precedence as clients
- `wg_ip`: `site[:address]` if set, else `nil` (renders as an em dash)
- `cidrs`: that site's networks, for the column where a client renders its `/32`
- `rx_bps` / `tx_bps` / `rx_series` / `tx_series` keyed on pubkey, identical to clients
- `online` uses the same `ONLINE_WITHIN`

Sort stays busiest-first, then online, then name — extend the existing sort key with `name` as
the tiebreak since a site has no `wg_ip`.

Three details that bite if missed:

1. **`retain_series!` must add site pubkeys to `live`**, or every site's ring is evicted on the
   tick after it is created and the sparkline never fills.
2. **Fold site rates into `wg[:rx_bps]` / `wg[:tx_bps]`** — that is real tunnel throughput and
   excluding it understates the hero tile. But leave **`wg[:total]` / `[:enabled]` / `[:online]`
   counting clients only**, and add `sites_total` / `sites_enabled` / `sites_online` beside them.
   `Collector#judge` uses the first three for the stall detector: an online site would make
   `wg[:online].positive?` true and mask a genuine total client outage, which is the exact
   situation the detector exists for. This also keeps every existing example in
   `test/metrics_collector_test.rb` passing.
   > Resolution: `grok.md` folds sites into `wg[:total/enabled/online]`. Rejected for the reason
   > above.
3. **A site with no networks is not a kernel peer** (WireGuard refuses empty AllowedIPs), so it
   has no sample. Render *"not installed — no networks"*, not *"idle"* — the same reason
   `poll!` excludes it from the drift set.

**Talkers** are ranked in the collector (templates render snapshots, they do not rank them) and
published frozen:

```ruby
# One entry per peer, clients and sites together, busiest first. `share` is of the
# measured total, so it is nil until something has been measured — never 0, which
# would claim an idle tunnel.
measured = peers.reject { |e| e[:rx_bps].nil? && e[:tx_bps].nil? }
total    = measured.sum { |e| e[:rx_bps].to_f + e[:tx_bps].to_f }
talkers  = measured
  .map    { |e| e.merge(total_bps: e[:rx_bps].to_f + e[:tx_bps].to_f) }
  .sort_by { |e| -e[:total_bps] }
  .first(8)
  .map    { |e| e.merge(share: Num.pct(e[:total_bps], total)).freeze }
  .freeze
```

### `lib/naaf/metrics/snapshot.rb`

New `:talkers` member on the `Data.define` plus `EMPTY_TALKERS = [].freeze`. `EMPTY_WG` gains
`sites_total`, `sites_enabled`, `sites_online`. Peers already carry sites, so no new member is
needed for F7.1 itself. Only `Snapshot.empty` and `Collector#build` construct one, so this is
additive.

### `lib/naaf/metrics.rb`

`FRAGMENTS` gains `talkers`. It inherits `LIVE_FRAGMENTS` automatically (that constant is
`FRAGMENTS - %w[policy]`).

### Views

- **`views/metrics/clients.erb`** — panel retitled "Peers"; new **Type** column with a
  `client` / `site` tag; sites render their CIDR list where a client renders its `/32`, and an
  em dash for VPN IP when `address` is nil; header links to both `/clients` and `/sites`.
  **The fragment name stays `clients`** — it is an SSE event name and a `Metrics::FRAGMENTS`
  whitelist entry.
- **`views/metrics/talkers.erb`** (new) — name, kind tag, in/out via `fmt.bps`, a
  `<progress class="progress is-small">` share bar, total bytes since `wg0` came up via
  `fmt.bytes`.
- **`views/dashboard.erb`** — the panel rows become:

  ```
  health          (full width)
  kpis            (full width)
  pipeline        (full width)
  clients         (full width, now "Peers")
  dns  | talkers
  interfaces | policy      <- policy keeps its non-live treatment
  app             (full width)
  ```

Panel copy, non-negotiable:

> Per peer, refreshed every reconcile (30s). This box cannot break traffic down by external
> destination — per-flow byte counts need `/proc/net/nf_conntrack` (root-only) or `nft`
> counters (CAP_NET_ADMIN), and an `nft` counter would reset on every apply.

The dashboard's standing rule is that an unknown renders as an em dash and never as a zero; the
same honesty applies to a dimension it cannot measure at all. The DNS panel's "Top names" next
door is the answer to "where is it going" at name granularity.

`NAAF_METRICS_DNS_NAMES=0` does **not** hide talkers — IPs and peer names are not query names.
No new config key.

### `lib/naaf/metrics/collector.rb` — `policy_counts`

Nothing needed here yet; the `dns forwarding` chip lands in stage 4.

### Tests

- `test/metrics_collector_test.rb` — a tick with one client and one site (recent handshake,
  `PeerStats` sample for both pubkeys) gives `s.peers.size == 2`, the site's `kind == :site`,
  `s.wg[:online] == 1` (clients only) and `s.wg[:sites_online] == 1`; a site with no networks is
  listed but `online == false`; site rates are included in `wg[:rx_bps]`; `talkers` is ranked
  busiest-first, capped at 8, `share` is nil before anything is measured; deleting a site frees
  its ring (`retain_series!`).
- `test/app_test.rb` — `GET /metrics/talkers` is 200; the SSE fragment list includes `talkers`;
  a site name appears in `GET /metrics/clients`.

**Commit:** `feat: show sites as peers and rank top talkers`

---

# Stage 4 — F1 + F2 + F3: conditional DNS forwarding

The only stage touching the resolver hot path.

### Semantics

dnsmasq-style suffix match, **not** RFC 1034 wildcards:

- Stored suffix `example.com` matches `example.com` and `foo.bar.example.com`.
- The UI shows `*.example.com` as sugar; a leading `*.` is stripped on write.
- **Longest suffix wins.** `foo.example.com → 9.9.9.9` beats `example.com → 1.2.3.4`.
- **The local zone always wins.** `lookup_a` / `lookup_ptr` still run first in `#process`, so a
  client's `nas.vpn` A record is never forwarded.
- `settings.dns_upstream` is the fallback when no suffix matches.
- **AAAA for a forwarded name goes to that same forwarder.** The AAAA branch in `#process` only
  short-circuits for names the local zone knows; everything else falls through to the shared
  passthrough, which now consults `upstream_for`. AAAA for a local name stays an empty NOERROR.
- A **disabled site contributes no forwarder** — it is not a kernel peer and its route is not
  installed, so its resolver is unreachable. Dropping the rule turns a guaranteed timeout into
  an ordinary upstream answer.
- The matcher is plain DNS-name text, so `168.192.in-addr.arpa → 192.168.1.85` is a legal row
  and gives a site reverse lookups for free.

### Schema — `db/schema.rb`

Inside `migrate!`, **after** `site_networks` so the FK target exists:

```ruby
db.create_table?(:dns_forwarders) do
  primary_key :id
  # NULL = a rule the admin typed on the DNS page. Non-NULL = owned by a site,
  # read-only there, and deleted with it.
  foreign_key :site_id, :sites, on_delete: :cascade
  String  :suffix, null: false      # normalized: lowercase, no leading "*.", no trailing dot
  String  :server, null: false      # IPv4 literal
  Integer :port,   null: false, default: 53
  String  :notes
  # Global, not [site_id, suffix]: two rows for one suffix make resolution
  # ambiguous. The route refuses the clash with a message naming the owner.
  unique [:suffix]
end
```

`alter_existing!` is untouched.

> Resolution: `grok.md` proposed three schema objects — `dns_forwarders`, `site_domains`, and a
> `sites.dns_upstream` column — with suffix uniqueness enforced in Ruby across two tables
> (`assert_suffix_free!`). Rejected: one table gets the global uniqueness constraint from
> SQLite instead of from a check that can be raced or forgotten, gets cascade-delete for free,
> and gives `Zone#reload!` one query instead of a join plus a merge whose tie-break rule
> (`grok.md`: "site wins last-write in the hash") is a bug being documented rather than
> prevented. The cost is that a site's domains disappear when its resolver is cleared; the site
> form handles that by refusing to clear the resolver while domains remain (below).

`test/helper.rb`: add `:dns_forwarders` to the **head** of `reset_db!`'s wipe list (before
`:sites`). `make_site` gains optional `dns_server:` / `dns_port:` / `domains:` keyword arguments
that insert the matching `dns_forwarders` rows.

### Resolution — `lib/naaf/zone.rb`

Longest-suffix wins, falling out of the data structure: a flat hash keyed on the exact suffix,
walked by stripping one label at a time.

```ruby
attr_reader :upstream, :forwarders, :generation

def reload!
  # ... existing A / PTR / static-record build ...

  disabled = @db[:sites].where(enabled: false).select_map(:id).to_set
  fwd = {}
  @db[:dns_forwarders].order(:suffix).each do |r|
    next if r[:site_id] && disabled.include?(r[:site_id])
    fwd[r[:suffix]] = [r[:server], r[:port]].freeze
  end
  @forwarders = fwd.freeze        # whole-object swap, same discipline as @a / @ptr
  @generation = @generation.to_i + 1
  @upstream = Naaf.settings[:dns_upstream]
  self
end

# nil means "use the default upstream", so a box with no forwarders keeps
# exactly the code path it has today at the cost of one Hash#empty?.
def upstream_for(name)
  return nil if @forwarders.empty?
  n = self.class.normalize(name)
  loop do
    hit = @forwarders[n]
    return hit if hit
    i = n.index(".") or return nil
    n = n[(i + 1)..]
  end
end
```

### Hot path — `lib/naaf/dns_server.rb`

`require_relative "config"`. Add `UPSTREAM_TIMEOUT = Config.int("NAAF_DNS_UPSTREAM_TIMEOUT")`.

```ruby
# Memo keyed on the [ip, port] pair. Constructing a Resolver opens no sockets, so
# this is cheap; the reset is a whole-hash swap with no yield in it, which is what
# keeps it safe with one fiber per datagram.
def resolver_for(spec)
  return resolver if spec.nil?          # the settings upstream, unchanged
  gen = @zone.generation
  if @forwarder_generation != gen
    @forwarder_generation = gen
    @forwarder_resolvers = {}
  end
  @forwarder_resolvers[spec] ||=
    Async::DNS::Resolver.new(Async::DNS::Endpoint.for(spec[0], port: spec[1]))
end

# async-dns has no timeout of its own: try_datagram_server does a bare recvfrom,
# so an unreachable resolver parks this fiber and its socket for good.
# Fiber.scheduler#with_timeout only fires while blocked on IO — exactly this case —
# and is nil outside a reactor, so the stub-driven tests still run.
def with_upstream_timeout
  scheduler = Fiber.scheduler or return yield
  scheduler.with_timeout(UPSTREAM_TIMEOUT) { yield }
end
```

> Keying the memo on `@zone.generation` rather than on the forwarder hash's object identity
> (`grok.md`) means a `reload!` that produces an identical hash still invalidates, and there is
> no reliance on `Hash#freeze` returning a new object.

In `#process`, replace the passthrough line:

```ruby
spec  = @zone.upstream_for(name)
began = @stats && Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  result = with_upstream_timeout { transaction.passthrough!(resolver_for(spec)) }
rescue Async::TimeoutError
  # Named before the generic rescue below so a slow resolver is not filed as a
  # bug in this process.
  @stats&.record(:upstream_fail, name: name, remote: remote, ms: UPSTREAM_TIMEOUT * 1000.0)
  return transaction.fail!(:ServFail)
end
```

`Async::TimeoutError < StandardError`, so it must be rescued **before** the method's existing
bare `rescue => e`. The existing `@stats` block that follows (rcode → `upstream_ok` /
`upstream_fail`) is unchanged and still runs on the success path.

### Validation — `lib/naaf/app.rb`

```ruby
# HOSTNAME is reused rather than copied — same value class, every label starts
# alphanumeric, so an in-addr.arpa suffix matches and a leading "-" cannot arrive.
def param_dns_suffix(raw)
  s = raw.to_s.strip.downcase.chomp(".").delete_prefix("*.")
  raise ValidationError, "Domain is required." if s.empty?
  raise ValidationError, "Domain must be a DNS name like example.com." unless HOSTNAME.match?(s)
  # A single-label suffix would capture an entire TLD — and ".com" is not what
  # anyone means when they type it into this box.
  unless s.count(".") >= 1
    raise ValidationError, "Use at least two labels (example.com), not a bare top-level domain."
  end
  domain = Naaf.settings[:dns_domain]
  if s == domain || s.end_with?(".#{domain}")
    raise ValidationError,
      "#{s} is inside the internal zone (#{domain}), which this resolver already answers."
  end
  s
end

def param_dns_server(host_raw, port_raw)
  ip   = param_ipv4(host_raw)
  port = port_raw.to_s.strip.empty? ? 53 : param_port(port_raw)
  raise ValidationError, "0.0.0.0 is not a resolver address." if ip == "0.0.0.0"
  if (ip == Naaf.settings[:server_ip] || ip == "127.0.0.1") && port == Config.int("NAAF_DNS_PORT")
    raise ValidationError,
      "That is this resolver's own address — the query would loop back to itself."
  end
  [ip, port]
end
```

Note the loopback rule is deliberately **port-sensitive**: `127.0.0.1:5335` is a legitimate
local recursor and is allowed; only the box's own listening socket is refused.

Plus two more refusals:

- **Clash**, checked before insert so `Sequel::UniqueConstraintViolation` never surfaces as the
  generic "That entry already exists": name the owner —
  *"example.com is already forwarded to 9.9.9.9 by site roomkoetje."*
- **Site resolver must be reachable.** A site's `server` must sit inside one of **that site's**
  `site_networks`, because those are the only CIDRs `Renderers::Routes.desired` installs for it.
  A resolver outside them is "configured but the kernel has no proto-158 route to it" — an
  unexplained timeout. Setting a site DNS server with zero networks is a validation error, and
  deleting the last network that contains a site's resolver is refused with a message saying to
  clear the DNS server first.
  > Adopted from `grok.md`; `FEATURES-F1-F7.md` omitted it.

### Routes — `lib/naaf/app.rb`

| Path | Kind | Note |
|------|------|------|
| `GET /dns-records` | edit | loads `@forwarders` (left-joined to `sites` for the owner name) |
| `POST /dns-forwarders` | new | `submit("/dns-records")`; `site_id` is never a form field |
| `POST /dns-forwarders/:id/delete` | new | `.where(id: id, site_id: nil).delete` — a site-owned row cannot be deleted here *by query*, not by a check that can be forgotten |
| `POST /sites`, `POST /sites/:id` | edit | optional `dns_server`, `dns_port`, `dns_domains` (newline-separated); upsert into `dns_forwarders` with this site's id inside the same `submit` |
| `POST /sites/:id/forwarders/:fid/delete` | new | mirrors the existing `networks/:nid/delete` shape |

The site update path must refuse clearing `dns_server` while that site still has forwarder rows
(the message tells the admin to remove the domains first) — that is the compensating rule for
the single-table model.

### Views

- **`views/dns_records.erb`** — third section, **"Conditional forwarding"**, under
  Automatic/Static. Site-owned rows get a `tag is-light` naming the site, linked to `/sites`, and
  **no Delete button** — the same read-only treatment the automatic records already use.
  **This section is F3.** A line of copy states the fallback: *"Names matching no suffix go to
  the default upstream (`<%= @settings[:dns_upstream] %>`), set in Settings."*
- **`views/sites.erb`** — DNS server + port + domains fields in **both** the add form and the
  per-site `<details>` edit form (`site_attrs` is shared by both, so a new field cannot land on
  only one), plus the site's own forwarder list with a Remove button per suffix.
- **`views/layouts/app.erb`** — nav label `DNS records` → `DNS`. No new nav item.
- **`views/metrics/policy.erb`** + `Collector#policy_counts` — a `dns forwarding` count chip
  (`@db[:dns_forwarders].count`), linking to `/dns-records`.

Copy the site form must carry, because the failure mode is an unexplained timeout:

> A forwarded query is sent by the hub, from `server_ip`, over the site tunnel. It works only if
> the remote lists `wg_subnet` in its AllowedIPs, or Masquerade is on for this site (in which
> case the remote resolver sees the query from this site's assigned address). Same condition as
> reaching the LAN at all. `split-nodns` clients never use this resolver and are unaffected.

### Config — `lib/naaf/config.rb` + `naaf.conf.example`

`NAAF_DNS_UPSTREAM_TIMEOUT = "4"`. `test/config_test.rb` enforces both key parity and value
parity between the two files, so both change in the same commit.

### Apply path

`submit → Reconciler#apply! → Zone#reload!`. Forwarders are not a kernel projection, so no
renderer output changes and `wg syncconf` / `nft -f` are no-ops on this change. Going through
`apply!` anyway is what `/dns-records` already does and keeps `reload!` the single invalidation
point. **Do not add a second reload seam.**

### Tests

- `test/zone_test.rb` — longest suffix wins over a shorter one; apex match; unmatched name →
  nil; a disabled site's rule is absent; the empty-forwarder fast path returns nil without
  walking; a name the local zone answers never reaches the matcher; `generation` advances on
  `reload!`.
- `test/dns_server_test.rb` — **`StubZone` must gain `upstream_for` and `generation`**, or every
  existing example in this file breaks. `StubTransaction#passthrough!` already receives the
  resolver, so assert which endpoint it was built with. New: matching name → forwarder resolver;
  non-matching → settings upstream; AAAA for a forwarded name uses the forwarder; memo rebuilt
  when generation moves; timeout → ServFail with exactly one `upstream_fail` and no `servfail`.
- `test/app_test.rb` — forwarder CRUD; every refusal above (bare TLD, internal zone, self-loop,
  `0.0.0.0`, clash naming the owner, site resolver outside the site's networks, clearing a site
  resolver that still has domains, deleting the last network containing a resolver); a
  site-owned row renders no Delete button and its delete route is a no-op; deleting a site
  cascades its forwarders away; the existing "runs apply! after …" example still holds.
- `test/config_test.rb` — passes unchanged once both files carry the new key.

**Commit:** `feat: forward matching domains to a chosen resolver`

---

# Stage 5 — F5.4: the Troubleshoot page shell and the flow tester

Ships `/troubleshoot`, the nav item, and one working panel. Spawns nothing, so it is independent
of stage 6.

### `lib/naaf/flow.rb` (new)

Deliberately **not** under `renderers/` — AGENTS.md names exactly four renderers. This is an
analyzer over the same data, and it is pure.

```ruby
module Naaf
  module Flow
    # :hub | :client | :site | :extra | :vpn_unassigned | :internet
    Endpoint = Data.define(:kind, :ip, :label, :row, :enabled)
    # verdict: :pass | :fail | :warn | :info | :unknown
    Step     = Data.define(:stage, :verdict, :detail, :rule, :fix)
    Report   = Data.define(:src, :dst, :proto, :dport, :steps, :verdict, :summary)

    def self.analyze(db, src:, dst:, proto:, dport:) = ...
  end
end
```

**Classification, first match wins** (more specific role beats less specific):
`settings.server_ip` → `:hub`; a `clients.wg_ip` → `:client`; inside any **enabled** site's
`site_networks` CIDR → `:site`; inside an `extra_routes` CIDR but no site → `:extra`; inside
`wg_subnet` → `:vpn_unassigned`; else `:internet`.

`:vpn_unassigned` is reported first, before anything else runs — no peer owns that address.

Each stage mirrors one thing a renderer actually emits, so the tester cannot drift from the box
without a renderer test failing too.

**client → site**

1. `ConfigBuilder#allowed_ips` per flavor, **reported per flavor** so "which config did they
   install" is answered rather than assumed. `split-nodns` and the ws flavors route the same set
   as `split`; `full` routes everything.
2. Client enabled (`Renderers::WireGuard`).
3. `Renderers::Routes.desired(db)` contains the destination — proto 158 on wg0.
4. Cryptokey routing: which peer's AllowedIPs contain the destination. None → blackhole.
5. `iifname "wg0" oifname "wg0" ip daddr @site_nets accept`.
6. Masquerade note if the site masquerades: the source is rewritten to `site.address`, and
   return traffic cannot be *initiated* from the site toward a laptop.
7. `:unknown` for the remote side, stated as *"naaf cannot see this"*.

**client → client** — the port check must reproduce interval-set semantics exactly:

```ruby
# Matches what Nftables.merge folds into @vpn_tcp_allow: a row covers dport when
# port <= dport <= coalesce(port_end, port). NULL port_end means "ends where it
# starts", the reading every other consumer uses.
open = db[:exposed_ports]
  .where(client_id: dst.row[:id], proto: proto)
  .where { (port <= dport) & (Sequel.function(:coalesce, :port_end, :port) >= dport) }
  .first
```

Pass quotes `ip daddr . tcp dport @vpn_tcp_allow accept` (or the udp set); fail quotes
`iifname "wg0" oifname "wg0" counter drop` and links `/exposed-ports` with the client and port it
would need. ICMP passes on `iifname "wg0" oifname "wg0" icmp type echo-request accept`.

**client → extra-route-only destination** — a **`:warn`**: `extra_routes` are folded into client
`AllowedIPs` but install **no hub route**, so the kernel sends the packet out the WAN interface
under `ip saddr <wg_subnet> oifname <wan> masquerade`. That is almost never what the extra route
was added for. *(Adopted from `grok.md`; `FEATURES-F1-F7.md` omitted this case.)*

**client → internet** — `AllowedIPs` (only `full` routes `0.0.0.0/0`; a split client never sends
the packet to the hub at all, which is a blackhole, not a firewall verdict), then
`ip saddr <wg_subnet> oifname <wan> masquerade`.

**internet → client** — an enabled `port_forwards` row. Report the **public** port that reaches
the entered target, and `iifname "<wan>" oifname "wg0" ct status dnat accept`. With no matching
DNAT: the forward chain's policy is `accept`, but the Internet has no route to a private VPN
address — say exactly that rather than reporting "allow".

**site → client** — `iifname "wg0" oifname "wg0" ip saddr @site_nets accept`.

**anything → hub** — this is `input` in `inet filter`, which the app does not manage. Say exactly
that, and state what the base template contains: `iifname "wg0" accept`, tcp/22,
udp/`listen_port`, ICMP, a conditional wstunnel tcp port, then `counter drop`.

Final verdict: the first `:fail` wins, else the first `:warn`, else `:pass`.

### Rendering

Summary line + a `REACHABLE` / `BLOCKED` / `UNKNOWN` chip, then the stages as a vertical list:
verdict chip, stage name, one sentence, deciding line in `<code>`. Bulma tags and
`.box.naaf-warn` / `.box.naaf-alert`. The panel must print the caveat:

> This reads the database, not the kernel. It cannot see the remote end of a site, the base
> firewall as loaded, or a peer that is not handshaking. Use ping and traceroute above for what
> the kernel actually does.

### Page shell

- `GET /troubleshoot` → the page.
- `GET /troubleshoot/flow?src=&dst=&proto=&dport=` → the flow report. **GET, not POST**: it is a
  pure read, so the result is bookmarkable and no CSRF token is involved.
  *(Adopted from `grok.md`.)*
- `views/layouts/app.erb` gains a **Troubleshoot** nav item.

The form carries `method="get" action="/troubleshoot/flow"` **and** `hx-get`, so it works without
JavaScript and swaps in place with it — the same degradation contract the dashboard has with SSE.
The route returns the bare fragment when `r.env["HTTP_HX_REQUEST"]` is set and the whole page
otherwise. `hx-disabled-elt="find button"` prevents a double submit (htmx 2.0.10 supports it).

### `test/flow_test.rb` (new)

The highest-value test in the batch, and cheap because `analyze` is pure. One fixture topology —
two clients, one enabled site with a LAN, one disabled site, one port forward, one exposed range,
one global extra route — through a case table: every pair above, disabled client, disabled site,
site with no networks, port just outside an exposed range, port just inside it, ICMP,
`vpn_unassigned`, extra-route-only destination, an address covered by both an extra route and a
site network (classified `:site`, the more specific role), and `src == server_ip`.

App test: `GET /troubleshoot/flow` with params renders the expected verdict text; `GET
/troubleshoot` 401s without a session.

**Commit:** `feat: add a troubleshoot page with a flow tester`

---

# Stage 6 — F5.1–F5.3: ping, traceroute, curl

### `lib/naaf/diagnostics.rb` (new)

```ruby
Result = Data.define(:argv, :output, :status, :seconds, :timed_out, :unavailable)

# Absolute paths, resolved from a candidate list at call time. Never PATH: the
# process inherits systemd's, and an absolute path cannot be shadowed. Debian has
# moved these between /bin and /usr/bin across releases.
BINARIES = {
  ping:       %w[/usr/bin/ping /bin/ping],
  traceroute: %w[/usr/bin/traceroute /usr/sbin/traceroute],
  curl:       %w[/usr/bin/curl /bin/curl]
}.freeze

MAX_OUTPUT = 64 * 1024
# Two at a time, process-wide. A stuck browser tab retrying a request must not be
# able to fork a box that also routes everyone's traffic.
GATE = Async::Semaphore.new(Config.int("NAAF_DIAG_CONCURRENCY"))

# -w is a deadline, not a timeout: ping exits at 8s even with a reply outstanding.
# The async kill at NAAF_DIAG_TIMEOUT is the backstop, not the mechanism.
def self.ping_argv(host)       = ["-n", "-c", "3", "-W", "2", "-w", "8", host]
# -q 1 so a 12-hop trace cannot 3x-probe its way past the deadline.
def self.traceroute_argv(host) = ["-n", "-q", "1", "-m", "12", "-w", "1", host]
def self.curl_argv(url, scheme:, insecure:)
  proto = (scheme == "tcp") ? "=telnet" : "=http,https"
  a = ["-sS", "-v", "-o", "/dev/null", "--proto", proto,
       "--connect-timeout", "4", "--max-time", "8", "--no-progress-meter"]
  a << "-k" if insecure && scheme == "https"
  a << url
end
```

**Three curl modes**, because "can I reach this ip/port at all" is the question an operator
actually has: `tcp` composes `telnet://HOST:PORT` (a bare TCP connect), `http` composes
`http://HOST:PORT/`, `https` composes `https://HOST:PORT/`. *(The `tcp` mode is adopted from
`grok.md`; the link-local refusal and `--proto` pinning are from `FEATURES-F1-F7.md`.)*
The URL is **always assembled server-side from the validated parts** — never accept a free-form
URL string, because the parts are what were checked.

### The runner

Falcon, Roda and async-dns share **one reactor in one process**. A blocking ten-second read would
freeze the admin UI, the resolver and the reconciler together, so every wait is a fiber wait:

`Process.spawn(*argv, in: :close, out: w, err: [:child, :out], pgroup: true)`, close the parent's
write end (or EOF never arrives), then `r.readpartial` in a loop — which yields through the
scheduler's `io_read` hook — the whole thing wrapped in
`Fiber.scheduler.with_timeout(Config.int("NAAF_DIAG_TIMEOUT"))` and held inside `GATE.acquire`.

```ruby
ensure
  # Negative pid = the whole process group. TERM then KILL: traceroute prints a
  # partial trace on TERM, which is worth having.
  begin
    Process.kill("-TERM", pid)
    Fiber.scheduler&.kernel_sleep(0.2)
    Process.kill("-KILL", pid)
  rescue Errno::ESRCH
  end
  status = Process.wait2(pid)&.last   # always reaped — no zombies
  r.close
end
```

Partial output is rendered on timeout with a "stopped after Ns" chip. Output is scrubbed to
UTF-8 (`curl -v` echoes remote banner bytes), truncated at `MAX_OUTPUT` with an explicit marker,
and rendered inside `<pre>` through Roda's `h()` — it is remote text reaching the admin's browser.
A missing binary returns `unavailable: true` and renders as *"traceroute is not installed on this
box — re-run `./deploy.sh`"*, never a 500.

### Input validation

Same doctrine as `ConfigBuilder`'s `WS_SAFE_*` classes: anchored whitelists, and the *first*
character matters as much as the rest.

| Field | Rule | Stops |
|-------|------|-------|
| Host | `param_ipv4` or `HOSTNAME` | both start `[a-z0-9]`, so a host of `-o/tmp/x` can never become an argv flag |
| Scheme | `%w[tcp http https]` | `file://`, `dict://`, `gopher://` — belt and braces with `--proto` |
| Port | `param_port` | reused as-is |
| Path | `\A/[A-Za-z0-9._~\-/%?&=:@+]{0,512}\z` | must start `/`; no spaces, control characters or leading dash |
| curl target | refuse `169.254.0.0/16` via `IPAM.parse_v4` | cloud metadata credential leak. Ping and traceroute still allow it |

### Routes, config, provisioning

- `POST /troubleshoot/{ping,traceroute,curl}` — same fragment-or-page shape as stage 5, but
  **POST**, because these have a side effect on the network and must not be re-run by a bookmark
  or a prefetch. CSRF is already automatic (`check_csrf! unless r.get?`) and htmx serializes the
  `csrf_tag` hidden field with the form.
- All three 404 when `NAAF_DIAG_ENABLED=0`; the three panels and their nav affordance hide; the
  flow tester stays available.
- `lib/naaf/config.rb` + `naaf.conf.example`: `NAAF_DIAG_ENABLED=1`, `NAAF_DIAG_TIMEOUT=10`,
  `NAAF_DIAG_CONCURRENCY=2`.
- `vendor/naaf.css`: ~3 lines for a `.naaf-busy` indicator hidden unless `.htmx-request`, plus a
  wrap/scroll rule for `pre.naaf-log`. **No new vendored script** — `bin/ci` checks `vendor/*.js`
  as an exact set (`bin/ci:86`) and greps every `<script` in `views/` against a two-tag allowlist
  (`bin/ci:117`).
- `deploy/provision/10-packages.sh`: add `iputils-ping` and `traceroute` to the existing
  `apt-get install` list (`curl` is already there).
- `deploy/verify.sh`: one row asserting both binaries exist and `getcap /usr/bin/ping` is
  non-empty — otherwise the failure surfaces as an opaque exit code inside a web page.

### `test/diagnostics_test.rb` (new)

argv construction per tool and per curl scheme (pure); URL composition (assert
`telnet://10.8.0.2:443`, not a user-supplied string); the timeout path against `/bin/sleep 30`
under `Sus::Fixtures::Async::ReactorContext`, asserting it returns inside the deadline, reports
`timed_out`, and leaves no child; output truncation at `MAX_OUTPUT`; a missing binary returns
`unavailable` rather than raising; the semaphore bound holds under three concurrent calls.

`test/app_test.rb` — 401 without a session; CSRF rejected on POST; an invalid host flashes and
never spawns (assert against a stubbed `Diagnostics`); a 404 for all three when
`NAAF_DIAG_ENABLED=0`; GET `/troubleshoot` contains all four headings.

**Commit:** `feat: run ping, traceroute and curl from the admin UI`

---

# Stage 7 — docs

- **`AGENTS.md`**, under "Architecture conventions":

  > "no `wg`/`nft`/`system` on the web or DNS path"

  becomes: no **privileged** command on the web or DNS path. The three diagnostics binaries are
  the one exception — unprivileged, absolute-path, argv-array, semaphore-bounded, hard-killed,
  and disableable with `NAAF_DIAG_ENABLED=0`. **Adding a fourth is an "Ask first".** The helper
  vocabulary is unchanged at four commands; say so explicitly so the next reader does not
  conclude the boundary moved.
- **`AGENTS.md`**, under the DNS notes: `Zone` now carries the forwarder map, rebuilt only in
  `reload!` by whole-hash swap, for the same fiber-safety reason `DNSStats` rotates by swap.
  Note the async-dns upstream timeout and why `DNSServer` wraps `passthrough!`.
- **`AGENTS.md`**, reinforce the existing `NEVER add a metrics table` line with *why*
  per-destination bytes are absent from top talkers (root-only conntrack; `nft` counters reset
  on every apply), so the next person does not re-derive it.
- **`README.md`** — the "What the admin UI manages" DNS row: static A records **and** per-domain
  upstreams. Add Troubleshoot to the page list. Dashboard row mentions peers (clients + sites)
  and top talkers.
- **`docs/TROUBLESHOOTING.md`** — §1b gains a step: a site DNS forwarder that times out is the
  same reachability problem as steps 2–4, not a DNS problem. A short "split DNS" note:
  `dig @10.8.0.1 foo.roomkoetje.be` should come back from the site resolver. At the top: "from
  the UI, start at Troubleshoot".
- **`SECURITY.md`** — no helper change to record. Add the diagnostics surface: which binaries,
  which user, the validation classes, the timeout and concurrency bounds, and the kill switch.

**Commit:** `docs: record the diagnostics exception and split DNS`

---

## Verification

`bin/ci` after every behaviour, and `bundle exec standardrb --fix` before declaring any stage
done. Beyond that, on a live box:

| Stage | Check |
|-------|-------|
| 1–2 | Page render only. |
| 3 | A site row's counters move under real site traffic; the hero tile's total equals clients + sites; the talkers share bar sums to ~100%. |
| 4 | `dig @10.8.0.1 host.example.com` from a client; confirm the answer came from the forwarder. Point a rule at an unroutable address — ServFail must land within `NAAF_DNS_UPSTREAM_TIMEOUT` instead of hanging, and `ss -uap` must show no accumulating sockets after ~100 such queries. Confirm `.vpn` names still resolve locally, and that AAAA for an internal name is still an empty NOERROR. |
| 5 | Take a case the tester calls BLOCKED, confirm with a real connection attempt, add the exposed port, confirm both flip together. That is the tester's only real acceptance criterion. |
| 6 | Fire all three tools **while a continuous ping runs between two spokes** — not one dropped packet, and the dashboard SSE stream must not stall. That is the reactor-blocking test. Confirm a killed run leaves no zombie (`ps --ppid $(pidof -s ruby)`). |

Standing checks from AGENTS.md that this branch must not disturb:

- `ss -ltnp | grep ':8080'` is exactly two rows — the WireGuard IP and `127.0.0.1`.
- `sudo nft list table inet naaf` and `ip -4 route show proto 158` unchanged throughout — no
  stage changes renderer output.
- `nft list tables` shows only `inet filter` and `inet naaf`.
- `.schema clients` still has no private-key column; no `PrivateKey` in logs.
- `sudo wg show wg0` shows no dropped sessions across the `apply!` that stage 4's DNS writes
  trigger (`syncconf`, never `wg-quick down/up`).

---

## Out of scope / deferred

- **Per-IP top talkers via conntrack.** Deliberately not built (decision 2). If it is ever
  wanted, the shape is: a new **root helper command** `conntrack` reading `/proc/net/nf_conntrack`
  under a byte cap and returning raw text (do **not** extend `dump` — that parser must stay the
  only reader of `wg show dump`, whose first field is the server private key); a
  `net.netfilter.nf_conntrack_acct = 1` line in `deploy/sysctl-99-naaf.conf`, without which
  entries carry no `bytes=` and the panel must show an em dash, never `0 B`; parsing and
  aggregation in the **reconciler fiber**, down to a frozen top-N before publish, so raw text
  never reaches a view or an SSE frame; and a `Metrics::TalkerStats` sink mirroring `PeerStats`.
  Note the semantic catch that makes it less attractive than it looks: conntrack holds **live
  flows**, so its byte counts vanish when a connection closes — the panel would measure something
  materially different from "top talkers since the tunnel came up". Both the helper command and
  the sysctl are separate "Ask first" items.
- **True per-destination byte accounting** via `nft` counters — needs `CAP_NET_ADMIN` and would
  reset on every `apply`.
- **`Renderers::SVG.chain` for the flow tester** — a clean follow-up if the step list proves too
  dense.
- **Per-client DNS overrides.** Only per-domain and per-site-domain forwarding is in scope.
- **IPv6 anywhere**: the tunnel interior, site routing, DNS forwarding and these tools stay IPv4,
  consistent with the rest of the app.
- **No download route for diagnostic output.** Copy-paste from the `<pre>` is the supported path.

## Commits

`<type>: <imperative ~60 chars>`, no `Co-authored-by` trailer. One commit per stage, each
`bin/ci`-green on its own, all on `feat/f1-f7`.
