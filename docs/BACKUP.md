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
deploy/run-remote.sh <ip> config
deploy/run-remote.sh <ip> step 45-litestream
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

```
NAAF_LITESTREAM_REPLICA_TYPE=s3
NAAF_LITESTREAM_BUCKET=naaf-backups
NAAF_LITESTREAM_PREFIX=naaf
NAAF_LITESTREAM_REGION=auto
NAAF_LITESTREAM_ENDPOINT=https://<account>.r2.cloudflarestorage.com
```

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
deploy/run-remote.sh <ip> step 45-litestream
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

### Verify replication is actually working

Four checks, in increasing strength. Only the last one proves anything that
matters.

```sh
# 1. alive, not crash-looping
systemctl status litestream --no-pager

# 2. it sees the database and has data
litestream databases -config /etc/litestream.yml
litestream snapshots -config /etc/litestream.yml /var/lib/naaf/naaf.db

# 3. a write actually propagates — the only end-to-end check
litestream ltx -config /etc/litestream.yml -level 0 /var/lib/naaf/naaf.db | tail -3
#   ...now make a harmless change in the admin UI (add then delete a DNS record)
sleep 5
litestream ltx -config /etc/litestream.yml -level 0 /var/lib/naaf/naaf.db | tail -3
#   a higher TXID = live. Nothing new = not replicating, whatever systemctl says.

# 4. the restore actually restores. Run this the day you enable Litestream,
#    and quarterly after.
sudo -u naaf litestream restore -config /etc/litestream.yml \
  -o /tmp/verify.db /var/lib/naaf/naaf.db
sqlite3 /tmp/verify.db 'SELECT count(*) FROM clients; SELECT length(server_privkey) FROM settings;'
rm -f /tmp/verify.db
```

`length(server_privkey)`, never the value — that key is never printed anywhere.

A healthy replica gains a snapshot per `NAAF_LITESTREAM_SNAPSHOT_INTERVAL`, so a
stale newest date from check 2 is the cheapest alarm available without a
monitoring stack.

### Restore from the replica

```sh
systemctl stop naaf litestream
mv /var/lib/naaf/naaf.db{,.broken}
rm -f /var/lib/naaf/naaf.db-wal /var/lib/naaf/naaf.db-shm
sudo -u naaf litestream restore -config /etc/litestream.yml /var/lib/naaf/naaf.db
sqlite3 /var/lib/naaf/naaf.db 'PRAGMA integrity_check;'
systemctl start litestream naaf
```

`sudo -u naaf` so the restored file is owned by the service, not by root.

For a point-in-time restore, always write to a side path and inspect before
swapping:

```sh
sudo -u naaf litestream restore -config /etc/litestream.yml \
  -timestamp 2026-08-07T11:00:00Z -o /var/lib/naaf/naaf.db.pit /var/lib/naaf/naaf.db
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
raw IP, they are pinned to that box.

```sh
IP=<new box>

# 1. provision, but stop before bring-up
deploy/run-remote.sh "$IP" sync
for s in 05-swap 10-packages 20-system 30-ruby 40-app 45-litestream; do
  deploy/run-remote.sh "$IP" step $s
done

# 2. restore the database BEFORE 50-bringup. Its already_bootstrapped() guard
#    keys on settings.server_pubkey, so a restored database makes it skip
#    bootstrap entirely and keep the original server identity.
deploy/run-remote.sh "$IP" exec 'systemctl stop litestream &&
  sudo -u naaf litestream restore -config /etc/litestream.yml /var/lib/naaf/naaf.db &&
  systemctl start litestream'
#    (or: scp a snapshot into /var/lib/naaf/naaf.db and chown naaf:naaf)

# 3. bring up: no new keys, no new admin password, every client row intact
export NAAF_ADMIN_PASSWORD='ignored — bootstrap is skipped, but the step requires it'
deploy/run-remote.sh "$IP" step 50-bringup

# 4. refresh the facts that are about the box, not about the deployment
deploy/run-remote.sh "$IP" exec 'cd /opt/naaf && runuser -u naaf -- \
  env BUNDLE_GEMFILE=/opt/naaf/Gemfile HOME=/var/lib/naaf \
  PATH=/opt/rubies/ruby-4.0.6/bin:/usr/bin:/bin \
  bundle exec ruby bin/bootstrap.rb --refresh-network'
deploy/run-remote.sh "$IP" exec 'systemctl restart naaf'

# 5. repoint DNS. Clients dial endpoint_host, so this is the cutover.
```

Two things that will bite you if skipped:

- **Step 2 must precede step 3.** Run bring-up first and bootstrap generates a
  fresh keypair, at which point the restore was pointless and every client is
  broken.
- **`endpoint_v4`, `endpoint_v6` and `wan_interface` travel with the database and
  are wrong on the new box.** Step 4 refreshes exactly those three and touches
  neither keys nor the admin password.
