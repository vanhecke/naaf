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
- Inspect live: `sudo wg show wg0`, `sudo nft list table inet naaf`
- Deploy: `./deploy.sh` (one command, idempotent); `deploy/DEPLOY.md`
- Troubleshoot a live box: `docs/TROUBLESHOOTING.md`

## Architecture conventions
- The DB is authoritative. NEVER read kernel state to populate the DB —
  the kernel is a projection. Only handshake/traffic stats flow inward.
- All mutations follow: write DB -> Reconciler#apply! -> helper -> kernel.
- Renderers are pure functions of the DB. No side effects in a renderer.
- The helper's command vocabulary is fixed (genkeys/apply/dump/ping). Adding a
  command requires explicit approval — it widens the privilege boundary.
- Never build shell strings. Always argv arrays via IO.popen(array).
- New long-running work is an `Async` task on the existing reactor, not a
  new process and not a Thread.

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
  in `/etc/naaf/litestream.env`.
- The WireGuard server private key lives in the `settings` table. Never log it,
  never render it into a view, never put it in an error message.
- Client keys are generated server-side by the helper, rendered ONCE into the
  download/QR, and never persisted. `clients` has NO private key column. This
  is deliberate and structural. Do not add one, and do not "cache" a private
  key in the DB, a file, or a log line to make re-download work.

## Testing
- Tests in `test/`, sus style. Renderers and IPAM are pure — test them directly.
- Every renderer change needs a test asserting the emitted text.
- `nft -c -f` (check mode) is the real validator for firewall output; use it.

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
- `/goal` to frame -> plan mode -> `/plan` -> approve -> implement.
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
- Schema changes; changing the wg subnet (it invalidates every client config).
- Touching the server private key handling.
- Adding a gem.

### Never
- NEVER run the web app as root or grant it CAP_NET_ADMIN.
- NEVER use `wg-quick down/up` to apply a peer change — it drops every session.
- NEVER write nftables rules outside table `inet naaf`, and never modify
  /etc/nftables.conf from APPLICATION code. That file is what keeps SSH alive.
  Deliberate, reviewed exception: `deploy/provision/20-system.sh` renders it once
  at provisioning time from `deploy/nftables.conf.template`, substituting
  `NAAF_LISTEN_PORT` and `NAAF_WG_INTERFACE`, and runs `nft -c -f` on the
  RENDERED file before installing it. That is provisioning, not the app, and it
  is what makes naaf.conf the single authority for the WireGuard port instead of
  it being written down in four places. Do not "fix" this back to a static file.
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
  to the object store.
- NEVER read `wg show dump` anywhere but `Reconciler#poll!`. Line 1 field 0 of
  that output is the server private key and every peer line's field 1 is that
  peer's PSK, so a second parser feeding anything the browser renders puts both
  one bug away from the page. Peer telemetry reaches the dashboard through
  `Metrics::PeerStats`, published by that one reader.
- NEVER let a mutable object cross the metrics publish boundary. async-dns runs
  a fiber per datagram; if a render iterated a live counter hash and yielded on
  a socket write, a DNS fiber adding a key would raise inside the DNS fiber and
  `DNSServer#process` would turn it into a ServFail. Counters rotate by
  whole-object swap and snapshots are published frozen.
- NEVER leave `ufw` (or any second firewall on the input/forward hooks) enabled on a
  host — it silently drops WireGuard, tunnel DNS, and forwarding. `nft list tables`
  must show only `inet filter` and `inet naaf`.
