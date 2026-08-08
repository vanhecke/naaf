#!/usr/bin/env bash
# Install Ruby with rv (https://rv.dev) — a pinned, prebuilt, checksum-verified
# tarball rather than a source compile. This step used to be the long pole of the
# whole deploy at 15-30 minutes on 1 vCPU; it is now a few seconds.
#
# Idempotent: an existing good build of the requested version is left alone.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

RV_BIN=/usr/local/bin/rv

# rv's update-mode defaults to "install": it tries to replace its own binary at
# runtime. That would silently defeat NAAF_RV_VERSION — the pin is the whole
# point — so turn it off for every invocation here. It also stops rv logging a
# self-update failure on a box where the binary was installed from the tarball
# rather than by their installer script (there is no update "receipt").
export RV_UPDATE_MODE=none

# Deliberately NOT `curl -LsSf https://rv.dev/install | sh`. That resolves to
# whatever is newest and executes it unverified, so the Ruby under a VPN control
# plane would change without anyone deciding to change it. Pin the release and
# check the digest — the same discipline as 45-litestream.sh.
install_rv() {
  local triple base tar tmp want have
  case "$(dpkg --print-architecture)" in
    amd64) triple=x86_64-unknown-linux-gnu ;;
    arm64) triple=aarch64-unknown-linux-gnu ;;
    *) die "no rv build for $(dpkg --print-architecture) — rv ships x86_64 and aarch64" ;;
  esac

  base="https://github.com/spinel-coop/rv/releases/download/v$NAAF_RV_VERSION"
  tar="rv-$triple.tar.xz"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp now, not at trap time
  trap "rm -rf '$tmp'" RETURN

  log "downloading rv $NAAF_RV_VERSION ($triple)"
  curl -fsSL -o "$tmp/$tar" "$base/$tar"
  curl -fsSL -o "$tmp/$tar.sha256" "$base/$tar.sha256"

  # The published digest is `<hash> *<file>`; compare the hash directly rather
  # than feeding that to `sha256sum -c`, whose tolerance for the binary marker
  # and trailing lines varies by implementation.
  want="$(cut -d' ' -f1 "$tmp/$tar.sha256")"
  have="$(sha256sum "$tmp/$tar" | cut -d' ' -f1)"
  [ -n "$want" ] || die "no digest published for $tar"
  [ "$want" = "$have" ] || die "rv checksum mismatch: expected $want, got $have"
  log "checksum ok"

  tar -xJf "$tmp/$tar" -C "$tmp"
  install -m 0755 "$tmp/rv-$triple/rv" "$RV_BIN"
}

if [ -x "$RV_BIN" ] && "$RV_BIN" --version 2>/dev/null | grep -qw "$NAAF_RV_VERSION"; then
  log "rv $NAAF_RV_VERSION already installed"
else
  install_rv
fi
"$RV_BIN" --version

if [ -x "$RUBY_BIN" ] && "$RUBY_BIN" -v 2>/dev/null | grep -qw "$NAAF_RUBY_VERSION"; then
  log "Ruby already installed: $("$RUBY_BIN" -v)"
else
  # --install-dir takes the PARENT directory: rv creates ruby-<version> inside
  # it, the same layout ruby-install produced, so NAAF_RUBY_PREFIX and both
  # systemd units keep working untouched.
  log "installing Ruby $NAAF_RUBY_VERSION (prebuilt)"
  "$RV_BIN" ruby install "$NAAF_RUBY_VERSION" --install-dir "$(dirname "$NAAF_RUBY_PREFIX")"
fi

[ -x "$RUBY_BIN" ] || die "expected Ruby at $RUBY_BIN after install — check NAAF_RUBY_VERSION=$NAAF_RUBY_VERSION"
"$RUBY_BIN" -v

# Make `ruby` resolve for a human who SSHes in. Replaces chruby + auto.sh, which
# existed only for this: provisioning gets the path from 00-lib.sh and the
# systemd units use absolute paths, so nothing else depended on it.
cat >/etc/profile.d/naaf-ruby.sh <<EOF
# Written by deploy/provision/30-ruby.sh. The Ruby that runs naaf.
PATH="$RUBY_PREFIX/bin:\$PATH"
EOF
log "wrote /etc/profile.d/naaf-ruby.sh ($RUBY_PREFIX/bin)"

# A box provisioned before the move to rv still has chruby's profile snippet,
# which would fight the line above for what `ruby` means in a login shell.
if [ -f /etc/profile.d/chruby.sh ]; then
  rm -f /etc/profile.d/chruby.sh
  log "removed /etc/profile.d/chruby.sh (superseded by rv)"
fi

# Ruby 4.0's `-v` only prints +YJIT when YJIT is *active*; check availability
# directly instead (the service turns it on via RUBY_YJIT_ENABLE=1).
if "$RUBY_BIN" --yjit -e 'exit(RubyVM::YJIT.enabled? ? 0 : 1)' 2>/dev/null; then
  log "YJIT available"
else
  log "WARNING: YJIT not available in this build"
fi
