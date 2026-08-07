#!/usr/bin/env bash
# Run every provisioning step in order, teeing each to its own log under
# /var/log/wgcp-provision. Safe to re-run — steps are idempotent. Needs
# WGCP_ADMIN_PASSWORD (and optionally WGCP_ENDPOINT_HOST) for the bring-up step.
# Used verbatim by the Stage-2 cloud-init path; in Stage 1 you run the steps
# one-by-one instead (see deploy/run-remote.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root
mkdir -p "$WGCP_LOG_DIR"

STEPS=(05-swap 10-packages 20-system 30-ruby 40-app 50-bringup)
for step in "${STEPS[@]}"; do
  log "=== $step ==="
  if bash "$DIR/$step.sh" 2>&1 | tee "$WGCP_LOG_DIR/$step.log"; then
    log "=== $step OK ==="
  else
    die "step $step failed — inspect $WGCP_LOG_DIR/$step.log"
  fi
done
log "provisioning complete"
