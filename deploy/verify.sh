#!/usr/bin/env bash
# Post-deploy verification. Run ON the server, as root. `./deploy.sh` runs it as
# the last thing it does; `./deploy.sh --verify` re-runs just this.
#
#   ./deploy.sh --verify                    # from your workstation
#   bash /opt/naaf/deploy/verify.sh         # on the box
#
# Everything is derived from naaf.conf and the database rather than hardcoded, so
# this checks YOUR deployment, not a reference one. It asserts the invariants
# that are easy to break and expensive to discover late: the admin UI never
# reaching a public interface, ufw not having crept back onto the netfilter
# hooks, the firewall and the daemon agreeing on the WireGuard port, backups
# actually being written and readable only by the service, the TLS store's key
# material being unreadable by every uid but root, and no client private key
# existing anywhere.
#
# Exits non-zero if any check fails, so it works in a pipeline.
set -uo pipefail

NAAF_CONF="${NAAF_CONF:-/etc/naaf/naaf.conf}"
# shellcheck source=/dev/null
[ -f "$NAAF_CONF" ] && { set -a; . "$NAAF_CONF"; set +a; }
: "${NAAF_DB:=/var/lib/naaf/naaf.db}"
: "${NAAF_USER:=naaf}"
: "${NAAF_GROUP:=naaf}"
: "${NAAF_STATE_DIR:=/var/lib/naaf}"
: "${NAAF_WEB_PORT:=8080}"
: "${NAAF_BACKUP_ENABLED:=1}"
: "${NAAF_BACKUP_DIR:=/var/lib/naaf/backups}"
: "${NAAF_LITESTREAM_ENABLED:=0}"
: "${NAAF_LITESTREAM_REPLICA_TYPE:=file}"
# Every name this script reads has to be defaulted HERE. This runs `set -u` and
# sources naaf.conf directly — it does not source deploy/provision/00-lib.sh, so
# that file's defaults never reach it. A box whose /etc/naaf/naaf.conf predates
# the key below would otherwise abort the ENTIRE verification on an unbound
# variable, and deploy.sh runs this without `|| true`: every upgrade deploy
# would fail, including the ones that never enable any of this.
: "${NAAF_WSTUNNEL_ENABLED:=0}"
: "${NAAF_WSTUNNEL_PORT:=443}"
: "${NAAF_CERT_DIR:=/etc/naaf/certs}"
: "${NAAF_ACME_ENABLED:=0}"

pass=0; fail=0; warn=0
# Count files matching a glob. A glob that matches nothing stays literal, so the
# -e test is what makes "zero" come out as zero.
nglob() { local n=0 f; for f in "$@"; do [ -e "$f" ] && n=$((n+1)); done; printf '%s' "$n"; }
ok()   { printf '  PASS  %-56s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-56s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
note() { printf '  WARN  %-56s %s\n' "$1" "${2:-}"; warn=$((warn+1)); }
ck()   { [ "$2" = "$3" ] && ok "$1" "$3" || no "$1" "want=$2 got=$3"; }
has()  { printf '%s' "$3" | grep -q -- "$2" && ok "$1" || no "$1" "missing: $2"; }

command -v sqlite3 >/dev/null || { echo "sqlite3 is required"; exit 2; }
[ -r "$NAAF_DB" ] || { echo "cannot read $NAAF_DB (run as root)"; exit 2; }
q() { sqlite3 "$NAAF_DB" "$1"; }

SERVER_IP=$(q 'select server_ip from settings')
WG_IF=$(q 'select wg_interface from settings')
PORT=$(q 'select listen_port from settings')
SUBNET=$(q 'select wg_subnet from settings')

echo "── 1. configuration ──"
echo "  db=$NAAF_DB  wg=$WG_IF  subnet=$SUBNET  server=$SERVER_IP  port=$PORT"
# naaf.conf only seeds the database on first boot; the database wins afterwards.
# Disagreement is legal, so it is a warning that names the difference, not a
# failure — the point is that it is visible rather than silent.
for pair in "NAAF_WG_SUBNET:$SUBNET" "NAAF_SERVER_IP:$SERVER_IP" \
            "NAAF_LISTEN_PORT:$PORT" "NAAF_WG_INTERFACE:$WG_IF" \
            "NAAF_DNS_DOMAIN:$(q 'select dns_domain from settings')" \
            "NAAF_MTU:$(q 'select mtu from settings')"; do
  k=${pair%%:*}; dbv=${pair#*:}; cv=${!k:-}
  [ -z "$cv" ] || [ "$cv" = "$dbv" ] && continue
  note "naaf.conf differs from the DB ($k)" "conf=$cv db=$dbv (DB wins)"
done
ck "endpoint_v4 is set (blank breaks client configs)" "1" \
   "$(q "select count(*) from settings where length(coalesce(endpoint_v4,''))>0")"

echo
echo "── 2. listeners: tunnel-only, never 0.0.0.0 ──"
binds=$(ss -ltnH "( sport = :$NAAF_WEB_PORT )")
ck "admin UI listener count" "2" "$(printf '%s' "$binds" | grep -c . )"
has "admin UI on the WireGuard IP" "$SERVER_IP:$NAAF_WEB_PORT" "$binds"
has "admin UI on loopback" "127.0.0.1:$NAAF_WEB_PORT" "$binds"
ck "admin UI NOT on 0.0.0.0" "0" "$(printf '%s' "$binds" | grep -c "0\.0\.0\.0:$NAAF_WEB_PORT")"
ck "admin UI NOT on [::]" "0" "$(printf '%s' "$binds" | grep -c '\[::\]')"
has "DNS on the WireGuard IP" "$SERVER_IP:53" "$(ss -lunH '( sport = :53 )')"

echo
echo "── 3. firewall ──"
tables=$(nft list tables | awk '{print $2" "$3}' | sort | paste -sd, -)
# An `ip filter` / `ip6 filter` table means ufw is back on the same netfilter
# hooks, which silently drops WireGuard, tunnel DNS and forwarding.
ck "only the expected nft tables (ufw not back)" "inet filter,inet naaf" "$tables"
has "base firewall allows udp/$PORT" "udp dport $PORT" "$(nft list table inet filter)"
has "app table has the tunnel subnet" "$SUBNET" "$(nft list table inet naaf)"
ck "no policy drop on an app base chain" "0" \
   "$(nft list table inet naaf | grep -c 'hook .* policy drop')"
ck "ip_forward enabled" "1" "$(sysctl -n net.ipv4.ip_forward)"

echo
echo "── 4. wireguard ──"
ck "wg listen-port matches the database" "$PORT" "$(wg show "$WG_IF" listen-port 2>/dev/null)"
has "interface carries the gateway address" "$SERVER_IP/" "$(ip -4 addr show "$WG_IF" 2>/dev/null)"
ck "enabled clients are peers in the kernel" \
   "$(q 'select count(*) from clients where enabled=1')" \
   "$(wg show "$WG_IF" peers 2>/dev/null | grep -c .)"

echo
echo "── 5. services ──"
for u in naaf naaf-helper "wg-quick@$WG_IF" nftables; do
  ck "$u" "active" "$(systemctl is-active "$u" 2>/dev/null)"
done
has "helper socket is group-readable only" "srw-rw----" "$(ls -l "${NAAF_HELPER_SOCKET:-/run/naaf/helper.sock}" 2>/dev/null)"

echo
echo "── 6. backups ──"
if [ "$NAAF_BACKUP_ENABLED" = "1" ]; then
  n=$(nglob "$NAAF_BACKUP_DIR"/naaf-*.db)
  if [ "$n" -ge 1 ]; then
    ok "snapshots present" "$n"
    newest=$(ls -1t "$NAAF_BACKUP_DIR"/naaf-*.db | head -1)
    # A snapshot contains server_privkey and admin_pw_hash.
    ck "newest snapshot mode 0600" "600" "$(stat -c %a "$newest")"
    ck "newest snapshot owner" "$NAAF_USER:$NAAF_GROUP" "$(stat -c '%U:%G' "$newest")"
    ck "newest snapshot integrity" "ok" "$(sqlite3 "$newest" 'PRAGMA integrity_check')"
    ck "snapshot count within NAAF_BACKUP_KEEP" "yes" \
       "$([ "$n" -le "${NAAF_BACKUP_KEEP:-24}" ] && echo yes || echo "no ($n)")"
  else
    note "no snapshot yet" "expected within ${NAAF_BACKUP_INTERVAL:-3600}s of start"
  fi
  ck "no half-written snapshots left behind" "0" "$(nglob "$NAAF_BACKUP_DIR"/*.tmp)"
else
  note "backups disabled" "NAAF_BACKUP_ENABLED=$NAAF_BACKUP_ENABLED"
fi

echo
echo "── 7. litestream ──"
if [ "$NAAF_LITESTREAM_ENABLED" = "1" ]; then
  ck "litestream" "active" "$(systemctl is-active litestream 2>/dev/null)"
  # As root it would create root-owned -wal/-shm in a service-owned directory and
  # the app would fail to write to its own database on a later restart.
  ck "runs as the database owner, not root" "$NAAF_USER" \
     "$(ps -o user= -C litestream 2>/dev/null | head -1 | tr -d ' ')"
  ck "no root-owned wal/shm beside the database" "0" \
     "$(find "$NAAF_STATE_DIR" -maxdepth 1 -name 'naaf.db-*' -user root 2>/dev/null | grep -c .)"
  has "tracks the database" "$NAAF_DB" \
      "$(litestream databases -config /etc/litestream.yml 2>&1)"

  if [ "$NAAF_LITESTREAM_REPLICA_TYPE" = "s3" ]; then
    # The replica holds server_privkey in plaintext (litestream 0.5 has no
    # encryption), so these keys reach the whole database. Guard them like it.
    ck "credentials file mode" "640" "$(stat -c %a /etc/naaf/litestream.env 2>/dev/null)"
    ck "credentials file owner" "root:$NAAF_GROUP" \
       "$(stat -c '%U:%G' /etc/naaf/litestream.env 2>/dev/null)"
    # The keys must reach the config by ${VAR} expansion at load time. A literal
    # value here means that indirection broke and the secret is now on disk twice.
    ck "no literal key in /etc/litestream.yml" "0" \
       "$(grep -cE '^[[:space:]]*(access-key-id|secret-access-key):[[:space:]]*[^$[:space:]]' \
          /etc/litestream.yml 2>/dev/null)"
    # Objects in the bucket are the ONLY proof the replica is real: the daemon
    # reports active just as happily against a bucket it cannot write. The unit's
    # EnvironmentFile= does not reach a command we run, so source it ourselves —
    # without this every litestream command fails with an EC2 IMDS error that
    # looks nothing like its cause.
    n=$( ( set -a; . /etc/naaf/litestream.env; set +a
           litestream ltx -config /etc/litestream.yml -level 0 "$NAAF_DB" 2>/dev/null
         ) | grep -cE '^0[[:space:]]' )
    [ "${n:-0}" -ge 1 ] &&
      ok "replica reachable and holding transactions" "$n L0 files" ||
      no "replica reachable and holding transactions" "none — wrong bucket, bad keys, or no egress"
  fi
else
  note "replication disabled" "NAAF_LITESTREAM_ENABLED=$NAAF_LITESTREAM_ENABLED"
fi

echo
echo "── 8. wstunnel ──"
# The firewall assertions for tcp/$NAAF_WSTUNNEL_PORT live HERE and not in
# section 3, so the whole feature — port, unit, certificate wiring — is gated on
# one flag in one place and the default box is never told it is missing
# something it deliberately does not have.
if [ "$NAAF_WSTUNNEL_ENABLED" = "1" ]; then
  # `systemctl cat` prints the unit file verbatim, comments included — and this
  # unit's comments name the very flags they explain, so both
  # `--restrict-http-upgrade-path-prefix` and `--restrict-to` appear in prose
  # ABOVE the ExecStart. Strip comments first or the extractions below read the
  # documentation and report on it instead of on the command line.
  unit=$(systemctl cat naaf-wstunnel 2>/dev/null | grep -v '^[[:space:]]*#')
  ck "naaf-wstunnel" "active" "$(systemctl is-active naaf-wstunnel 2>/dev/null)"
  ck "listening on tcp/$NAAF_WSTUNNEL_PORT" "yes" \
     "$([ "$(ss -ltnH "( sport = :$NAAF_WSTUNNEL_PORT )" | grep -c .)" -ge 1 ] && echo yes || echo no)"
  has "base firewall allows tcp/$NAAF_WSTUNNEL_PORT" \
      "tcp dport $NAAF_WSTUNNEL_PORT" "$(nft list table inet filter)"
  # THE assertion of this section, and the reason it is `ck` and not `has`:
  # `has` is a substring grep, so a unit forwarding to 5182 would PASS against a
  # database that says 51820 — the exact drift this exists to catch. naaf.conf is
  # the only source for what wstunnel forwards to and the database is the only
  # source for where WireGuard actually listens. Section 1 deliberately downgrades
  # that disagreement to a WARN; here it is a silent total outage for every ws
  # client, with a healthy-looking unit and an open port.
  ck "forwards to the LIVE WireGuard port" "127.0.0.1:$PORT" \
     "$(printf '%s' "$unit" | sed -n 's/.*--restrict-to \([^ ]*\).*/\1/p' | head -1)"
  # wstunnel's embedded certificate is compiled into the binary and therefore
  # byte-identical on every deployment in the world — a perfect fingerprint. The
  # flag being present is what proves this box serves its own.
  has "serves its own certificate, not the embedded one" "--tls-certificate" "$unit"
  # LoadCredential= is what lets key.pem stay 0600 root:root while a transient
  # uid reads it, and pointing at the store is what makes renewals land here.
  has "tls-cert credential comes from the store" \
      "LoadCredential=tls-cert:$NAAF_CERT_DIR/" "$unit"
  has "tls-key credential comes from the store" \
      "LoadCredential=tls-key:$NAAF_CERT_DIR/" "$unit"
  # ProtectSystem=strict with no exception at all: the only publicly-exposed
  # daemon here has nothing to write, and an added ReadWritePaths would be the
  # first step back towards it being able to touch the store it reads from.
  ck "no ReadWritePaths (it has nothing to write)" "0" \
     "$(printf '%s' "$unit" | grep -c '^ReadWritePaths=')"
  # DynamicUser=yes: assert the PROPERTY, never the name. procps truncates USER
  # to 8 characters with a trailing `+` and the transient user is
  # `naaf-wstunnel`, 13 — so an equality test would fail on a correct box.
  ck "not running as root" "0" "$(ps -o user= -C wstunnel 2>/dev/null | grep -c '^root')"
  # The upgrade path prefix is a shared secret: every issued split-ws config
  # carries it, and this output is teed to deploy/logs/ back on the workstation.
  # So the check reports a verdict and never the value. `v1` is wstunnel's own
  # default prefix, which is to say no secret at all.
  prefix=$(printf '%s' "$unit" |
    sed -n 's/.*--restrict-http-upgrade-path-prefix \([^ ]*\).*/\1/p' | head -1)
  case "$prefix" in
    "") verdict=missing ;;
    v1) verdict="wstunnel's default" ;;
    *) verdict=generated ;;
  esac
  ck "upgrade path prefix generated (value never printed)" "generated" "$verdict"
else
  note "wstunnel disabled" "NAAF_WSTUNNEL_ENABLED=$NAAF_WSTUNNEL_ENABLED"
  # Off means off, and the port matters more than the unit: an open tcp/443 with
  # nothing behind it is an advertisement, which is the entire reason the base
  # firewall rule is conditional instead of always present.
  ck "wstunnel is not running" "no" \
     "$(case "$(systemctl is-active naaf-wstunnel 2>/dev/null)" in active) echo yes ;; *) echo no ;; esac)"
  ck "nothing listening on tcp/$NAAF_WSTUNNEL_PORT" "0" \
     "$(ss -ltnH "( sport = :$NAAF_WSTUNNEL_PORT )" | grep -c .)"
  ck "base firewall does not open tcp/$NAAF_WSTUNNEL_PORT" "0" \
     "$(nft list table inet filter | grep -c "tcp dport $NAAF_WSTUNNEL_PORT ")"
fi
# In BOTH branches, and forever: certificates come from ACME DNS-01, which proves
# control with a TXT record and needs no inbound port. A tcp/80 rule here means
# someone reached for HTTP-01 — the trailing space keeps 8080 out of the match.
ck "tcp/80 is never open (ACME is DNS-01)" "0" \
   "$(nft list table inet filter | grep -c 'tcp dport 80 ')"

echo
echo "── 9. certificates ──"
# Unconditional, and it iterates whatever is in the store rather than checking
# one known name: the store is general-purpose and outlives wstunnel. It has
# exactly one owner (60-certs.sh) and any number of consumers, so this keeps
# working as the next one registers itself.
CERT_RELOAD=/usr/local/sbin/naaf-cert-reload
if [ -d "$NAAF_CERT_DIR" ]; then
  # The modes ARE the privilege boundary, not decoration. /etc/naaf is 0750
  # root:naaf so the service group can traverse into this store, and a writable
  # directory anywhere on the path makes a 0600 key.pem irrelevant — whoever can
  # write the directory replaces the file.
  ck "store directory mode" "755" "$(stat -c %a "$NAAF_CERT_DIR" 2>/dev/null)"
  ck "store directory owner" "root:root" "$(stat -c '%U:%G' "$NAAF_CERT_DIR" 2>/dev/null)"
  # The one root-executed entry point into the store: acme.sh runs it unattended
  # from cron as --reloadcmd, with an argument that came out of a config file.
  ck "naaf-cert-reload mode" "755" "$(stat -c %a "$CERT_RELOAD" 2>/dev/null)"
  ck "naaf-cert-reload owner" "root:root" "$(stat -c '%U:%G' "$CERT_RELOAD" 2>/dev/null)"

  ncerts=0
  for d in "$NAAF_CERT_DIR"/*/; do
    [ -d "$d" ] || continue
    ncerts=$((ncerts+1))
    slug=${d%/}; slug=${slug##*/}
    ck "$slug: directory mode" "755" "$(stat -c %a "$d" 2>/dev/null)"
    ck "$slug: consumers.d mode" "755" "$(stat -c %a "$d/consumers.d" 2>/dev/null)"
    ck "$slug: key.pem mode" "600" "$(stat -c %a "$d/key.pem" 2>/dev/null)"
    ck "$slug: key.pem owner" "root:root" "$(stat -c '%U:%G' "$d/key.pem" 2>/dev/null)"
    if [ -s "$d/cert.pem" ]; then
      # A week of slack. acme.sh renews at 60 days of a 90-day life and a
      # self-signed one lives 3650 days, so anything inside 7 days means renewal
      # has been failing silently for about a month.
      ck "$slug: valid for at least another week" "yes" \
         "$(openssl x509 -in "$d/cert.pem" -noout -checkend 604800 >/dev/null 2>&1 && echo yes || echo no)"
      if [ "$NAAF_ACME_ENABLED" = "1" ]; then
        # …but only for a name a CA could ever issue. A bare-IP box has its own
        # address as the endpoint (endpoint_v4, no NAAF_ENDPOINT_HOST — the
        # documented default), 60-certs.sh adds that slug to the store and
        # correctly leaves it self-signed, and no public CA issues over DNS-01
        # for an address. Asserting CA-issued there is a FAIL that can never be
        # cleared, and deploy.sh runs this without `|| true`: every deploy on
        # that box would fail forever. Same `*[!0-9.:]*` shape test lib-certs.sh
        # uses to pick an IP: SAN over a DNS: one.
        case "$slug" in
          *[!0-9.:]*)
            # Assert the property that actually matters — does this certificate
            # chain to a publicly trusted root? — rather than issuer != subject.
            # That older test passed on a Let's Encrypt STAGING certificate,
            # because staging is a CA and its issuer differs from the subject
            # just fine. Observed on a live box: the operator follows the
            # documented "prove it on letsencrypt_test, then flip to
            # letsencrypt" path, acme.sh skips the re-issue as not-yet-due, and
            # the box keeps serving a `(STAGING)` certificate that no client can
            # validate — with this check reporting green the whole time.
            #
            # `openssl verify` against the system trust store catches the
            # self-signed fallback AND a staging certificate in one assertion,
            # and needs no list of CA name patterns to keep up to date. cert.pem
            # is a fullchain, so it supplies its own intermediates via -untrusted.
            ck "$slug: chains to a publicly trusted root" "yes" \
               "$(openssl verify -untrusted "$d/cert.pem" "$d/cert.pem" >/dev/null 2>&1 && echo yes || echo no)"
            # The CA marker lib-certs.sh writes next to the certificate. A
            # mismatch means NAAF_ACME_SERVER was changed and the re-issue has
            # not happened yet — which is a deploy away, not a broken box.
            if [ -r "$d/ca" ]; then
              ck "$slug: issued by the configured CA" "$NAAF_ACME_SERVER" "$(cat "$d/ca" 2>/dev/null)"
            fi
            ;;
          *) note "$slug: self-signed by design" "no CA issues for a bare address" ;;
        esac
      fi
    else
      no "$slug: cert.pem present and non-empty" "missing or empty"
    fi
    # A marker naming a unit that is not installed means a consumer was removed
    # or renamed: the renewal then restarts nothing, and because LoadCredential=
    # snapshots the pair at start, the old certificate stays loaded until
    # something else happens to restart it.
    for m in "$d/consumers.d"/*; do
      [ -e "$m" ] || continue   # an unmatched glob stays literal
      u=${m##*/}
      case "$u" in
        *.service | *.socket | *.target) ;;
        # naaf-cert-reload skips anything else by design, and that suffix filter
        # is the security control: without it one file named `--now` turns a
        # renewal into a root-chosen systemctl invocation. Nothing but a consumer
        # ever writes here, so a name that is not a unit is a finding, not noise.
        *) no "$slug: junk in consumers.d" "$u"; continue ;;
      esac
      ck "$slug: consumer $u is installed" "yes" \
         "$(systemctl cat -- "$u" >/dev/null 2>&1 && echo yes || echo no)"
    done
  done
  # An empty store means 60-certs.sh derived no usable name. Two ways to get
  # there and they need different fixes, so name both rather than guessing: the
  # settings row is genuinely empty (50-bringup has not run), or endpoint_host
  # holds something cert_slug refuses as a directory component — which is
  # reachable because NAAF_ENDPOINT_HOST reaches the database unvalidated.
  [ "$ncerts" -ge 1 ] ||
    note "no certificates in the store" \
         "60-certs.sh derived no usable name — check: sqlite3 $NAAF_DB 'select endpoint_host, endpoint_v4 from settings'"

  if [ "$NAAF_ACME_ENABLED" = "1" ]; then
    # acme.sh installs its own daily cron at --install time and naaf adds no
    # timer of its own, so this entry is the entire renewal mechanism. Match the
    # command and not the path: acme.sh writes the entry with the home quoted.
    ck "acme.sh renewal cron entry" "yes" \
       "$(crontab -l 2>/dev/null | grep -q 'acme.sh --cron' && echo yes || echo no)"
    # Only when present: acme.sh saves the credential into its own account.conf
    # after a first success, so a working box can legitimately have no acme.env.
    if [ -e /etc/naaf/acme.env ]; then
      # 0600 root:root, deliberately NOT litestream.env's 0640 root:naaf. That
      # one is read by litestream running as the naaf user; this one can rewrite
      # DNS and is read only by acme.sh as root, and /etc/naaf is traversable by
      # the naaf group — so the file mode is the entire barrier.
      ck "acme.env mode" "600" "$(stat -c %a /etc/naaf/acme.env 2>/dev/null)"
      ck "acme.env owner" "root:root" "$(stat -c '%U:%G' /etc/naaf/acme.env 2>/dev/null)"
    fi
  fi
else
  note "no certificate store at $NAAF_CERT_DIR" "has 60-certs.sh run?"
fi

echo
echo "── 10. key custody ──"
ck "clients table has no private-key column" "0" "$(q '.schema clients' | grep -ci 'privkey\|private_key')"
ck "no client private key in the journal" "0" \
   "$(journalctl -u naaf --no-pager 2>/dev/null | grep -c 'PrivateKey =')"
ck "server private key present (length only)" "1" \
   "$(q "select count(*) from settings where length(coalesce(server_privkey,''))>0")"
ck "config file not world-readable" "640" "$(stat -c %a "$NAAF_CONF" 2>/dev/null)"

echo
echo "═══ $pass passed, $fail failed, $warn warning(s) ═══"
[ "$fail" -eq 0 ]
