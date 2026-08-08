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

## Quick start

```bash
cp naaf.conf.example naaf.conf     # the one file you edit
$EDITOR naaf.conf                  # set NAAF_SSH_HOST
./deploy.sh                        # a few minutes later you have a VPN
```

Any Debian 13 host you can reach as root over SSH. No box yet? Set
`NAAF_PROVIDER` and run `./deploy.sh --create` to create one first.

See [Deploying](#deploying) below and **`deploy/DEPLOY.md`** for the detail,
**`docs/TROUBLESHOOTING.md`** for operations and gotchas, **`AGENTS.md`** for the
working conventions and boundaries, and **`CONTRIBUTING.md`** if you want to
change something.

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
naaf.conf.example       the one config file — every key, documented
bin/naaf                single-reactor entrypoint (web + dns + reconcile + backups)
bin/naaf-helper         privileged root helper (separate systemd unit)
bin/bootstrap.rb        one-time: server keys + admin pw + endpoint; --refresh-network
bin/ci                  standardrb + sus + config lint + nft render check
lib/naaf/               app, config, backup, renderers (pure), reconciler, zone,
                        ipam, helper client, config_builder, bootstrap
db/schema.rb            idempotent SQLite schema (settings, clients, exposed_ports,
                        port_forwards, dns_records, extra_routes), run on boot
views/                  ERB templates (Bulma markup; plain form POST + redirect)
vendor/                 bulma.min.css, htmx.min.js (served by Roda :public)
test/                   sus tests (renderers, ipam, reconciler, zone, app, config,
                        backup, bootstrap)
deploy.sh               the one deploy command (create, provision, update, verify)
deploy/                 host artifacts (systemd, nftables template, sysctl, tmpfiles)
deploy/provision/       idempotent provisioning steps (05-swap … 50-bringup)
deploy/verify.sh        post-deploy assertions, run on the box
deploy/providers/       optional per-provider box creation and DNS (vultr, dnsimple)
deploy/DEPLOY.md        the deploy runbook
docs/BACKUP.md          snapshots, Litestream, restore, box migration
docs/TROUBLESHOOTING.md operations, the WireGuard-not-connecting playbook, gotchas
```

## Development (macOS or Linux dev box)

Requires **Ruby 4.0.6** and Bundler. `rv ruby install` is the quickest way to
get it (`brew install rv`, or see https://rv.dev); anything that puts 4.0.6 on
your `PATH` works.

```bash
bundle install
cp naaf.conf.example naaf.conf && chmod 600 naaf.conf
ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'   # paste into NAAF_SESSION_SECRET

bundle exec sus            # tests
bundle exec standardrb     # lint (or --fix)
bin/ci                     # full gate: standardrb + sus + config lint + nft render check
```

The renderers, IPAM, Zone, ConfigBuilder, backup and bootstrap helpers are
pure/DB-only and are tested directly, without root or a live kernel. Running the
full server (`bin/naaf`) binds the WireGuard IP and port 53, so it is exercised
on the target host, not the dev box.

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
## Deploying

Deploys to **any Debian 13 (trixie) host you can reach as root over SSH** — there is
no provider API in the deployment path, no metadata endpoint, and no assumption
about the WAN interface name. One command does all of it:

```bash
./deploy.sh                 # provision NAAF_SSH_HOST end to end, then verify
./deploy.sh --create        # create the box first (NAAF_PROVIDER), then the above
./deploy.sh --update        # push code + restart; no provisioning
./deploy.sh --verify        # re-run the post-deploy checks
./deploy.sh --step 30-ruby  # re-run one provisioning step
```

It is idempotent — run it again after editing `naaf.conf`, or against a box where
something failed half way, and it picks up where it left off. The admin password
is asked for once, on a first deploy, and never stored in plaintext anywhere.
Ruby is installed by [rv](https://rv.dev) as a pinned, checksum-verified prebuilt
tarball — seconds rather than the 15–30 minute source compile this used to need,
which was most of a first deploy.

`deploy/providers/` holds optional worked examples for creating a box on Vultr
and upserting a record in DNSimple. Neither is required; adding another provider
means one script that prints an IP address.

Full runbook, including what each provisioning step does: **`deploy/DEPLOY.md`**.

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
