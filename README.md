# Naaf — a WireGuard control plane in Ruby

A single-admin control plane for a WireGuard hub. It gives you a web UI to manage
clients, intra-VPN port policy, host port-forwards, split-tunnel routes, a private
DNS zone, and server settings. **SQLite is the single source of truth**; the kernel
(WireGuard + nftables) is a *projection* re-rendered from the DB and pushed through
a small root helper.

- **One process, one reactor.** Falcon (web) + async-dns (DNS) + a 30 s reconcile
  loop, all as tasks on one shared Async reactor.
- **One privilege boundary.** A ~120-line root helper on a Unix socket is the only
  privileged code. It speaks a fixed four-command JSON vocabulary
  (`genkeys` / `apply` / `dump` / `ping`) and never builds a shell string.
- **Safe firewall model.** The app owns only nftables table `inet naaf`,
  regenerated wholesale and applied atomically via `nft -f`. The static base
  firewall in `/etc/nftables.conf` is off-limits — that is what keeps SSH alive.
- **Structural key custody.** Client private keys are generated server-side, shown
  **once** in the download/QR, and never stored — `clients` has no private-key column.
- **No Node.** ERB + vendored Bulma + vendored htmx; htmx is the only client-side JS.

See **`deploy/DEPLOY.md`** for deploying to a VPS, **`docs/TROUBLESHOOTING.md`** for
operations and gotchas, **`AGENTS.md`** for the working conventions and boundaries,
and **`CONTRIBUTING.md`** if you want to change something.

## What the admin UI manages

| Page | What it does |
|---|---|
| **Clients** | Add a client (server generates keys, or paste your own pubkey), enable/disable, delete, and download the config in three flavors (`split`, `split·nodns`, `full`) or as a QR. IPAM assigns the next free VPN IP. |
| **Exposed ports** | Which ports a spoke may accept **from other spokes** — a single port or a range like `8000-8100` (default-deny spoke-to-spoke, allow-list via an nftables interval set). |
| **Port forwards** | Inbound DNAT from the public interface to a client's port, with an enable toggle. |
| **Routes** | Extra split-tunnel subnets folded into a client's `AllowedIPs` (global, or per-client). |
| **DNS** | Static `A` records in the internal `.vpn` zone, layered over the automatic per-client `<hostname>.vpn` records. |
| **Settings** | Edit endpoint host/IPs, DNS upstream + internal domain, MTU, WAN interface; change the admin password. Structural values (subnet, gateway, listen port, keys) are read-only. |

## Config flavors

Every client can download three configs (`GET /clients/:id/config/:flavor`):

- **`split`** — routes only the VPN subnet (+ any extra routes), sets `DNS = 10.8.0.1`.
- **`split·nodns`** — same routing, but no `DNS =` line (uses your system DNS).
- **`full`** — routes `0.0.0.0/0` (all traffic through the hub), sets `DNS = 10.8.0.1`.

The `Endpoint` is `settings.endpoint_host:listen_port` when an endpoint host is set
(so migrating boxes is just a DNS repoint), otherwise the raw `endpoint_v4`.

## Layout

```
bin/naaf                single-reactor entrypoint (web + dns + reconcile)
bin/naaf-helper         privileged root helper (separate systemd unit)
bin/bootstrap.rb        one-time: server keys + admin pw + endpoint (env-driven)
bin/ci                  standardrb + sus + nft render check
lib/naaf/               app, renderers (pure), reconciler, zone, ipam, helper client,
                        config_builder, bootstrap (env-var provisioning helpers)
db/schema.rb            idempotent SQLite schema (settings, clients, exposed_ports,
                        port_forwards, dns_records, extra_routes), run on boot
views/                  ERB templates (Bulma markup; plain form POST + redirect)
vendor/                 bulma.min.css, htmx.min.js (served by Roda :public)
test/                   sus tests (renderers, ipam, reconciler, zone, app, bootstrap)
deploy/                 host artifacts (systemd, nftables, sysctl, tmpfiles) + README
deploy/provision/       idempotent server provisioning steps (05-swap … 50-bringup)
deploy/vultr/           create-box.sh, ensure-firewall.sh (run from your workstation)
deploy/dns/             update-record.sh (DNSimple A/AAAA upsert)
deploy/DEPLOY.md        the staged deploy runbook
docs/TROUBLESHOOTING.md operations, the WireGuard-not-connecting playbook, gotchas
```

## Development (macOS or Linux dev box)

Requires **Ruby 4.0.6** (via ruby-install + chruby) and Bundler.

```bash
bundle install
cp naaf.conf.example naaf.conf && chmod 600 naaf.conf
ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'   # paste into NAAF_SESSION_SECRET

bundle exec sus            # tests
bundle exec standardrb     # lint (or --fix)
bin/ci                     # full gate: standardrb + sus + config lint + nft render check
```

## Configuration

One file. `naaf.conf.example` documents every key; copy it to `naaf.conf`, edit,
and deploy installs it to `/etc/naaf/naaf.conf`. It is plain `KEY=value` with no
`export` and no expansion, because it is read three ways: as systemd's
`EnvironmentFile=` for both units, sourced by the provisioning scripts, and
parsed by `lib/naaf/config.rb`, which holds every default in one place.

Values resolve environment → file → default. The keys that mirror a `settings`
column (subnet, ports, DNS, MTU, endpoint host) **seed the database on first boot
only** — after that the database is authoritative and the admin UI edits it, and
Naaf logs a warning at boot if the two have drifted apart.

Two things deliberately never go in the file: the admin password, which is read
once at bootstrap and bcrypt-hashed into the database, and object-store
credentials for Litestream, which would otherwise land in the web application's
environment (see `docs/BACKUP.md`).

The renderers, IPAM, Zone, ConfigBuilder, and bootstrap helpers are pure/DB-only and
are tested directly without root or a live kernel. Running the full server (`bin/naaf`)
binds the WireGuard IP and port 53, so it is exercised on the target host, not the dev box.

## Deploying

Deploys to **any Debian 13 (trixie) host you can reach as root over SSH** — there is
no provider API in the deployment path. Two stages, documented in
**`deploy/DEPLOY.md`**:

- **Stage 1** — rsync the repo to the box, run `deploy/provision/*` steps one-by-one
  over SSH (`deploy/run-remote.sh <ip> step <NN>`) and read each log. De-risks the
  provisioning.
- **Stage 2** — hand the verified steps to cloud-init as a `#!/bin/bash` user-data
  script so a fresh box self-provisions, then point DNS at it.

`deploy/vultr/` and `deploy/dns/` are optional worked examples for creating a box on
Vultr and upserting a record in DNSimple. Neither is required; adding another
provider means one script that prints an IP.

The same idempotent `deploy/provision/*.sh` steps run in both stages, so there is no
drift between "hand-run" and "automated". Ruby 4.0.6 is compiled from source with YJIT
(~15–30 min on 1 vCPU + swap) — the long pole.

**Update flow on a running box:** `git pull` (or rsync) into `/opt/naaf` then
`sudo systemctl restart naaf` (the helper only needs a restart if `bin/naaf-helper` changed).

## Operations

```bash
sudo systemctl status naaf naaf-helper wg-quick@wg0
sudo wg show wg0                       # peers, handshakes, transfer
sudo nft list table inet naaf          # app-owned firewall (NAT + spoke policy)
journalctl -u naaf -f                  # app logs
```

First-run / recovery access before any tunnel exists (admin UI is tunnel-only):

```bash
ssh -L 8080:127.0.0.1:8080 <host>      # then open http://localhost:8080
```

## Backups

The database is the whole system — it holds the server private key, every peer,
and every firewall rule. Two layers, documented in **`docs/BACKUP.md`**:

- **Snapshots**, on by default: an hourly `VACUUM INTO` taken in-process, mode
  0600, newest 24 kept, in `/var/lib/naaf/backups`.
- **Litestream**, off by default: continuous WAL replication to a file path or
  any S3-compatible bucket, for recovery that survives losing the machine.

Because the server private key lives in the database and clients dial
`endpoint_host`, restoring onto a fresh box and repointing DNS moves the whole
service with **zero client reconfiguration**. That is the migration path.

## Troubleshooting

If clients can't connect, DNS times out, or full-tunnel is dead, start with
**`docs/TROUBLESHOOTING.md`** — the most common cause is a second firewall (`ufw`)
on the host; the provisioning disables it, but it is the first thing to check.
