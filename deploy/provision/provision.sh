#!/usr/bin/env bash
# Run every provisioning step in order, teeing each to its own log under
# /var/log/naaf-provision. Safe to re-run — steps are idempotent.
#
# This is what `./deploy.sh` runs on the box once the code is in place. Running
# it here by hand is the same deploy minus the sync, which is occasionally what
# you want when you are already on the box. A box that has never been
# bootstrapped needs NAAF_ADMIN_PASSWORD in the environment (optionally
# NAAF_ENDPOINT_HOST too); one that has been needs neither.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-run overrides have to survive 00-lib.sh sourcing naaf.conf. `set -a; . file`
# makes the FILE win over the environment, so a value passed for this run only is
# replaced by the (usually blank) one in the file before any step runs — and the
# steps inherit THIS shell's environment, so 50-bringup.sh capturing it before its
# own source is too late. NAAF_ADMIN_PASSWORD is never in the file, so the
# endpoint host is the only one that needs rescuing.
EH_OVERRIDE="${NAAF_ENDPOINT_HOST:-}"

# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

if [ -n "$EH_OVERRIDE" ]; then export NAAF_ENDPOINT_HOST="$EH_OVERRIDE"; fi
mkdir -p "$NAAF_LOG_DIR"

# 45-litestream runs before 50-bringup so replication is already up when the
# database gets its server key — you want the very first meaningful write
# replicated, not the second. It is a no-op when replication is disabled.
STEPS=(05-swap 10-packages 20-system 30-ruby 40-app 45-litestream 50-bringup)
for step in "${STEPS[@]}"; do
  log "=== $step ==="
  if bash "$DIR/$step.sh" 2>&1 | tee "$NAAF_LOG_DIR/$step.log"; then
    log "=== $step OK ==="
  else
    die "step $step failed — inspect $NAAF_LOG_DIR/$step.log"
  fi
done
log "provisioning complete"
