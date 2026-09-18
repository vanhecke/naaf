#!/usr/bin/env bash
# Tunnel-only SOCKS5 proxy for split clients (per-app egress via the hub).
# No-op unless NAAF_PROXY_ENABLED=1, so the step list stays constant either way.
#
# Runs after 50-bringup: the listen address is settings.server_ip from the
# database, which bootstrap only fills in at step 50. Does not steal the
# CERTS.md §9 name 70-proxy.sh (that sketch is a TLS reverse proxy).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

UNIT=/etc/systemd/system/naaf-proxy.service
: "${NAAF_PROXY_ENABLED:=1}"
: "${NAAF_PROXY_PORT:=1080}"
: "${NAAF_PROXY_USER:=naaf-proxy}"

unit_tmp=""
cleanup() {
  [ -n "$unit_tmp" ] && rm -f "$unit_tmp"
  return 0
}
trap cleanup EXIT

wait_for_admin_ui() {
  if systemctl is-active --quiet naaf; then
    log "waiting for the admin UI to listen again on :${NAAF_WEB_PORT:-8080}"
    for _ in $(seq 1 60); do
      ss -ltnH "( sport = :${NAAF_WEB_PORT:-8080} )" 2>/dev/null | grep -q . && break
      sleep 1
    done
    ss -ltnH "( sport = :${NAAF_WEB_PORT:-8080} )" 2>/dev/null | grep -q . ||
      die "naaf restarted but never bound :${NAAF_WEB_PORT:-8080} — check: journalctl -u naaf"
  fi
}

if [ "$NAAF_PROXY_ENABLED" != "1" ]; then
  log "NAAF_PROXY_ENABLED is not 1 — skipping the SOCKS5 proxy"
  systemctl disable --now naaf-proxy 2>/dev/null || true
  if [ -f "$UNIT" ]; then
    log "removing $UNIT"
    rm -f "$UNIT"
    systemctl daemon-reload
    # Apply must run so the helper deletes leftover uidrange rules. try-restart
    # is a no-op when naaf is not running.
    log "restarting naaf so apply drops proxy uid rules"
    systemctl try-restart naaf
    wait_for_admin_ui
  fi
  exit 0
fi

case "$NAAF_PROXY_PORT" in
  ''|*[!0-9]*) die "NAAF_PROXY_PORT '$NAAF_PROXY_PORT' is not numeric — check naaf.conf" ;;
esac
[ "$NAAF_PROXY_PORT" -ge 1 ] && [ "$NAAF_PROXY_PORT" -le 65535 ] ||
  die "NAAF_PROXY_PORT '$NAAF_PROXY_PORT' is out of range"

case "$NAAF_PROXY_USER" in
  ''|root|"$NAAF_USER"|*[!a-z0-9_-]*|-*)
    die "NAAF_PROXY_USER '$NAAF_PROXY_USER' is not a safe system user (must not be $NAAF_USER or root) — check naaf.conf"
    ;;
esac

SERVER_IP="$(sqlite3 "$NAAF_DB" "select server_ip from settings" 2>/dev/null || true)"
WG_IF="$(sqlite3 "$NAAF_DB" "select wg_interface from settings" 2>/dev/null || true)"
[ -n "$SERVER_IP" ] || SERVER_IP="${NAAF_SERVER_IP:-}"
[ -n "$WG_IF" ] || WG_IF="${NAAF_WG_INTERFACE:-}"
[ -n "$SERVER_IP" ] || die "no server_ip in $NAAF_DB — has 50-bringup run?"
[ -n "$WG_IF" ] || die "no wg_interface in $NAAF_DB — has 50-bringup run?"
case "$WG_IF" in
  ''|*[!a-zA-Z0-9._-]* ) die "wg_interface '$WG_IF' is not a valid iface name" ;;
esac

export DEBIAN_FRONTEND=noninteractive
if ! dpkg-query -W -f='${Status}' microsocks 2>/dev/null | grep -q 'install ok installed'; then
  log "installing microsocks"
  apt-get update
  apt-get install -y --no-install-recommends microsocks
fi
command -v microsocks >/dev/null || die "microsocks is not on PATH after install"

if ! getent passwd "$NAAF_PROXY_USER" >/dev/null; then
  log "creating system user $NAAF_PROXY_USER"
  adduser --system --no-create-home --home /nonexistent \
    --shell /usr/sbin/nologin "$NAAF_PROXY_USER"
fi

log "installing $UNIT"
unit_tmp="$(mktemp)"
# `|` as the sed delimiter, not `#`. A `#` anywhere in a replacement makes sed
# reinterpret the tail of the expression as flags.
sed -e "s|__NAAF_SERVER_IP__|$SERVER_IP|g" \
    -e "s|__NAAF_PROXY_PORT__|$NAAF_PROXY_PORT|g" \
    -e "s|__NAAF_WG_INTERFACE__|$WG_IF|g" \
    -e "s|__NAAF_PROXY_USER__|$NAAF_PROXY_USER|g" \
    "$REPO_ROOT/deploy/naaf-proxy.service" >"$unit_tmp"
grep -q '__NAAF_' "$unit_tmp" && die "unsubstituted placeholder left in the rendered naaf-proxy.service"
install -o root -g root -m 0644 "$unit_tmp" "$UNIT"

systemctl daemon-reload
systemctl enable naaf-proxy
systemctl restart naaf-proxy
systemctl --no-pager --lines=0 status naaf-proxy || true

# naaf.service reads EnvironmentFile at start; apply must see the new uid so
# exit.proxy is attached. Unconditional try-restart; wait because this is the
# last step and deploy/verify.sh runs immediately after it.
log "restarting naaf so apply attaches proxy uid rules"
systemctl try-restart naaf
wait_for_admin_ui

log "SOCKS5 proxy enabled: $SERVER_IP:$NAAF_PROXY_PORT"
