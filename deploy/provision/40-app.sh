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

# The one config file. It lives in /etc, deliberately outside $APP: deploy.sh
# rsyncs --delete into $APP, so anything kept there is one careless sync from
# being erased. /etc/naaf is never in the rsync blast radius.
CONF=/etc/naaf/naaf.conf
install -d -o root -g "$NAAF_GROUP" -m 0750 /etc/naaf

# Generate the session secret if it is absent or blank. This has to run for BOTH
# branches below: the common path is deploy.sh shipping a naaf.conf derived from
# naaf.conf.example, which carries NAAF_SESSION_SECRET= empty, and the app raises
# KeyError at boot without it.
ensure_session_secret() {
  local f="$1" cur
  cur="$(sed -n 's/^NAAF_SESSION_SECRET=//p' "$f" | head -1)"
  [ -n "$cur" ] && return 0
  log "generating NAAF_SESSION_SECRET"
  local secret
  secret="$("$RUBY_BIN" -rsecurerandom -e 'print SecureRandom.hex(64)')"
  if grep -q '^NAAF_SESSION_SECRET=' "$f"; then
    sed -i "s#^NAAF_SESSION_SECRET=.*#NAAF_SESSION_SECRET=$secret#" "$f"
  else
    printf 'NAAF_SESSION_SECRET=%s\n' "$secret" >>"$f"
  fi
}

# The committed example is the key list. An operator's own values arrive
# separately: deploy.sh installs their naaf.conf to $CONF before this step runs,
# which is why $CONF existing is the common case and the branch below only fills
# gaps. Running provision.sh by hand on the box is the case where it does not.
# The WORKSTATION ONLY section is stripped either way: SSH key paths and repo
# tokens have no business in the VPN server's environment, and this file is
# EnvironmentFile= for naaf.service.
SRC="$APP/naaf.conf.example"

if [ ! -f "$CONF" ]; then
  log "writing $CONF from $(basename "$SRC")"
  sed '/^# ═*.*WORKSTATION ONLY/,$d' "$SRC" >"$CONF.tmp"
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

ensure_session_secret "$CONF"

# Enforce ownership and mode every run: deploy.sh may have written the file
# before 20-system.sh created the service group, in which case it is still
# root:root and bin/bootstrap.rb (which runs as the service user) cannot read it.
chown root:"$NAAF_GROUP" "$CONF"
chmod 0640 "$CONF"

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
