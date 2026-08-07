#!/usr/bin/env bash
# Bring the stack up in the one order that works: helper (creates the socket) →
# bootstrap (server keys + admin pw + endpoint host) → app (first apply writes
# /etc/wireguard/wg0.conf) → wg-quick@wg0 (creates the interface from that conf).
# Mirrors SETUP §10. Requires NAAF_ADMIN_PASSWORD; NAAF_ENDPOINT_HOST optional.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

: "${NAAF_ADMIN_PASSWORD:?set NAAF_ADMIN_PASSWORD (min 8 chars) before running 50-bringup}"
ENDPOINT_HOST="${NAAF_ENDPOINT_HOST:-}"
APP=/opt/naaf

wait_for() { # <path> <what>
  for _ in $(seq 1 60); do [ -e "$1" ] && return 0; sleep 1; done
  die "timed out waiting for $2 ($1)"
}

# True once the server keypair exists — bootstrap regenerates keys and the admin
# password, so it must run exactly once. Re-runs of this step then skip it.
already_bootstrapped() {
  [ -f /var/lib/naaf/naaf.db ] || return 1
  local n
  n="$(sqlite3 /var/lib/naaf/naaf.db "select count(*) from settings where coalesce(server_pubkey,'') != ''" 2>/dev/null || echo 0)"
  [ "$n" = "1" ]
}

log "daemon-reload"
systemctl daemon-reload

log "starting naaf-helper"
systemctl enable naaf-helper
# restart (not just --now) so unit changes take effect on a re-run; the helper is
# stateless so this only recreates the socket + its /run/naaf dir.
systemctl restart naaf-helper
wait_for /run/naaf/helper.sock "helper socket"

if already_bootstrapped; then
  log "already bootstrapped (server key present) — skipping bootstrap"
else
  log "bootstrap (keys, admin password${ENDPOINT_HOST:+, endpoint host $ENDPOINT_HOST})"
  runuser -u naaf -- env \
    NAAF_ADMIN_PASSWORD="$NAAF_ADMIN_PASSWORD" \
    NAAF_ENDPOINT_HOST="$ENDPOINT_HOST" \
    BUNDLE_GEMFILE="$APP/Gemfile" \
    HOME=/var/lib/naaf \
    PATH="$RUBY_PREFIX/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    sh -c "cd $APP && exec bundle exec ruby bin/bootstrap.rb"
fi

log "starting naaf (first apply writes wg0.conf)"
systemctl enable --now naaf
wait_for /etc/wireguard/wg0.conf "wg0.conf from first apply"

log "bringing up wg-quick@wg0"
systemctl enable --now wg-quick@wg0

# With wg0 now present, restart the app so its boot apply! succeeds cleanly
# (syncconf + nftables) instead of waiting for the 30s reconcile loop. On later
# reboots systemd already orders wg-quick@wg0 before naaf, so this is only for
# the very first bring-up.
log "restarting naaf for a clean apply on the live interface"
systemctl restart naaf

systemctl --no-pager --lines=0 status naaf-helper naaf wg-quick@wg0 || true
log "bring-up complete — admin UI on 127.0.0.1:8080 (reach via ssh -L 8080:127.0.0.1:8080)"
