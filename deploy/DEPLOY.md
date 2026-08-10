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
| always | run `deploy/provision/provision.sh` — the nine steps below |
| always | run `deploy/verify.sh` and print how to reach the admin UI |

The provisioning steps, in the one order that works:

| step | does |
|---|---|
| `05-swap` | 2 GB swapfile (headroom on a 1–2 GB box) |
| `10-packages` | apt: WireGuard/nftables, a compiler for native gem extensions, and the CLI tools later steps need (`sqlite3`, `openssl`, `dig`) |
| `20-system` | `naaf` user, dirs, IP-forward sysctl, tmpfiles, SSH hardening, `/etc/nftables.conf` from the template |
| `30-ruby` | `rv` + Ruby with YJIT, prebuilt and checksum-verified (seconds) |
| `40-app` | `/etc/naaf/naaf.conf` with a generated session secret, `bundle install`, both systemd units |
| `45-litestream` | optional off-box replication; a no-op unless `NAAF_LITESTREAM_ENABLED=1` |
| `50-bringup` | helper → `bootstrap.rb` (keys/admin-pw/endpoint host) → app → `wg-quick@wg0` |
| `60-certs` | the TLS certificate store in `/etc/naaf/certs`: self-signed always, Let's Encrypt over DNS-01 when `NAAF_ACME_ENABLED=1` |
| `65-wstunnel` | optional TLS-WebSocket transport in front of the WireGuard listener; a no-op unless `NAAF_WSTUNNEL_ENABLED=1` |

Every step is idempotent and logs to `/var/log/naaf-provision/<step>.log` on the
box; the whole run is also tee'd to `deploy/logs/` locally (gitignored).

`50-bringup` generates the server keypair exactly once, guarded on
`settings.server_pubkey` being set. That guard is why re-deploying is safe, why a
re-deploy needs no admin password, and why [restoring a database onto a fresh
box](../docs/BACKUP.md) keeps the original server identity.

The last two steps run **after** bring-up on purpose: a certificate has to be
named for `endpoint_host || endpoint_v4` as they sit in the settings table, and
`bootstrap.rb` only fills `endpoint_v4` in at step 50. Running them earlier meant
no name at all on a default bare-IP deploy — and a step that fails there takes
`50-bringup` with it, leaving the box with no WireGuard interface. `60-certs` is
also the one step that never fails the deploy: a CA outage or a missing DNS
record downgrades to a warning and the self-signed certificate beside it, because
a certificate problem must not cost you the VPN. `20-system` still opens the
firewall early — the gap where tcp/443 is open with nothing listening is a
`connection refused`, whereas the reverse order gives you a live listener the
firewall silently drops.

The ACME DNS token never goes in `naaf.conf` (that file is `EnvironmentFile=` for
the web app). Export it for one deploy and `deploy.sh` ships it to
`/etc/naaf/acme.env`, 0600 root:root:

```bash
export NAAF_ACME_DNS_TOKEN=...
./deploy.sh --sync && ./deploy.sh --step 60-certs
```

`--step` alone neither syncs the repo nor reinstalls `naaf.conf`, so a `--sync`
first is what makes an edited config actually reach the box. Full detail in
[`../docs/CERTS.md`](../docs/CERTS.md) and
[`../docs/WSTUNNEL.md`](../docs/WSTUNNEL.md).

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
attaching a firewall group that allows 22/tcp, the WireGuard port, and — only
when `NAAF_WSTUNNEL_ENABLED=1` — the wstunnel port. That group is created once
and reused by description afterwards, so enabling wstunnel on an existing box
means adding the rule by hand or deleting the group.
`deploy/providers/dnsimple/update-record.sh` upserts an A (and optional AAAA)
record. Each needs its own authenticated CLI and takes account-specific values
from `naaf.conf` with no defaults — read the header comment of each script.
