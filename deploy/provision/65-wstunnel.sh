#!/usr/bin/env bash
# Optional TLS-WebSocket transport in front of the WireGuard listener, for
# clients on networks that pass nothing but outbound tcp/443. No-op unless
# NAAF_WSTUNNEL_ENABLED=1, so the step list stays constant either way.
#
# Installs the pinned release tarball straight from GitHub, verified against the
# release's own checksums.txt — the same shape as 45-litestream.sh, minus the
# packaging: wstunnel publishes no apt repository and no .deb, so this adds zero
# signing keys and zero sources.list entries.
#
# Runs after 50-bringup, and after 60-certs: the certificate served here is named
# for endpoint_host || endpoint_v4 from the settings table, which bin/bootstrap.rb
# only fills in at step 50, and 60-certs is what writes the pair.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
# shellcheck source=lib-certs.sh
source "$DIR/lib-certs.sh"
require_root

BIN=/usr/local/bin/wstunnel
UNIT=/etc/systemd/system/naaf-wstunnel.service
ENV_FILE=/etc/naaf/wstunnel.env

# ONE trap, not two. `tmp` is assigned only inside the download branch below, so
# a second `trap 'rm -f "$unit_tmp"' EXIT` installed later would replace this one
# and, on every run that skips the download, dereference an unset `tmp` under
# `set -u` — the step would exit 1 after doing everything correctly and every
# subsequent deploy would then fail here. Declared empty up front and cleaned up
# by one handler that tolerates either being unused. shellcheck -S warning
# catches none of that.
tmp="" unit_tmp=""
cleanup() {
  [ -n "$tmp" ] && rm -rf "$tmp"
  [ -n "$unit_tmp" ] && rm -f "$unit_tmp"
  return 0
}
trap cleanup EXIT

if [ "$NAAF_WSTUNNEL_ENABLED" != "1" ]; then
  log "NAAF_WSTUNNEL_ENABLED is not 1 — skipping the wstunnel transport"
  # `2>/dev/null || true`, exactly as 45-litestream.sh does it: a bare
  # `disable --now` on a unit that was never installed exits non-zero, which
  # under `set -euo pipefail` would fail this step on the DEFAULT configuration.
  systemctl disable --now naaf-wstunnel 2>/dev/null || true
  if [ -f "$UNIT" ]; then
    log "removing $UNIT"
    rm -f "$UNIT"
    # Reload after REMOVING too, not only after writing — systemd keeps the unit
    # loaded until told otherwise and mentions it only as a warning on some later
    # unrelated systemctl call. That is the omission b1b366d fixed in 40-app.sh.
    # Inside the `-f` guard so the common default path does not reload every run.
    systemctl daemon-reload
  fi
  # $ENV_FILE and the certificate store are deliberately left alone. Rotating the
  # path prefix would invalidate every issued split-ws config, so a disable/enable
  # cycle keeps them working; and the store belongs to 60-certs.sh and its other
  # consumers, not to us.
  exit 0
fi

# Pinned, never resolved. 45-litestream.sh falls back to the GitHub "latest"
# endpoint when its version is blank; this one must not — silently upgrading the
# one daemon that faces the public internet is not something a deploy should do
# on its own.
VER="${NAAF_WSTUNNEL_VERSION:-10.6.2}"
[ -n "$VER" ] || die "NAAF_WSTUNNEL_VERSION is empty — pin a version, it is not resolved"

# A malformed port renders a unit that fails to start with a message that says
# nothing about where the bad value came from. Both ports land in the unit: the
# wstunnel one in the bind address, the WireGuard one in --restrict-to, where a
# wrong-but-valid value is a silent total outage (verify.sh checks that pair
# exactly, with `ck` rather than a substring match).
for p in "$NAAF_WSTUNNEL_PORT" "$NAAF_LISTEN_PORT"; do
  case "$p" in ''|*[!0-9]*) die "port '$p' is not numeric — check naaf.conf" ;; esac
done

# The release assets use Debian's amd64/arm64 spelling but armv7 where Debian
# says armhf, so this map is NOT the same as 45-litestream.sh's (which needs
# x86_64). Checked against the published v10.6.2 asset list.
case "$(dpkg --print-architecture)" in
  amd64) WSARCH=amd64 ;;
  arm64) WSARCH=arm64 ;;
  armhf) WSARCH=armv7 ;;
  *) die "no wstunnel release for architecture $(dpkg --print-architecture)" ;;
esac

# grep -w, not a bare substring: `wstunnel --version` prints `wstunnel-cli 10.6.2`
# and an unanchored match for 10.6.2 would also accept a future 10.6.20.
if [ ! -x "$BIN" ] || ! "$BIN" --version 2>/dev/null | grep -qw "$VER"; then
  base="https://github.com/erebe/wstunnel/releases/download/v$VER"
  tgz="wstunnel_${VER}_linux_$WSARCH.tar.gz"
  tmp="$(mktemp -d)"
  log "downloading $tgz"
  curl -fsSL -o "$tmp/$tgz" "$base/$tgz"
  curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
  (cd "$tmp" && grep " $tgz\$" checksums.txt | sha256sum -c -) ||
    die "checksum mismatch for $tgz — refusing to install"
  tar -xzf "$tmp/$tgz" -C "$tmp"
  # goreleaser's default archive layout puts the binary at the archive root,
  # beside LICENSE and README. Assert it rather than trusting that, so the day
  # upstream adds an `archives:` section with a wrapping directory this fails
  # here instead of installing nothing and reporting success.
  [ -f "$tmp/wstunnel" ] || die "no wstunnel binary at the root of $tgz"
  install -o root -g root -m 0755 "$tmp/wstunnel" "$BIN"
fi
# `--version` already prints the program name ("wstunnel-cli 10.6.2"), unlike
# litestream's, so this does not prefix it a second time.
log "$("$BIN" --version)"

# The path prefix acts as a shared secret — wstunnel refuses any WebSocket
# upgrade that does not carry it. It lives HERE and not in naaf.conf because
# deploy/install-config.sh iterates the incoming file only: a key present on the
# box but absent from the operator's local naaf.conf is dropped, re-appended
# empty by 40-app.sh and regenerated here, which would silently invalidate every
# split-ws config ever issued. naaf.service reads this file via
# EnvironmentFile=-/etc/naaf/wstunnel.env so ConfigBuilder sees it in ENV.
#
# Log the FACT and never the VALUE: provision.sh tees every step to a 0644 log
# under root's 022 umask, and deploy.sh tees the whole run to deploy/logs/ back
# on the workstation. 40-app.sh's session-secret generation is the model.
PREFIX=""
if [ -f "$ENV_FILE" ]; then
  PREFIX="$(sed -n 's/^NAAF_WSTUNNEL_PATH_PREFIX=//p' "$ENV_FILE" | head -1)"
fi
if [ -n "$PREFIX" ]; then
  log "$ENV_FILE already carries a path prefix — keeping it"
else
  log "generating a wstunnel path prefix into $ENV_FILE"
  PREFIX="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # umask inside a subshell so the file is never briefly world-readable and the
  # mask does not leak into the rest of the step.
  ( umask 027; printf 'NAAF_WSTUNNEL_PATH_PREFIX=%s\n' "$PREFIX" >"$ENV_FILE" )
  chown root:"$NAAF_GROUP" "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
fi

# The certificate this serves is the endpoint's, read from the settings table the
# way verify.sh reads listen_port — the DB is authoritative and the naaf.conf
# copies of these ship blank by design. 60-certs.sh derived the same name the
# same way one step ago, so the slugs agree by construction.
ENDPOINT="$(sqlite3 "$NAAF_DB" \
  "select coalesce(nullif(endpoint_host,''), nullif(endpoint_v4,''), '') from settings" 2>/dev/null || true)"
[ -n "$ENDPOINT" ] || die "no endpoint_host or endpoint_v4 in $NAAF_DB — has 50-bringup run?"
# cert_slug and cert_register report to stderr and `return 1` rather than exiting,
# so that a caller can decide — 60-certs.sh must never die. This one may, and
# should: it is the last step, the VPN is already up, and a transport enabled
# against a certificate that does not exist is a silent outage. The explicit
# `|| die` is what turns their bare non-zero into a message naming this step.
# cert_slug normalises a trailing dot, so the FQDN spelling of a name agrees with
# 60-certs.sh's slug rather than killing this step. Anything still refused here is
# a value no certificate directory can be named after — and since
# lib/naaf/bootstrap.rb writes NAAF_ENDPOINT_HOST into the settings table with no
# validation at all (the settings UI is the only validated path), that is a real
# way to arrive. 60-certs.sh will have skipped the same name, so there is no
# certificate to serve and no honest way to continue; say what the value was and
# where to change it, because "cannot derive a certificate name" alone sends the
# operator looking at this step instead of at the database.
SLUG="$(cert_slug "$ENDPOINT")" || die "cannot derive a certificate name from the endpoint '$ENDPOINT' (settings.endpoint_host).
  60-certs.sh skipped it for the same reason, so there is no certificate to serve.
  Set a plain hostname in the Settings UI, or NAAF_ENDPOINT_HOST + bin/bootstrap.rb --refresh-network,
  then re-run: ./deploy.sh --step 60-certs && ./deploy.sh --step 65-wstunnel"
CERT_PATH="$(cert_dir "$SLUG")"
[ -f "$CERT_PATH/cert.pem" ] && [ -f "$CERT_PATH/key.pem" ] ||
  die "no certificate pair under $CERT_PATH — run 60-certs.sh first"
# Register as a consumer so acme.sh's --reloadcmd restarts us on renewal. It has
# to be a restart rather than wstunnel's own file-watch: LoadCredential= snapshots
# the pair at start, so the running process never sees the new files.
cert_register "$SLUG" naaf-wstunnel.service ||
  die "could not register naaf-wstunnel.service as a consumer of $SLUG"
log "serving the certificate at $CERT_PATH"

# This step installs its own unit rather than going through 40-app.sh's loop:
# that loop is a fixed six-placeholder set shared by the two Ruby units, this one
# shares none of the six, and 40-app runs unconditionally while this unit must
# exist only while the transport is enabled.
#
# `|` as the sed delimiter, not the `#` used elsewhere. A `#` anywhere in a
# replacement makes sed reinterpret the tail of the expression as flags — it
# exits 0, writes the wrong output, and every downstream guard still reports
# success. None of these four values contains one today; the delimiter is what
# keeps that from mattering.
log "installing $UNIT"
unit_tmp="$(mktemp)"
sed -e "s|__NAAF_WSTUNNEL_PATH_PREFIX__|$PREFIX|g" \
    -e "s|__NAAF_LISTEN_PORT__|$NAAF_LISTEN_PORT|g" \
    -e "s|__NAAF_WSTUNNEL_PORT__|$NAAF_WSTUNNEL_PORT|g" \
    -e "s|__NAAF_CERT_PATH__|$CERT_PATH|g" \
    "$REPO_ROOT/deploy/naaf-wstunnel.service" >"$unit_tmp"
# The guard 20-system.sh has and 40-app.sh lacks: an unsubstituted placeholder is
# a unit that starts and forwards to the wrong place, or refuses every client.
grep -q '__NAAF_' "$unit_tmp" && die "unsubstituted placeholder left in the rendered naaf-wstunnel.service"
# 0644 is the systemd convention. The path prefix is visible in the rendered unit
# and in /proc/<pid>/cmdline regardless of the mode, which is precisely why it is
# kept out of the provisioning LOG — the log is the copy that leaves the box.
install -o root -g root -m 0644 "$unit_tmp" "$UNIT"

systemctl daemon-reload
# enable + restart, not `enable --now`: --now starts an inactive unit but leaves a
# running one on the old definition, and `--step 65-wstunnel` is exactly how you
# change this unit. wstunnel is stateless, so a restart costs live TCP sessions
# that reconnect and a WireGuard handshake that retries within 5s — the same cost
# a certificate renewal already imposes.
systemctl enable naaf-wstunnel
systemctl restart naaf-wstunnel
systemctl --no-pager --lines=0 status naaf-wstunnel || true

# naaf.service reads its EnvironmentFile once, at start, so an app that was
# already running when the prefix was written keeps emitting the stale one — and
# the half-provisioned banner it shows would be unclearable by the very action it
# tells the operator to take. Unconditional rather than only-when-newly-generated
# for that reason; try-restart is a no-op when naaf is not running. Last, so the
# app only starts offering ws flavors once the transport behind them is up.
log "restarting naaf so it picks up $ENV_FILE"
systemctl try-restart naaf

# And then WAIT for it to be serving again. systemd reports naaf `active` as soon
# as the process is exec'd, about a second before Falcon binds — and this step is
# the LAST one, so `deploy.sh` runs deploy/verify.sh immediately after it. Without
# this wait, every deploy with the transport enabled fails verification on four
# checks (both admin-UI binds, the listener count, and tunnel DNS) against a stack
# that is merely mid-restart. Observed on a real box: naaf active at 02:21:47,
# verify reporting `admin UI listener count want=2 got=0` moments later, and the
# same script passing on the same box once it settled.
#
# 50-bringup.sh:110-118 solves the identical problem for its own restart with its
# own wait_until; this is deliberately a self-contained copy rather than a shared
# helper, so a step that runs after bring-up cannot regress bring-up.
if systemctl is-active --quiet naaf; then
  log "waiting for the admin UI to listen again on :${NAAF_WEB_PORT:-8080}"
  for _ in $(seq 1 60); do
    ss -ltnH "( sport = :${NAAF_WEB_PORT:-8080} )" 2>/dev/null | grep -q . && break
    sleep 1
  done
  ss -ltnH "( sport = :${NAAF_WEB_PORT:-8080} )" 2>/dev/null | grep -q . ||
    die "naaf restarted but never bound :${NAAF_WEB_PORT:-8080} — check: journalctl -u naaf"
fi

log "wstunnel transport enabled: tcp/$NAAF_WSTUNNEL_PORT -> 127.0.0.1:$NAAF_LISTEN_PORT"
