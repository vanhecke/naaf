#!/usr/bin/env bash
# Build Ruby 4.0.6 with YJIT via ruby-install (run as root → installs to
# /opt/rubies). This is the long pole (source compile + Rust). Idempotent:
# ruby-install --no-reinstall skips a good existing build. Mirrors SETUP §2.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

CHRUBY_VERSION=0.3.9

if ! command -v ruby-install >/dev/null; then
  log "installing ruby-install (resolving latest release asset)"
  cd /tmp
  # Releases ship a versioned asset (ruby-install-X.Y.Z.tar.gz); there is no
  # static /latest/download/ruby-install.tar.gz, so resolve the URL via the API.
  url="$(curl -fsSL https://api.github.com/repos/postmodern/ruby-install/releases/latest |
    jq -r '.assets[] | select(.name|test("^ruby-install-[0-9.]+\\.tar\\.gz$")) | .browser_download_url' | head -1)"
  [ -n "$url" ] || die "could not resolve the ruby-install download URL from the GitHub API"
  log "downloading $url"
  curl -fsSL -o ruby-install.tar.gz "$url"
  tar -xzf ruby-install.tar.gz
  (cd ruby-install-*/ && make install)
fi

if ! [ -f /usr/local/share/chruby/chruby.sh ]; then
  log "installing chruby $CHRUBY_VERSION"
  cd /tmp
  curl -fsSL -o chruby.tar.gz \
    "https://github.com/postmodern/chruby/archive/v${CHRUBY_VERSION}.tar.gz"
  tar -xzf chruby.tar.gz
  (cd "chruby-${CHRUBY_VERSION}/" && make install)
  cat >/etc/profile.d/chruby.sh <<'EOF'
source /usr/local/share/chruby/chruby.sh
source /usr/local/share/chruby/auto.sh
EOF
fi

if [ -x "$RUBY_BIN" ] && "$RUBY_BIN" -v 2>/dev/null | grep -q '4\.0\.6'; then
  log "Ruby already built: $("$RUBY_BIN" -v)"
else
  log "building Ruby 4.0.6 (this takes a while) …"
  ruby-install --update
  ruby-install --no-reinstall ruby 4.0.6 -- --enable-yjit --enable-zjit
fi

"$RUBY_BIN" -v
# Ruby 4.0's `-v` only prints +YJIT when YJIT is *active*; check availability
# directly instead (the service turns it on via RUBY_YJIT_ENABLE=1).
if "$RUBY_BIN" --yjit -e 'exit(RubyVM::YJIT.enabled? ? 0 : 1)' 2>/dev/null; then
  log "YJIT available"
else
  log "WARNING: YJIT not available in this build"
fi
