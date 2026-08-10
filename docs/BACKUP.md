# Naaf — backup, restore, and box migration

The SQLite database at `/var/lib/naaf/naaf.db` is the whole system. It holds the
**server private key**, every peer, every firewall rule, and the admin password
hash. Losing it means regenerating the server key and re-enrolling every client —
which, for a phone provisioned by QR code, means physically handling the device.

Losing the *box* costs nothing if you still have the database: provision a new
one, restore, repoint DNS, and every existing client config keeps working
untouched. That is the whole point of what follows.

Two independent layers, either usable without the other:

| | what it protects against | granularity | off-box |
|---|---|---|---|
| **Snapshots** (on by default) | a bad write, an accidental delete, a botched change | one file per interval, default hourly | no |
| **Litestream** (off by default) | the same, plus losing the disk or the whole VPS | continuous, second-level | yes, with an object-store replica |

---

## 1. Snapshots

The application takes a `VACUUM INTO` snapshot on its own reactor task, by
default hourly, keeping the newest 24.

```
NAAF_BACKUP_ENABLED=1
NAAF_BACKUP_DIR=/var/lib/naaf/backups
NAAF_BACKUP_INTERVAL=3600
NAAF_BACKUP_KEEP=24
```

`VACUUM INTO` is a transaction-consistent snapshot that never touches the source:
no write lock, no checkpoint, no page rewrite. It is also, explicitly, what
Litestream's own documentation recommends *instead of* a bare `VACUUM` — so the
two layers compose rather than fight.

Each snapshot is written to a `.tmp` name and renamed into place, so no reader
ever sees a partial file, and it is `chmod 0600` before it becomes reachable
under its final name. **A snapshot contains the server private key.** Treat a
copy of one exactly as you would treat the key itself.

`NAAF_BACKUP_KEEP` is a hard ceiling, not a high-water mark: rotation runs before
each write, so a nearly-full volume gets a slot freed before another file is
requested. Only files matching `naaf-<timestamp>.db` are ever deleted, so
anything else you leave in the directory is safe.

**Check it is working:**

```sh
ls -l /var/lib/naaf/backups        # naaf-<ts>.db, 0600 naaf:naaf, no .tmp files
sqlite3 /var/lib/naaf/backups/naaf-<ts>.db 'PRAGMA integrity_check; SELECT count(*) FROM clients;'
journalctl -u naaf | grep -i backup
```

The Settings page also shows the newest snapshot's name and size. There is
deliberately **no download button** — that would serve the server private key and
the admin password hash over HTTP. Use `scp`.

**Restore from a snapshot:**

```sh
systemctl stop naaf litestream
mv /var/lib/naaf/naaf.db{,.broken}
rm -f /var/lib/naaf/naaf.db-wal /var/lib/naaf/naaf.db-shm   # all three must go
cp /var/lib/naaf/backups/naaf-<ts>.db /var/lib/naaf/naaf.db
chown naaf:naaf /var/lib/naaf/naaf.db
sqlite3 /var/lib/naaf/naaf.db 'PRAGMA integrity_check;'     # expect: ok
systemctl start litestream naaf
```

Deleting the `-wal` and `-shm` files is not optional. A stale pair left beside a
restored database is a documented corruption path.

---

## 2. Litestream

Continuous replication of the write-ahead log, giving second-level recovery point
and — with an object-store replica — a copy that survives the machine.

Off by default. Enable it in `naaf.conf` and run the step:

```
NAAF_LITESTREAM_ENABLED=1
NAAF_LITESTREAM_VERSION=0.5.16
NAAF_LITESTREAM_REPLICA_TYPE=file        # or s3
NAAF_LITESTREAM_PATH=/var/lib/naaf/replica
```

```sh
./deploy.sh --sync
./deploy.sh --step 45-litestream
```

The step installs the pinned `.deb` from the GitHub release, verified against
that release's `checksums.txt`. Litestream publishes no apt repository, so this
adds no signing keys and no `sources.list` entries.

### Choosing a replica

**`type: file`** needs no cloud account and works on any VPS. Be clear-eyed about
what it buys: on the same disk it survives an application bug, a bad migration,
or an accidental delete — **not a dead disk and not a destroyed VPS.** Point it at
a separately mounted volume and it becomes a genuine second copy.

**`type: s3`** works with AWS, Cloudflare R2, Backblaze B2, MinIO, and Wasabi.
This is the one that survives losing the machine.

**Create the bucket first.** Litestream never creates it, and a missing bucket
looks like a credentials error in the journal. Cloudflare R2 is the cheap default
— 10 GB free, no egress fee, and the database is well under a megabyte. (Vultr
Object Storage also works and is S3-compatible, but its smallest tier is $18/mo
for 1 TB, which is a lot of money to replicate a file this size.)

```
NAAF_LITESTREAM_REPLICA_TYPE=s3
NAAF_LITESTREAM_BUCKET=naaf
NAAF_LITESTREAM_PREFIX=naaf
NAAF_LITESTREAM_REGION=auto
NAAF_LITESTREAM_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
```

`REGION` and `ENDPOINT` per provider — the rest of the shape is identical:

| provider | `REGION` | `ENDPOINT` |
|---|---|---|
| Cloudflare R2 | `auto` | `https://<account-id>.r2.cloudflarestorage.com` |
| Backblaze B2 | `us-west-004` | `https://s3.us-west-004.backblazeb2.com` |
| Vultr | `ewr1` | `https://ewr1.vultrobjects.com` |
| AWS | the bucket's region | omit |

R2 needs no `force-path-style` and no `sign-payload`; virtual-host addressing
works as-is. If a different provider 403s on upload, those two are the first
things to try — and neither is expressible in `naaf.conf` today, so it means
extending `deploy/provision/45-litestream.sh`.

> **The replica is not encrypted.** Litestream removed age encryption in v0.5.0
> and since v0.5.1 refuses to start if an `age:` block is configured, so a
> `type: s3` replica puts `server_privkey` and `admin_pw_hash` at rest with your
> object-store provider **in plaintext**, protected only by the bucket being
> private and by the keys in `/etc/naaf/litestream.env`. Use a bucket dedicated to
> this, keep it private, and treat its credentials exactly as you would treat the
> server private key — because that is what they reach. There is no encrypted
> option to switch to; per-page encryption in LTX is planned upstream, not shipped.

Credentials go in `/etc/naaf/litestream.env` (0640 root:naaf), **not in
`naaf.conf`**. `naaf.conf` is `EnvironmentFile=` for `naaf.service`, so every key
in it becomes an environment variable of the tunnel-facing web application, where
object-store credentials have no business being. Litestream reads
`LITESTREAM_ACCESS_KEY_ID` and `LITESTREAM_SECRET_ACCESS_KEY` from its own
environment and expands them into the config, so the keys never appear in
`/etc/litestream.yml` either.

Pass them once at provisioning time:

```sh
export NAAF_LITESTREAM_ACCESS_KEY_ID=...
export NAAF_LITESTREAM_SECRET_ACCESS_KEY=...
./deploy.sh --step 45-litestream
```

### Notes on how it is wired

- Litestream runs as **`naaf`, not root** (a drop-in at
  `/etc/systemd/system/litestream.service.d/10-naaf.conf` overrides the packaged
  unit). It creates the `-wal`/`-shm` files when they are absent, so as root it
  would leave root-owned files in a `naaf`-owned directory and the application
  would fail to write to its own database on the next restart — silently, weeks
  later.
- The drop-in uses `Wants=naaf.service`, never `Requires=`. Replication must
  never be able to take the VPN down.
- The config names the database by `path:`, never `dir:`/`pattern:`. A directory
  scan would find the hourly snapshots in `/var/lib/naaf/backups` and try to
  replicate those too.
- `PRAGMA journal_mode = WAL` and `PRAGMA busy_timeout = 5000` in
  `lib/naaf/db.rb` are load-bearing: Litestream refuses a database that is not in
  WAL mode, and asks for that busy timeout so its checkpoints are not blocked.
  Do not "tidy" them away.
- **Do not** set `wal_autocheckpoint = 0`. It is advice for high write rates;
  Naaf's write volume is a handful of small updates per reconcile. Disabling it
  would mean unbounded WAL growth whenever Litestream is off — which is the
  default configuration.

### Running the CLI against an s3 replica

`/etc/naaf/litestream.env` is an `EnvironmentFile=` for the *unit*, so the daemon
has the object-store keys but a command you type does not. Every `litestream`
invocation below therefore fails on an s3 replica with

```
get identity: get credentials: failed to refresh cached credentials,
unexpected empty EC2 IMDS role list
```

— which reads like a broken bucket and is nothing of the sort. Source the file
first, in the same shell:

```sh
set -a; . /etc/naaf/litestream.env; set +a
```

`file` replicas need no credentials, so this section is s3-only. The commands
that follow assume you have run it.

### Verify replication is actually working

Four checks, in increasing strength. Only the last one proves anything that
matters.

```sh
# 1. alive, not crash-looping
systemctl status litestream --no-pager

# 2. it sees the database and has data
litestream databases -config /etc/litestream.yml
litestream status -config /etc/litestream.yml
#   (there is no `litestream snapshots` in 0.5.x — it was a 0.3 command)

# 3. a write actually propagates — the only end-to-end check
litestream ltx -config /etc/litestream.yml -level 0 /var/lib/naaf/naaf.db | tail -3
#   ...now make a harmless change in the admin UI (add then delete a DNS record)
sleep 5
litestream ltx -config /etc/litestream.yml -level 0 /var/lib/naaf/naaf.db | tail -3
#   a higher TXID = live. Nothing new = not replicating, whatever systemctl says.

# 4. the restore actually restores. Run this the day you enable Litestream,
#    and quarterly after.
runuser -u naaf -- litestream restore -config /etc/litestream.yml \
  -o /var/lib/naaf/restore-check.db /var/lib/naaf/naaf.db
sqlite3 /var/lib/naaf/restore-check.db \
  'PRAGMA integrity_check; SELECT count(*) FROM clients; SELECT length(server_privkey) FROM settings;'
rm -f /var/lib/naaf/restore-check.db
```

`length(server_privkey)`, never the value — that key is never printed anywhere.
And the scratch file goes in `/var/lib/naaf` (0750 `naaf:naaf`), not `/tmp`:
a restored database is a *complete copy of the server private key*, and `/tmp` is
world-readable. Delete it when the check is done.

`runuser -u naaf --`, not `sudo -u naaf`: `runuser` keeps the environment you
just sourced, and `sudo` strips it — so the `sudo` form fails with the IMDS error
above even after you have sourced the credentials.

Naaf's own reconcile loop writes handshake counters every
`NAAF_RECONCILE_INTERVAL` seconds, so on a box with clients the TXID in check 3
advances on its own within a minute. A TXID that is *not* moving on a live box is
the signal, and it is the cheapest alarm available without a monitoring stack.

### Restore from the replica

```sh
set -a; . /etc/naaf/litestream.env; set +a          # s3 replicas only
systemctl stop naaf litestream
mv /var/lib/naaf/naaf.db{,.broken}
rm -f /var/lib/naaf/naaf.db-wal /var/lib/naaf/naaf.db-shm
runuser -u naaf -- litestream restore -config /etc/litestream.yml /var/lib/naaf/naaf.db
chmod 0600 /var/lib/naaf/naaf.db
sqlite3 /var/lib/naaf/naaf.db 'PRAGMA integrity_check;'
systemctl start litestream naaf
```

`runuser -u naaf --` so the restored file is owned by the service, not by root,
and so the sourced credentials survive into the command — `sudo` would strip
them.

The `chmod` is not cosmetic. Litestream writes the restored file `0644` under the
default umask, while the live database is `0600`; skipping it leaves the server
private key world-readable on the box. Nothing later puts it back.

For a point-in-time restore, always write to a side path and inspect before
swapping:

```sh
runuser -u naaf -- litestream restore -config /etc/litestream.yml \
  -timestamp 2026-08-07T11:00:00Z -o /var/lib/naaf/naaf.db.pit /var/lib/naaf/naaf.db
chmod 0600 /var/lib/naaf/naaf.db.pit
sqlite3 /var/lib/naaf/naaf.db.pit 'select name, wg_ip from clients'
```

---

## 3. Migrating to a new box

The payoff. Because the server private key lives in the database and every issued
client config pins `PublicKey = <server pubkey>` and
`Endpoint = <endpoint_host>:<port>`, restoring the database onto a new machine
gives it the *same cryptographic identity*. Repoint DNS and every existing client
reconnects with **zero config reissue**.

This only works if `NAAF_ENDPOINT_HOST` is a name you control. If clients dial a
raw IP, they are pinned to that box. The one thing "zero config reissue" does not
cover is the `split-ws` flavors: their path prefix lives in
`/etc/naaf/wstunnel.env` on the box, not in the database — see step 5 below.

This is the one procedure that does **not** use a plain `./deploy.sh`: a full
deploy would run `50-bringup` and generate a fresh server identity, which is
exactly what you are trying to avoid. So provision up to that point, put the
database in place, and only then bring up.

```sh
IP=<new box>

# 1. provision, but stop before bring-up. Note where this list stops: 60-certs
#    and 65-wstunnel come later, in step 5, for the reason spelled out there.
./deploy.sh --sync "$IP"
for s in 05-swap 10-packages 20-system 30-ruby 40-app 45-litestream; do
  ./deploy.sh --step $s "$IP"
done

# 2. restore the database BEFORE 50-bringup. Its already_bootstrapped() guard
#    keys on settings.server_pubkey, so a restored database makes it skip
#    bootstrap entirely and keep the original server identity.
./deploy.sh --ssh "$IP" -- 'set -a; . /etc/naaf/litestream.env; set +a
  systemctl stop litestream &&
  runuser -u naaf -- litestream restore -config /etc/litestream.yml /var/lib/naaf/naaf.db &&
  chmod 0600 /var/lib/naaf/naaf.db &&
  systemctl start litestream'
#    (or: scp a snapshot into /var/lib/naaf/naaf.db and chown naaf:naaf)

# 3. bring up: no new keys, no new admin password, every client row intact.
#    No password needed — the step sees the restored server key and skips
#    bootstrap. If it asks for one, the restore in step 2 did not land.
./deploy.sh --step 50-bringup "$IP"

# 4. refresh the facts that are about the box, not about the deployment
./deploy.sh --ssh "$IP" -- 'cd /opt/naaf && runuser -u naaf -- \
  env BUNDLE_GEMFILE=/opt/naaf/Gemfile HOME=/var/lib/naaf \
  PATH=/opt/rubies/ruby-4.0.6/bin:/usr/bin:/bin \
  bundle exec ruby bin/bootstrap.rb --refresh-network'
./deploy.sh --ssh "$IP" -- 'systemctl restart naaf'

# 5. certificates, then the transport that consumes them. Only now: both name
#    themselves after endpoint_host || endpoint_v4 from the settings table, and
#    endpoint_v4 travelled with the database — so before step 4 they would mint
#    a certificate for the OLD box's address and serve it. ACME is DNS-01, so
#    issuance does not need anything to resolve to this box yet; the certificate
#    is ready before the cutover rather than after it.
for s in 60-certs 65-wstunnel; do
  ./deploy.sh --step $s "$IP"
done

./deploy.sh --verify "$IP"

# 6. repoint DNS. Clients dial endpoint_host, so this is the cutover.
```

Three things that will bite you if skipped:

- **Step 2 must precede step 3.** Run bring-up first and bootstrap generates a
  fresh keypair, at which point the restore was pointless and every client is
  broken.
- **`endpoint_v4`, `endpoint_v6` and `wan_interface` travel with the database and
  are wrong on the new box.** Step 4 refreshes exactly those three and touches
  neither keys nor the admin password.
- **Step 5 must follow step 4, not ride along with step 1.** `60-certs` derives
  the certificate name from `endpoint_host || endpoint_v4`, so on a deployment
  that dials a bare IP it would otherwise issue for the machine you are leaving,
  and `65-wstunnel` would serve that certificate to every `split-ws` client. With
  `NAAF_ENDPOINT_HOST` set — the configuration this whole procedure is for — the
  name is right either way, and running it late costs nothing. The path prefix in
  `/etc/naaf/wstunnel.env` is *not* in the database and does not travel: a
  restored box generates a fresh one, which invalidates every `split-ws` config
  ever issued. Copy the file across before step 5 to keep them working
  (0640 root:naaf), or reissue those configs after the cutover.
