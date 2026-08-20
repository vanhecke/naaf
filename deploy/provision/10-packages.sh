#!/usr/bin/env bash
# System packages: the WireGuard/nftables runtime, a compiler for native gem
# extensions, and the handful of CLI tools the app and provisioning rely on.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

export DEBIAN_FRONTEND=noninteractive

log "apt-get update && upgrade"
apt-get update
apt-get -y upgrade

# No Ruby *build* toolchain here any more — rv ships a prebuilt Ruby, so rustc
# (and the ~60 MB of libstd-rust-dev behind it), autoconf, bison and the headers
# a source build needed are gone. Gems still compile, though, and that is a
# separate requirement from building Ruby:
#
#   build-essential  bcrypt, io-event, json, racc and bigdecimal build C
#                    extensions against Ruby's own headers at `bundle install`
#   libssl-dev       the openssl gem (4.0.2 in Gemfile.lock) compiles against
#                    system OpenSSL headers. Ruby having openssl statically
#                    linked does NOT cover this — the gem is a separate build,
#                    and without this bundle install dies on `openssl/ssl.h`.
#   pkg-config       openssl's extconf.rb looks for it before falling back
#   xz-utils         30-ruby.sh unpacks rv's .tar.xz
#   sqlite3          the CLI: verify.sh, 50-bringup's bootstrap guard, ops.
#                    The sqlite3 *gem* ships precompiled per-platform, so it
#                    needs no compiler and no libsqlite3-dev.
#   openssl          60-certs.sh generates every certificate's self-signed
#                    fallback and decides on renewal with `x509 -checkend`;
#                    verify.sh re-checks expiry. The CLI is a separate package
#                    from libssl-dev above, which is only gem build headers.
#   bind9-dnsutils   `dig`, for 60-certs.sh proving the _acme-challenge CNAME
#                    delegation exists BEFORE it asks a rate-limited CA. Debian
#                    minimal ships no resolver CLI at all, and `getent hosts`
#                    can only do A/AAAA — it cannot see a CNAME or a TXT.
#   iputils-ping     the Troubleshoot page runs it as the unprivileged naaf
#   traceroute       user. Debian ships ping with cap_net_raw+ep and
#                    traceroute defaults to UDP, so neither needs root — which
#                    is the whole reason they are not helper commands. curl is
#                    the third and is already above.
log "installing packages"
apt-get install -y --no-install-recommends \
  wireguard wireguard-tools nftables sqlite3 git rsync curl ca-certificates jq \
  xz-utils build-essential pkg-config libssl-dev unattended-upgrades \
  openssl bind9-dnsutils iputils-ping traceroute

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
