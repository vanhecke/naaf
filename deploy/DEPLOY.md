# Deploying Naaf

```bash
cp naaf.conf.example naaf.conf     # the one file you edit
$EDITOR naaf.conf                  # set NAAF_SSH_HOST
./deploy.sh                        # a few minutes later you have a VPN
```

That is the whole deployment. `./deploy.sh` pushes the code and your config to
the box, runs every provisioning step, and verifies the result. It is idempotent:
run it again after editing `naaf.conf`, or against a box where something failed
half way, and it picks up where it left off.

It works against **any Debian 13 (trixie) host you can reach as root over SSH**.
Nothing in the deployment path calls a provider API, reads a metadata endpoint,
or assumes an interface name.

## No box yet?

```bash
$EDITOR naaf.conf                  # set NAAF_PROVIDER (and optionally NAAF_DNS_PROVIDER)
./deploy.sh --create
```

This creates the box, points DNS at it, and then does exactly the same deploy.
`deploy/providers/` holds worked examples for Vultr and DNSimple; adding another
provider means one script that prints an IP address.

## Prerequisites

**Target box:** Debian 13 (trixie), 1+ vCPU, 1–2 GB RAM, root SSH access.
Debian 12 is untested; rv's prebuilt Ruby needs glibc 2.35+, which trixie has.

**Your machine:** `ssh` and `rsync`. `jq` and a provider CLI only if you use
`--create`.

## What a deploy actually does

| | |
|---|---|
| `--create` only | run `deploy/providers/$NAAF_PROVIDER/create-box.sh`, wait for SSH, upsert DNS |
| first deploy only | ask for the admin password, ship it to a root-only file the box deletes as it reads it |
| always | `rsync` the repo to `/opt/naaf`, install `naaf.conf` to `/etc/naaf/naaf.conf` (0640 root:naaf, workstation-only section stripped) |
| always | run `deploy/provision/provision.sh` — the seven steps below |
| always | run `deploy/verify.sh` and print how to reach the admin UI |

The provisioning steps, in the one order that works:

| step | does |
|---|---|
| `05-swap` | 2 GB swapfile (headroom on a 1–2 GB box) |
| `10-packages` | apt: WireGuard/nftables + a compiler for native gem extensions |
| `20-system` | `naaf` user, dirs, IP-forward sysctl, tmpfiles, SSH hardening, `/etc/nftables.conf` from the template |
| `30-ruby` | `rv` + Ruby with YJIT, prebuilt and checksum-verified (seconds) |
| `40-app` | `/etc/naaf/naaf.conf` with a generated session secret, `bundle install`, both systemd units |
| `45-litestream` | optional off-box replication; a no-op unless `NAAF_LITESTREAM_ENABLED=1` |
| `50-bringup` | helper → `bootstrap.rb` (keys/admin-pw/endpoint host) → app → `wg-quick@wg0` |

Every step is idempotent and logs to `/var/log/naaf-provision/<step>.log` on the
box; the whole run is also tee'd to `deploy/logs/` locally (gitignored).

`50-bringup` generates the server keypair exactly once, guarded on
`settings.server_pubkey` being set. That guard is why re-deploying is safe, why a
re-deploy needs no admin password, and why [restoring a database onto a fresh
box](../docs/BACKUP.md) keeps the original server identity.

## First login

The admin UI binds the WireGuard IP and `127.0.0.1`, never a public address — so
before you have a client, reach it over an SSH forward:

```bash
ssh -L 8080:127.0.0.1:8080 root@<box>     # then open http://localhost:8080
```

`/` is the live dashboard; the client list is one click away at `/clients`. Add a
client there, scan the QR, and you are on the tunnel. After that the UI is at
`http://10.8.0.1:8080` whenever the tunnel is up.

## When something goes wrong

Same script, same config, no new concepts:

```bash
./deploy.sh --verify              # re-run the post-deploy checks
./deploy.sh --step 30-ruby        # re-run one provisioning step
./deploy.sh --ssh -- 'journalctl -u naaf -n 100 --no-pager'
```

Steps are idempotent, so re-running the one that failed is always safe. If a
client can't connect, DNS times out, or full-tunnel is dead, start with
[`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md) — the most common cause
is `ufw`, which provisioning disables but cloud images keep reintroducing.

## Updating a running box

```bash
./deploy.sh --update              # rsync + restart, no provisioning
```

Use a full `./deploy.sh` when the change touches provisioning: a new config key,
a systemd unit, the nftables template, a Ruby version bump.

## Endpoint host, and migrating boxes

`NAAF_ENDPOINT_HOST` is the name baked into every client config. Set it to a name
you control and you can move to a new box by repointing DNS, with no client
reconfiguration. Leave it blank and clients dial the box's public IPv4 directly,
which pins them to that box forever.

The database holds the server private key and every peer, so it *is* the
deployment. Restoring it onto a fresh box and repointing DNS moves the whole
service — see [`docs/BACKUP.md`](../docs/BACKUP.md).

## Provider examples

`deploy/providers/vultr/create-box.sh` creates an instance and prints its IP,
attaching a firewall group that allows only 22/tcp and the WireGuard port.
`deploy/providers/dnsimple/update-record.sh` upserts an A (and optional AAAA)
record. Each needs its own authenticated CLI and takes account-specific values
from `naaf.conf` with no defaults — read the header comment of each script.
