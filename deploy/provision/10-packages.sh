#!/usr/bin/env bash
# System packages: WireGuard/nftables runtime, the Ruby 4.0 build toolchain, and
# the handful of CLI tools the app and provisioning rely on. Mirrors SETUP §1.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

export DEBIAN_FRONTEND=noninteractive

log "apt-get update && upgrade"
apt-get update
apt-get -y upgrade

log "installing packages"
apt-get install -y --no-install-recommends \
  wireguard wireguard-tools nftables sqlite3 git rsync curl ca-certificates jq \
  build-essential autoconf bison patch rustc libssl-dev libyaml-dev \
  libreadline-dev zlib1g-dev libncurses-dev libffi-dev libgmp-dev \
  libjemalloc-dev unattended-upgrades

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Ruby 4.0 needs OpenSSL 3.x and a recent Rust to build the JITs.
log "rustc:   $(rustc --version 2>/dev/null || echo MISSING)"
log "openssl: $(openssl version 2>/dev/null || echo MISSING)"
rust_ver="$(rustc --version 2>/dev/null | awk '{print $2}')"
if [ -n "$rust_ver" ] && [ "$(printf '%s\n1.85.0\n' "$rust_ver" | sort -V | head -1)" != "1.85.0" ]; then
  log "WARNING: rustc $rust_ver < 1.85 — the Ruby YJIT build may fail; consider rustup."
fi
