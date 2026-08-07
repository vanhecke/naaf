#!/usr/bin/env bash
# App setup: /etc/naaf/naaf.conf with a generated session secret, gem install, a
# load-check of the socketry chain, and installation of both systemd units (with
# paths templated in from the config). Assumes the repo is already present.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

APP="$NAAF_APP_DIR"
BUNDLE="$RUBY_PREFIX/bin/bundle"
export BUNDLE_GEMFILE="$APP/Gemfile"

[ -x "$RUBY_BIN" ] || die "Ruby not found at $RUBY_BIN — run 30-ruby.sh first"
[ -f "$APP/Gemfile" ] || die "repo not present at $APP — deliver the code first"

# The one config file. It lives in /etc, deliberately outside $APP: run-remote.sh
# rsyncs --delete into $APP, so anything kept there is one careless sync from
# being erased. /etc/naaf is never in the rsync blast radius.
CONF=/etc/naaf/naaf.conf
install -d -o root -g "$NAAF_GROUP" -m 0750 /etc/naaf

# The committed example is the key list. An operator's own values arrive
# separately — `run-remote.sh <ip> config`, or cloud-init writing the file — which
# is why $CONF existing is the common case and the branch below only fills gaps.
# The WORKSTATION ONLY section is stripped either way: SSH key paths and repo
# tokens have no business in the VPN server's environment, and this file is
# EnvironmentFile= for naaf.service.
SRC="$APP/naaf.conf.example"

if [ ! -f "$CONF" ]; then
  log "writing $CONF from $(basename "$SRC") with a fresh session secret"
  secret="$("$RUBY_BIN" -rsecurerandom -e 'print SecureRandom.hex(64)')"
  sed '/^# ═*.*WORKSTATION ONLY/,$d' "$SRC" |
    sed "s#^NAAF_SESSION_SECRET=.*#NAAF_SESSION_SECRET=$secret#" >"$CONF.tmp"
  chown root:"$NAAF_GROUP" "$CONF.tmp"
  chmod 0640 "$CONF.tmp"
  mv "$CONF.tmp" "$CONF"
else
  # A release may add keys. Append the missing ones; never overwrite a value the
  # operator set. Without this, a new key silently leaves live boxes on the
  # compiled-in default with no way to see that from the config file.
  log "$CONF present — adding any keys new in this release"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"
    [ "$k" = NAAF_SESSION_SECRET ] && continue
    grep -q "^$k=" "$CONF" || { log "  + $k"; printf '%s\n' "$line" >>"$CONF"; }
  done < <(sed '/^# ═*.*WORKSTATION ONLY/,$d' "$SRC")
fi

log "bundle install"
(cd "$APP" && "$BUNDLE" install)

log "load-check the socketry chain"
(cd "$APP" && "$BUNDLE" exec ruby -e \
  'require "falcon"; require "async/dns"; require "roda"; require "sequel"; require "sqlite3"; puts "load ok #{RUBY_VERSION}"')

log "installing systemd units (Ruby path -> $RUBY_BIN)"
for unit in naaf-helper.service naaf.service; do
  sed -e "s#__NAAF_RUBY_BIN__#$RUBY_BIN#g" \
      -e "s#__NAAF_APP_DIR__#$NAAF_APP_DIR#g" \
      -e "s#__NAAF_STATE_DIR__#$NAAF_STATE_DIR#g" \
      -e "s#__NAAF_USER__#$NAAF_USER#g" \
      -e "s#__NAAF_GROUP__#$NAAF_GROUP#g" \
      -e "s#__NAAF_WG_INTERFACE__#$NAAF_WG_INTERFACE#g" \
      "$REPO_ROOT/deploy/$unit" >"/etc/systemd/system/$unit"
done
log "units installed"
