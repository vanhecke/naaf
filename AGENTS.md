# Project: Naaf — WireGuard control plane

## Stack
- Debian 13 (trixie), Ruby 4.0.6, YJIT on in production via RUBY_YJIT_ENABLE
- Falcon + Roda + async-dns, ALL on one shared Async reactor, one process
- Web binds 10.8.0.1:8080 AND 127.0.0.1:8080. Never 0.0.0.0.
- Sequel + SQLite at /var/lib/naaf/naaf.db — the single source of truth
- nftables table `inet naaf` (app-owned) + /etc/nftables.conf (static, off-limits)
- Root helper daemon on /run/naaf/helper.sock — the ONLY privileged code
- ERB + vendored Bulma + vendored htmx. NO Node, NO npm, NO asset pipeline
- Standard (standardrb) for style; sus + sus-fixtures-async for tests

## Commands
- Dev run: `bundle exec ruby bin/naaf`
- Tests: `bundle exec sus`
- Lint/format: `bundle exec standardrb --fix`
- Full gate: `bin/ci`
- Apply state by hand: POST /apply, or `Reconciler#apply!` in a console
- Inspect live: `sudo wg show wg0`, `sudo nft list table inet naaf`, `ip -4 route show proto 158`
- Deploy: `./deploy.sh` (one command, idempotent); `deploy/DEPLOY.md`
- Troubleshoot a live box: `docs/TROUBLESHOOTING.md`

## Architecture conventions
- The DB is authoritative. NEVER read kernel state to populate the DB —
  the kernel is a projection. Only handshake/traffic stats flow inward.
- All mutations follow: write DB -> Reconciler#apply! -> helper -> kernel.
- Renderers are pure functions of the DB. No side effects in a renderer.
  There are four: WireGuard, nftables, Routes, and ConfigBuilder.
- `ConfigBuilder` is a renderer that also VALIDATES before it composes. Every
  value reaching a wg-quick hook runs as ROOT on a client's machine, so each one
  goes through an anchored whitelist (a leading `-` is an argv flag, a leading
  `~` tilde-expands, `[` globs) — never escaping, never a bare character class.
  Every resolved `AllowedIPs` route is audited against the endpoint address.
  Site CIDRs are folded into client AllowedIPs the same way `extra_routes` is,
  and `audit_transport_capture` still applies.
  A refusal is an `ArgumentError` → 500, never a config that silently cannot work.
- The helper's command vocabulary is fixed (genkeys/apply/dump/ping). Adding a
  command requires explicit approval — it widens the privilege boundary.
  `apply` projects three things from the DB: the WireGuard conf (`wg syncconf`),
  the entire `inet naaf` table (`nft -f`), and site extras (`ip route` proto 158
  + extra `/32`s on wg0). Widening what apply writes to the kernel is the same
  "Ask first" as a new command. Extra apply fields are optional so an older
  helper still answers; a box whose helper predates a new side effect will
  silently skip it.
- Never build shell strings. Always argv arrays via IO.popen(array).
- New long-running work is an `Async` task on the existing reactor, not a
  new process and not a Thread. Privileged work stays in the helper — no
  **privileged** command on the web or DNS path, and never a shell string.
  `HelperClient#call` opens a fresh socket under a mutex; a slow helper call
  runs on the calling fiber.
- The ONE exception is `lib/naaf/diagnostics.rb`: `ping`, `traceroute` and
  `curl`, spawned by the web process for the Troubleshoot page. They are
  unprivileged (Debian ships `ping` with `cap_net_raw+ep`, traceroute's default
  UDP mode needs no privilege, curl needs none), reached by ABSOLUTE path from a
  candidate list rather than through `PATH`, invoked as an argv array, bounded
  by `Async::Semaphore`, hard-killed on `NAAF_DIAG_TIMEOUT` (TERM to the process
  group, then KILL, then always reaped), and removable with
  `NAAF_DIAG_ENABLED=0`. Putting them behind the helper socket would be strictly
  worse — it would widen a four-command root vocabulary to gain nothing. **The
  helper's vocabulary is UNCHANGED at genkeys/apply/dump/ping; the privilege
  boundary has not moved.** A FOURTH binary here is an "Ask first".
- Every wait in that runner is a fiber wait — `readpartial` through the
  scheduler's IO hook, `wait2` through `process_wait`. A blocking ten-second
  read would freeze the admin UI, the resolver and the reconciler together.
- Reconcile and backup loops must rescue and continue (`Reconciler.tick!`,
  `Backup.tick!`). A raised task must not tear down the reactor. `Zone#reload!`
  swaps whole hashes.
- `Reconciler#failed!` stores the exception **class only**, never the message.
  The helper interpolates child stderr into the raise, and `wg-quick strip` /
  `wg syncconf` echo key material verbatim. That field is rendered in the admin
  UI and pushed on every SSE stream.
- Intra-VPN policy is the `inet naaf` forward chain, not `AllowedIPs`.
  Spoke↔spoke is default-deny; `exposed_ports` go through the `daddr . dport`
  sets; site LANs go through `site_nets`. `AllowedIPs` is a client-side hint.
- Port forwards DNAT on the WAN iface and need
  `oifname <wg> ct status dnat masquerade` (hairpin). Disabled forwards must
  not appear. `ip saddr <wg_subnet> oifname <wan> masquerade` stays for
  full-tunnel egress.
- IPAM never hands out the network, broadcast, or server address, and reuses
  freed ones. Enabled clients, and sites that have networks, are kernel peers;
  disabled ones are absent.

## DNS
- `Zone` holds the A/PTR hashes AND the conditional-forwarding map, all rebuilt
  only in `reload!` and installed by whole-object swap — the same fiber-safety
  reason `DNSStats` rotates by swap. `reload!` is reached only through
  `Reconciler#apply!`; do NOT add a second invalidation seam.
- Forwarding is dnsmasq-style suffix match, longest wins, and the local zone
  always runs first, so a `.vpn` name is never forwarded. A DISABLED site
  contributes no rule: it is not a kernel peer and its route is not installed,
  so keeping the rule would turn an ordinary upstream answer into a hang.
- async-dns 1.4.1 has NO timeout anywhere on the upstream path —
  `try_datagram_server` does a bare `recvfrom` and `Resolver#query` adds no
  deadline of its own. An unreachable upstream parks the query fiber and its
  UDP socket forever. `DNSServer` wraps `passthrough!` in
  `Fiber.scheduler#with_timeout(NAAF_DNS_UPSTREAM_TIMEOUT)` for exactly that
  reason, and `Async::TimeoutError` must be rescued ABOVE the method's bare
  `rescue => e` so a slow resolver is filed as `upstream_fail` and not as a bug
  in this process. Do not remove that wrapper because "one upstream has always
  worked" — one site with a down tunnel makes it routine.
- A site's resolver must sit inside one of THAT site's own `site_networks`.
  Those are the only CIDRs `Renderers::Routes.desired` installs a proto-158
  route for, so anything else is configured-but-unreachable, and the symptom is
  an unexplained timeout rather than a refusal.

## Sites
- A site is a remote WireGuard *server* this hub dials, not a client: no IPAM
  address on `wg_subnet`. The remote's pubkey is the peer; Naaf presents
  `settings.server_pubkey` on the other side. `docs/TROUBLESHOOTING.md` §1b.
- `Renderers::Routes` emits the desired extra `/32`s and dests on wg0. Apply
  tags those dests **proto 158** so it can diff them without touching the
  kernel connected route or anything the operator added by hand.
- The helper refuses a `/0` and any dest or address that covers the default
  gateway or a non-wg local IPv4 (would steal SSH / WAN). That check is in the
  root process on purpose; the form must refuse too, but the helper is the last
  line.
- `site_nets` in `inet naaf` must accept before the spoke↔spoke `counter drop`.
  Optional per-site SNAT/masquerade is for remotes that will not put
  `wg_subnet` in AllowedIPs.
- A site with no networks is not a kernel peer (WireGuard refuses empty
  AllowedIPs). `poll!` must not count it as drift.

## Frontend
- htmx AND its official SSE extension (`vendor/htmx-ext-sse.min.js`, 0BSD) are
  the only client-side JavaScript. There is no application .js file and there
  must not be one. No inline <script>. No Alpine/Stimulus/React. A THIRD
  vendored script is an "Ask first".
- Interactivity is server-rendered fragments swapped via hx-* attributes.
  If something seems to need scripting, move the behaviour to the server.
- Bulma is class-based: table.is-fullwidth, .field/.control, .button.is-danger,
  .notification. Bulma ships no JS — do not add its optional JS snippets.
- Everything static is vendored in `vendor/` and served by Roda's `:public`
  plugin: bulma.min.css, htmx.min.js, htmx-ext-sse.min.js, and naaf.css (ours —
  it exists only to colour the inline SVG charts for light and dark). No CDN at
  runtime. `bin/ci` pins both scripts by sha384.
- The dashboard at `/` pushes fragments over ONE SSE stream (`GET /events`).
  Every fragment is also a plain `GET /metrics/<name>`, so the page degrades to
  `hx-trigger="every Ns"` polling with `NAAF_METRICS_SSE=0` and every panel is
  testable without a reactor. The `hx-ext`/`sse-connect` wrapper must stay
  OUTSIDE every swap target — if htmx re-processes it, a second EventSource
  opens and the first leaks. Never put `sse-swap` and `hx-trigger` on the same
  element; they are two writers racing on one target.
- The SSE route is a Rack 3 **callable** body (`throw :halt,
  response.finish_with_body(proc { |stream| ... })`), never Roda's `:streaming`
  plugin: an each-able body runs in an Enumerator fiber where the reactor cannot
  reach it, a disconnect raises nothing, and the `ensure` never runs. Never set
  Content-Length on it.

## Style
- standardrb is the single authority. No .rubocop.yml, no arguing with it.
- Run `bundle exec standardrb --fix` before declaring a task done.

## Secrets / env
- ONE config file: `naaf.conf` (template `naaf.conf.example`, gitignored),
  installed to `/etc/naaf/naaf.conf` mode 0640 root:naaf. Plain `KEY=value` — the
  grammar is the intersection of systemd `EnvironmentFile=`, `set -a; . file`,
  and `lib/naaf/config.rb`, so no `export` and no `$VAR`. `bin/ci` enforces it.
- `lib/naaf/config.rb` is the single source of every default and MUST stay
  require-free: `bin/naaf-helper` loads it as root via `require_relative`.
- The config file only SEEDS the `settings` table on first boot. After that the
  DB is authoritative; `Config.drift` warns at boot when the two disagree.
- Object-store credentials never go in `naaf.conf` — it is `EnvironmentFile=` for
  the web app, so everything in it lands in that process's environment. They go
  in `/etc/naaf/litestream.env`. The ACME DNS token is the same story with a
  tighter mode: `/etc/naaf/acme.env`, 0600 root:root, because acme.sh runs as
  root and `/etc/naaf` is traversable by the `naaf` group. Both reach the box
  through `deploy.sh`'s secret channel, never through a config key.
- The wstunnel and certificate knobs (`NAAF_WSTUNNEL_*`, `NAAF_CERT_*`,
  `NAAF_ACME_*`) live in `naaf.conf` and NEVER in the `settings` table. The port
  and the cert paths must match the systemd unit AND the base firewall, both
  rendered from `naaf.conf` at provisioning time; a DB copy would be a second
  source of truth that drifts. The *host* clients dial stays in `settings`
  (`endpoint_host`). Two values are in neither: `NAAF_WSTUNNEL_PATH_PREFIX` lives
  in `/etc/naaf/wstunnel.env` (0640 root:naaf, generated by `65-wstunnel.sh` and
  read back via `EnvironmentFile=-`) because `install-config.sh` iterates the
  INCOMING file only and would drop then regenerate it — silently invalidating
  every ws config ever issued; and the ACME token, above.
- The WireGuard server private key lives in the `settings` table. Never log it,
  never render it into a view, never put it in an error message.
- Client keys are generated server-side by the helper, rendered ONCE into the
  download/QR, and never persisted. `clients` has NO private key column. This
  is deliberate and structural. Do not add one, and do not "cache" a private
  key in the DB, a file, or a log line to make re-download work.
- The one-shot key is spent through `with_oneshot_privkey(id)` and NOTHING else:
  peek, build the whole response inside the block, delete only on success. There
  is deliberately no bare `take_`. `ConfigBuilder#render` raises for a whole class
  of misconfigurations no route-level guard can see, and a take-then-raise destroys
  the only copy of a key nothing persists — the recovery is deleting and re-adding
  the client. The QR route peeks and never consumes.

## Testing
- Tests in `test/`, sus style. Renderers and IPAM are pure — test them directly.
- Every renderer change needs a test asserting the emitted text.
- `nft -c -f` (check mode) is the real validator for firewall output; use it.

## Verification
- Always: `bin/ci` (standardrb, sus, shellcheck, conf grammar, require-free
  `config.rb`, vendored script digests, `nft -c -f` including a non-empty
  `site_nets`).
- Apply-path or firewall change: `sudo nft list table inet naaf`,
  `sudo wg show wg0`, `ip -4 route show proto 158`, and a continuous ping
  between two spokes across `apply!`. A dropped packet means something used
  `wg-quick down/up` instead of `wg syncconf`.
- Client or key handling: `.schema clients` has no priv column; no
  `PrivateKey` in logs.
- Bind check: `ss -ltnp | grep ':8080'` is exactly two rows — the wg IP and
  `127.0.0.1`, never `0.0.0.0`/`::`. DNS is on the wg IP, not `0.0.0.0`.

## Backups
- Snapshots are `VACUUM INTO` on the app's own connection, written to a `.tmp`
  name then renamed, `chmod 0600` (they contain `server_privkey`).
- NEVER bare `VACUUM`, NEVER `PRAGMA wal_checkpoint`, NEVER `cp` the live `.db`:
  the first invalidates Litestream's tracking, the second fights it for
  checkpoint ownership, the third is a torn read without the `-wal`.
- `journal_mode = WAL` and `busy_timeout = 5000` in `lib/naaf/db.rb` are
  load-bearing for Litestream. Do not "tidy" them.
- No download route for a snapshot, ever. It would serve the server private key
  over HTTP. `scp` is the supported way to fetch one.
- Full detail and the restore/migration recipes: `docs/BACKUP.md`.

## Deployment & operations
- Target: ANY Debian 13 host reachable as root over SSH. There is no provider API
  in the deploy path, and the WAN interface is discovered at bootstrap from
  `ip -o -4 route show to default` — never hardcode `eth0`/`ens3`. `deploy/providers/`
  is optional worked examples, not the supported path.
- There is exactly ONE deploy action: `./deploy.sh`. It syncs, runs every
  idempotent `deploy/provision/*.sh` step via `provision.sh`, and verifies.
  `--create`/`--update`/`--verify`/`--step`/`--ssh` are the same script, not a
  second path. Do not add a parallel deploy mechanism (cloud-init user-data, a
  second runner script, a Makefile target that reimplements it) — one path is
  what keeps hand-run and automated from drifting. Ruby is installed by `rv` as a
  pinned, checksum-verified prebuilt tarball — never compiled from source, and
  never via `curl | sh`. `NAAF_RUBY_VERSION` must be a version rv publishes;
  provisioning fails loudly rather than falling back. `bin/bootstrap.rb` reads
  `NAAF_ADMIN_PASSWORD` / `NAAF_ENDPOINT_HOST` from the env for unattended first
  boot, else prompts.
- A provider integration is ONE script printing an IP on stdout
  (`deploy/providers/<name>/create-box.sh`, selected by `NAAF_PROVIDER`). It
  creates a bare box; it must not carry user-data that duplicates provisioning.
- `deploy/*.service` and `deploy/nftables.conf.template` carry `__NAAF_*__`
  placeholders substituted from `naaf.conf` at install time. Never install them
  verbatim, and never reintroduce a hardcoded path or port into them.
- Installing `/etc/nftables.conf` is NOT loading it. Debian's `nftables.service`
  is `Type=oneshot` + `RemainAfterExit=yes`, so `systemctl start` (all `--now`
  does) short-circuits on it forever and `ExecStart` never re-runs. `20-system.sh`
  `cmp`s the rendered file and, only when it changed, runs `systemctl
  reload-or-restart nftables` (that unit's `ExecReload` is the same `nft -f`)
  followed by `systemctl try-restart naaf`. The second half is load-bearing: the
  file opens with `flush ruleset`, which takes table `inet naaf` with it, and
  `Reconciler#poll!` only re-applies on PEER-SET drift — a vanished table is
  something it never looks for. `bin/naaf` applies at startup, so the restart is
  the re-apply.
- The certificate store (`/etc/naaf/certs`) has exactly ONE owner —
  `deploy/provision/60-certs.sh`, the only thing that issues or renews — and any
  number of consumers. A consumer calls `cert_slug` → `cert_dir` → asserts the
  pair exists → `cert_register`, and NEVER `cert_ensure` (that would mint a pair
  for a name nothing renews), never a CA, never a second renewal timer, never an
  inbound port: ACME is DNS-01 only and tcp/80 stays shut. `docs/CERTS.md`.
- Provisioning MUST disable `ufw`. Many Debian cloud images ship it enabled; its
  iptables-nft `ip filter` tables drop udp/51820, tunnel DNS, and forwarding even when
  `ufw status` reads inactive, and re-apply on boot. A healthy `nft list tables` shows
  ONLY `inet filter` + `inet naaf`; an `ip filter` table means ufw is back.
- `endpoint_host` (settings) is the host clients dial; set it to migrate boxes by
  repointing DNS. Written by the Settings UI or `NAAF_ENDPOINT_HOST` at bootstrap.
  Migration = provision a new box, restore the DB BEFORE `50-bringup` (its
  `already_bootstrapped` guard then skips re-keying), `bin/bootstrap.rb
  --refresh-network`, repoint DNS. `docs/BACKUP.md`.
- When a client can't connect / DNS times out / full-tunnel is dead, follow the
  playbook in `docs/TROUBLESHOOTING.md`. Key move: `tcpdump` on the WAN NIC captures
  before netfilter, so check `Udp: InDatagrams` in `/proc/net/snmp` — flat while
  packets arrive means a firewall table is silently dropping them.

## Workflow
- Branch per change: `git checkout -b feat/<thing>`.
- For anything that is not a one-line fix, use the harness plan mode. The plan
  names files to change, data-model impact, the apply path
  (DB write → `Reconciler#apply!` → helper → kernel), the tests, and the
  privilege check. Wait for approval before implementing. Do not invent
  project slash commands or named agents for this — the built-in plan mode
  is the loop.
- After each behavior: run its test. Then `bin/ci`.
- Commits: `<type>: <imperative ~60 chars>`. No Co-authored-by trailer.

## Boundaries (three tiers)

### Always
- Apply peer changes with `wg syncconf`. It computes the delta and leaves
  existing peer sessions untouched.
- Regenerate the ENTIRE `inet naaf` table from the DB and apply it in one
  `nft -f` transaction. Check with `nft -c -f` first.
- Keep the admin UI bound to the WireGuard IP and 127.0.0.1, and nothing else.
- Run `standardrb --fix` and `bin/ci` before finishing.

### Ask first
- Any change to the helper's command vocabulary or its privileges.
- Widening what `apply` writes to the kernel (new `ip` / `nft` / `wg` side
  effects, even if the command name stays `apply`).
- Schema changes; changing the wg subnet (it invalidates every client config).
- Touching the server private key handling.
- Adding a gem.

### Never
- NEVER run the web app as root or grant it CAP_NET_ADMIN.
- NEVER use `wg-quick down/up` to apply a peer change — it drops every session.
- NEVER write nftables rules outside table `inet naaf`, and never modify
  /etc/nftables.conf from APPLICATION code. That file is what keeps SSH alive.
  Deliberate, reviewed exception: `deploy/provision/20-system.sh` renders it once
  at provisioning time from `deploy/nftables.conf.template`, substituting THREE
  things — `NAAF_LISTEN_PORT`, `NAAF_WG_INTERFACE`, and `__NAAF_WSTUNNEL_RULE__`,
  which becomes a `tcp dport $NAAF_WSTUNNEL_PORT accept` rule or a comment-only
  line when the transport is disabled — and runs `nft -c -f` on the RENDERED file
  before installing it. That is provisioning, not the app, and it is what makes
  naaf.conf the single authority for the WireGuard port instead of it being
  written down in four places. Do not "fix" this back to a static file. Both
  branches are rendered and checked by `bin/ci`; keep it that way, and use `|` as
  the sed delimiter for the rule (a `#` in the replacement makes sed exit 0 and
  reinterpret the tail as flags — wrong output, every guard still green).
- NEVER let a ws flavor emit an `AllowedIPs` that captures its own transport. A
  `/0`, or any route covering `endpoint_v4`/`endpoint_v6`, routes wstunnel's own
  TCP session into the tunnel it carries: the interface comes up, never
  handshakes, and a `/0` additionally takes the client's own default route with
  it via `suppress_prefixlength 0`. Omitting the full-tunnel-over-ws flavor is
  NOT sufficient — `extra_routes` is folded into `AllowedIPs` verbatim and
  `param_cidr` accepts `0.0.0.0/0`. `audit_transport_capture` is what holds the
  line: it raises for the ws flavors and warns for plain `split`, where a `/0` is
  a working full tunnel today because the kernel WireGuard socket IS fwmark-exempt.
- NEVER put wg-quick's `%i`/`%I` in a ws hook. `%i` is the config name on Linux
  but the `utunN` device on macOS and `%I` exists only on macOS, so the relay's
  pidfile and local port are machine-global constants instead — which means ONE
  ws tunnel per machine. The guard hook refuses a second `wg-quick up` while the
  pidfile names a live wstunnel; without that refusal the second relay died on
  `EADDRINUSE` after overwriting the pidfile, and the first was orphaned past
  every `down`, holding `127.0.0.1:51820` until reboot.
- NEVER accept a port forward on a port the box needs for itself. A DNAT in
  `inet naaf` prerouting runs before the routing decision, so tcp/22,
  udp/`listen_port` or tcp/`NAAF_WSTUNNEL_PORT` hands the box's own traffic to a
  client — SSH, every handshake, or every ws client, with the forward chain's
  `ct status dnat accept` waving it through. `reserved_port_owner` refuses those
  at insert AND on the way ON in the toggle route (a row can predate the check).
  It is protocol-aware on purpose; `NAAF_WEB_PORT` is deliberately not reserved,
  because the admin UI binds only the WireGuard IP and 127.0.0.1.
- NEVER set `policy drop` on a base chain in `inet naaf` — other base chains on
  the same hook would be silently overridden.
- NEVER disable net.ipv4.ip_forward.
- NEVER store or log a client private key.
- NEVER bind the admin UI to 0.0.0.0 or the public interface. Two binds only:
  the WireGuard IP and 127.0.0.1.
- NEVER add Node, npm, or a package.json.
- NEVER add client-side JavaScript beyond the vendored htmx and its official SSE
  extension — no app .js file, no inline <script>, no JS framework. A third
  vendored script is an "Ask first".
- NEVER add a metrics table. Dashboard history lives in in-memory ring buffers
  and resets on restart, deliberately: naaf.db is configuration truth, and a
  high-frequency table in it would multiply the WAL churn Litestream replicates
  to the object store. The same reasoning is why "Top talkers" ranks PEERS and
  not destinations, and says so in its own copy rather than implying it measured
  something it did not: per-flow byte counts need `/proc/net/nf_conntrack`
  (`0440 root:root`) or `nft` counters (`CAP_NET_ADMIN`), an `nft` counter would
  reset on every apply — which deletes and recreates `table inet naaf` — and
  conntrack holds LIVE flows, so its byte counts vanish when a connection
  closes. Both a `conntrack` helper command and a `nf_conntrack_acct` sysctl are
  separate "Ask first" items.
- NEVER read `wg show dump` anywhere but `Reconciler#poll!`. Line 1 field 0 of
  that output is the server private key and every peer line's field 1 is that
  peer's PSK, so a second parser feeding anything the browser renders puts both
  one bug away from the page. Peer telemetry reaches the dashboard through
  `Metrics::PeerStats`, published by that one reader. Never put a helper
  exception message (or any other dump field) into a view or SSE fragment —
  `Reconciler#failed!` keeps the class name only.
- NEVER install a site dest or extra `/32` that covers the default gateway or
  a non-wg local address. The form refuses those; the helper refuses them
  again as root. A `/0` site dest is the same class of bug.
- NEVER let a mutable object cross the metrics publish boundary. async-dns runs
  a fiber per datagram; if a render iterated a live counter hash and yielded on
  a socket write, a DNS fiber adding a key would raise inside the DNS fiber and
  `DNSServer#process` would turn it into a ServFail. Counters rotate by
  whole-object swap and snapshots are published frozen.
- NEVER leave `ufw` (or any second firewall on the input/forward hooks) enabled on a
  host — it silently drops WireGuard, tunnel DNS, and forwarding. `nft list tables`
  must show only `inet filter` and `inet naaf`.
