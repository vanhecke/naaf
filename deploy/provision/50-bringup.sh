#!/usr/bin/env bash
# Bring the stack up in the one order that works: helper (creates the socket) →
# bootstrap (server keys + admin pw + endpoint host) → app (first apply writes
# the WireGuard conf) → wg-quick (creates the interface from that conf).
# NAAF_ADMIN_PASSWORD is required only on a box that has never been bootstrapped;
# NAAF_ENDPOINT_HOST is optional.
set -euo pipefail

# Capture the per-run overrides BEFORE sourcing 00-lib.sh. `set -a; . naaf.conf`
# makes the file win over the environment — the opposite of the Ruby precedence —
# so a value passed for this run only would otherwise be silently overwritten by
# a stale one in the file. NAAF_ADMIN_PASSWORD is never in the file, so the
# endpoint host is the only one that needs rescuing.
EH_OVERRIDE="${NAAF_ENDPOINT_HOST:-}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

ENDPOINT_HOST="${EH_OVERRIDE:-${NAAF_ENDPOINT_HOST:-}}"
APP="$NAAF_APP_DIR"
WG_IF="$NAAF_WG_INTERFACE"
WG_CONF="/etc/wireguard/$WG_IF.conf"

# Keep the config file the truth: an endpoint host passed for this run is written
# back, so a later re-run without it does not silently revert to the old value.
if [ -n "$ENDPOINT_HOST" ] && [ -f "$NAAF_CONF" ]; then
  if grep -q '^NAAF_ENDPOINT_HOST=' "$NAAF_CONF"; then
    sed -i "s#^NAAF_ENDPOINT_HOST=.*#NAAF_ENDPOINT_HOST=$ENDPOINT_HOST#" "$NAAF_CONF"
  else
    printf 'NAAF_ENDPOINT_HOST=%s\n' "$ENDPOINT_HOST" >>"$NAAF_CONF"
  fi
  log "recorded NAAF_ENDPOINT_HOST=$ENDPOINT_HOST in $NAAF_CONF"
fi

wait_for() { # <path> <what>
  for _ in $(seq 1 60); do [ -e "$1" ] && return 0; sleep 1; done
  die "timed out waiting for $2 ($1)"
}

# True once the server keypair exists — bootstrap regenerates keys and the admin
# password, so it must run exactly once. Re-runs of this step then skip it.
#
# This is also what makes a restore-onto-a-new-box migration work: drop a
# restored database in place before this step and bootstrap is skipped, so the
# box keeps the original server identity and every client config keeps working.
already_bootstrapped() {
  [ -f "$NAAF_DB" ] || return 1
  local n
  n="$(sqlite3 "$NAAF_DB" "select count(*) from settings where coalesce(server_pubkey,'') != ''" 2>/dev/null || echo 0)"
  [ "$n" = "1" ]
}

log "daemon-reload"
systemctl daemon-reload

log "starting naaf-helper"
systemctl enable naaf-helper
# restart (not just --now) so unit changes take effect on a re-run; the helper is
# stateless so this only recreates the socket + its run dir.
systemctl restart naaf-helper
wait_for "$NAAF_HELPER_SOCKET" "helper socket"

if already_bootstrapped; then
  log "already bootstrapped (server key present) — skipping bootstrap"
else
  # Checked here rather than at the top of the script so that re-running a deploy
  # against a live box needs no secret at all. The password is only ever consumed
  # by the one-time bootstrap below.
  : "${NAAF_ADMIN_PASSWORD:?set NAAF_ADMIN_PASSWORD (min 8 chars) — this box has never been bootstrapped}"
  log "bootstrap (keys, admin password${ENDPOINT_HOST:+, endpoint host $ENDPOINT_HOST})"
  # runuser scrubs the environment, so NAAF_CONF has to be passed explicitly or
  # bootstrap would not find the config file to seed from.
  runuser -u "$NAAF_USER" -- env \
    NAAF_ADMIN_PASSWORD="$NAAF_ADMIN_PASSWORD" \
    NAAF_ENDPOINT_HOST="$ENDPOINT_HOST" \
    NAAF_CONF="$NAAF_CONF" \
    BUNDLE_GEMFILE="$APP/Gemfile" \
    HOME="$NAAF_STATE_DIR" \
    PATH="$RUBY_PREFIX/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    sh -c "cd $APP && exec bundle exec ruby bin/bootstrap.rb"
fi

log "starting naaf (first apply writes $WG_CONF)"
systemctl enable --now naaf
wait_for "$WG_CONF" "$WG_IF.conf from first apply"

log "bringing up wg-quick@$WG_IF"
systemctl enable --now "wg-quick@$WG_IF"

# With the interface now present, restart the app so its boot apply! succeeds
# cleanly (syncconf + nftables) instead of waiting for the reconcile loop. On
# later reboots systemd already orders wg-quick before naaf, so this is only for
# the very first bring-up.
log "restarting naaf for a clean apply on the live interface"
systemctl restart naaf

systemctl --no-pager --lines=0 status naaf-helper naaf "wg-quick@$WG_IF" || true
log "bring-up complete — admin UI on 127.0.0.1:${NAAF_WEB_PORT:-8080} (reach via ssh -L 8080:127.0.0.1:8080)"
