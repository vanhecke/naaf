#!/usr/bin/env bash
# Ensure swap exists. This originally guarded a from-source Ruby build, which is
# gone now that rv ships prebuilt binaries; it stays because a 1-2 GB box running
# a compile-free deploy still benefits from headroom, and swap is cheap.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

SIZE_GB="${NAAF_SWAP_GB:-2}"

if [ "$(swapon --show --noheadings | wc -l)" -gt 0 ]; then
  log "swap already active — skipping"
elif [ -f /swapfile ]; then
  log "/swapfile present but inactive — enabling"
  swapon /swapfile
else
  log "creating ${SIZE_GB}G /swapfile"
  fallocate -l "${SIZE_GB}G" /swapfile 2>/dev/null ||
    dd if=/dev/zero of=/swapfile bs=1M count=$((SIZE_GB * 1024)) status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

swapon --show
free -h
