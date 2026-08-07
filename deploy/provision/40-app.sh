#!/usr/bin/env bash
# App setup: .env with a generated session secret, gem install, a load-check of
# the socketry chain, and installation of both systemd units (with the Ruby path
# templated in). Assumes the repo is already present at /opt/naaf. Mirrors
# SETUP §3 + the deploy install map.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

APP=/opt/naaf
BUNDLE="$RUBY_PREFIX/bin/bundle"
export BUNDLE_GEMFILE="$APP/Gemfile"

[ -x "$RUBY_BIN" ] || die "Ruby not found at $RUBY_BIN — run 30-ruby.sh first"
[ -f "$APP/Gemfile" ] || die "repo not present at $APP — deliver the code first"

if [ ! -f "$APP/.env" ]; then
  log "writing $APP/.env with a fresh session secret"
  secret="$("$RUBY_BIN" -rsecurerandom -e 'print SecureRandom.hex(64)')"
  sed "s#^NAAF_SESSION_SECRET=.*#NAAF_SESSION_SECRET=$secret#" "$APP/.env.example" >"$APP/.env"
  chown root:root "$APP/.env"
  chmod 600 "$APP/.env"
else
  log ".env already present — leaving it"
fi

log "bundle install"
(cd "$APP" && "$BUNDLE" install)

log "load-check the socketry chain"
(cd "$APP" && "$BUNDLE" exec ruby -e \
  'require "falcon"; require "async/dns"; require "roda"; require "sequel"; require "sqlite3"; puts "load ok #{RUBY_VERSION}"')

log "installing systemd units (Ruby path -> $RUBY_BIN)"
for unit in naaf-helper.service naaf.service; do
  sed "s#/opt/rubies/ruby-4.0.6/bin/ruby#$RUBY_BIN#g" "$REPO_ROOT/deploy/$unit" \
    >"/etc/systemd/system/$unit"
done
log "units installed"
