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
# actually being written and readable only by the service, and no client private
# key existing anywhere.
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
else
  note "replication disabled" "NAAF_LITESTREAM_ENABLED=$NAAF_LITESTREAM_ENABLED"
fi

echo
echo "── 8. key custody ──"
ck "clients table has no private-key column" "0" "$(q '.schema clients' | grep -ci 'privkey\|private_key')"
ck "no client private key in the journal" "0" \
   "$(journalctl -u naaf --no-pager 2>/dev/null | grep -c 'PrivateKey =')"
ck "server private key present (length only)" "1" \
   "$(q "select count(*) from settings where length(coalesce(server_privkey,''))>0")"
ck "config file not world-readable" "640" "$(stat -c %a "$NAAF_CONF" 2>/dev/null)"

echo
echo "═══ $pass passed, $fail failed, $warn warning(s) ═══"
[ "$fail" -eq 0 ]
