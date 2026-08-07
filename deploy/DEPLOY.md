# Deploying Naaf to a Debian 13 VPS

naaf deploys to **any Debian 13 (trixie) host you can reach as root over SSH** —
there is no provider API in the deployment path. `deploy/provision/` is plain
Debian + systemd, and `deploy/run-remote.sh` drives it against an IP address.

Two stages. Stage 1 de-risks provisioning by running each step by hand on a
throwaway box and reading the output; Stage 2 bakes the *same* verified steps into
cloud-init so a fresh box provisions itself. Both use the identical, idempotent
scripts under `deploy/provision/` — there is no second copy of the logic to drift.

## Prerequisites

**On the target box:** Debian 13 (trixie), 1+ vCPU, 1–2 GB RAM, root SSH access.
Debian 12 will not work — bookworm's Rust is too old for Ruby 4.0's JIT build.

**On your workstation:** `ssh`, `rsync`, `jq`.

**Optionally**, a provider CLI to create the box and a DNS CLI to point a name at
it. `deploy/vultr/` and `deploy/dns/` are worked examples for Vultr and DNSimple;
they are conveniences, not requirements. Any box you can already SSH into works
with Stage 1 as written — skip straight to `run-remote.sh`.

## What gets provisioned (`deploy/provision/`, run in order)
| step | does |
|---|---|
| `05-swap` | 2 GB swapfile (guards the Ruby build) |
| `10-packages` | apt: WireGuard/nftables + Ruby 4.0 build toolchain |
| `20-system` | `naaf` user, dirs, IP-forward sysctl, tmpfiles, SSH hardening, static `/etc/nftables.conf` |
| `30-ruby` | Ruby 4.0.6 + YJIT via ruby-install → `/opt/rubies/ruby-4.0.6` (slow: 15–30 min on 1 vCPU) |
| `40-app` | `.env` (generated secret), `bundle install`, install both systemd units |
| `50-bringup` | helper → `bootstrap.rb` (keys/admin-pw/endpoint host) → app → `wg-quick@wg0` |

Every step logs to `/var/log/naaf-provision/<step>.log` on the box; Stage-1 runs
also tee to `deploy/logs/` locally (gitignored).

## Stage 1 — verify on a vanilla box

```bash
IP=<your box's public IP>
# Optional: a specific key, otherwise your normal ssh config and agent are used.
export NAAF_SSH_KEY=~/.ssh/id_ed25519

# 1. push the repo, then run steps one at a time and read each log
deploy/run-remote.sh "$IP" sync
deploy/run-remote.sh "$IP" step 05-swap
deploy/run-remote.sh "$IP" step 10-packages
deploy/run-remote.sh "$IP" step 20-system
deploy/run-remote.sh "$IP" step 30-ruby        # the long one
deploy/run-remote.sh "$IP" step 40-app

# 2. bring-up needs the admin password (+ the FQDN clients will dial)
export NAAF_ADMIN_PASSWORD='choose-a-strong-one'
export NAAF_ENDPOINT_HOST='vpn.example.com'
deploy/run-remote.sh "$IP" step 50-bringup

# 3. smoke test: admin UI over the SSH forward, then wg/nft state
ssh -L 8080:127.0.0.1:8080 root@"$IP"          # open http://localhost:8080
deploy/run-remote.sh "$IP" exec 'wg show wg0; nft list table inet naaf; ruby -v'
```

Fix any failing step and re-run just that step — they are idempotent.

`NAAF_ENDPOINT_HOST` is the hostname baked into every client config. Set it to a
name you control and you can migrate to a new box later by repointing DNS, with
no client reconfiguration. Leave it unset and clients dial the box's public IPv4
directly, which pins them to that box.

## Stage 2 — self-provisioning box

Push the verified repo somewhere cloud-init can clone it (see the code-delivery
note below), then hand the provider this user-data script:

```bash
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y git ca-certificates
git clone --depth 1 --branch main https://github.com/<owner>/<repo>.git /opt/naaf
export NAAF_ADMIN_PASSWORD='choose-a-strong-one'
export NAAF_ENDPOINT_HOST='vpn.example.com'
bash /opt/naaf/deploy/provision/provision.sh
```

Every provider that supports cloud-init accepts a `#!/bin/bash` user-data script,
so this is portable as-is. `deploy/vultr/create-box.sh --auto` generates exactly
this and passes it to `vultr-cli` for you.

Watch it come up, then point DNS at the box:

```bash
ssh root@"$IP" 'tail -f /var/log/cloud-init-output.log'
ssh root@"$IP" 'ls -la /var/log/naaf-provision/'
```

### Code delivery (why Stage 2 needs a repo URL)

Stage 1 rsyncs your working tree over SSH. Stage 2's cloud-init runs on the box
with no path back to your workstation, so it `git clone`s the repo. Nothing secret
is in git (`.env` is ignored; server and client keys live in the database, never
the repo), so a **public** repo needs no token. For a **private** repo, pass a
read-only token — but note it is then stored in the instance's user-data at your
provider, so rotate or detach it afterwards.

## Updating a running box

```bash
deploy/run-remote.sh "$IP" sync
ssh root@"$IP" 'systemctl restart naaf'   # also restart naaf-helper if bin/naaf-helper changed
```

## Provider examples

`deploy/vultr/create-box.sh` (create an instance, `--vanilla` or `--auto`),
`deploy/vultr/ensure-firewall.sh` (a group allowing only 22/tcp and 51820/udp),
and `deploy/dns/update-record.sh` (idempotent A/AAAA upsert in DNSimple). Each
requires its own CLI to be authenticated and takes account-specific values from
environment variables with no defaults — read the header comment of each script.

Adding another provider means one script that creates a box and prints its IP;
everything downstream is provider-agnostic.

## Troubleshooting

If a client can't connect, DNS times out, or full-tunnel is dead, start with
[`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md). The most common cause is
a second firewall (`ufw`) on the host — provisioning disables it, but it is the
first thing to check.
