#!/usr/bin/env bash
# Drive Stage-1 provisioning from your workstation: sync the repo to the box, then
# run provisioning steps one at a time, teeing all output to a local timestamped
# log under deploy/logs/ so you can inspect each step before moving on.
#
#   run-remote.sh <ip> sync              rsync this repo -> /opt/naaf on the box
#   run-remote.sh <ip> step <NN-name>    run one step (e.g. 20-system), tee a log
#   run-remote.sh <ip> provision         run the whole provision.sh, tee a log
#   run-remote.sh <ip> exec <cmd...>     run an arbitrary remote command, tee a log
#
# Env: NAAF_SSH_KEY (optional — a specific private key file; if unset, your normal
# ssh config and agent are used). For `step 50-bringup` or `provision`:
# NAAF_ADMIN_PASSWORD (+ optional NAAF_ENDPOINT_HOST) — shipped to a root-only env
# file on the box, never placed on the remote command line.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LOGDIR="$REPO/deploy/logs"
mkdir -p "$LOGDIR"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
if [ -n "${NAAF_SSH_KEY:-}" ]; then
  # An explicit key also pins it: ignore any ssh-agent so an unattended run never
  # blocks on an agent-approval prompt (1Password and friends do this).
  SSH_OPTS+=(-o IdentitiesOnly=yes -o IdentityAgent=none -i "$NAAF_SSH_KEY")
fi
ssh_() { ssh "${SSH_OPTS[@]}" "root@$IP" "$@"; }
ts() { date -u +%Y%m%dT%H%M%SZ; }

IP="${1:?usage: run-remote.sh <ip> <sync|step|provision|exec> ...}"; shift
CMD="${1:?missing subcommand}"; shift || true

# Run a remote command, first shipping bring-up secrets to a root-only env file
# when NAAF_ADMIN_PASSWORD is set, then sourcing+removing it. Tees to $2.
run_logged() {
  local remote_cmd="$1" log="$2"
  echo "-> $remote_cmd  (log: $log)" >&2
  if [ -n "${NAAF_ADMIN_PASSWORD:-}" ]; then
    ssh_ "cat >/root/.naaf-bringup.env && chmod 600 /root/.naaf-bringup.env" <<EOF
export NAAF_ADMIN_PASSWORD=$(printf '%q' "$NAAF_ADMIN_PASSWORD")
export NAAF_ENDPOINT_HOST=$(printf '%q' "${NAAF_ENDPOINT_HOST:-}")
EOF
    ssh_ "set -a; . /root/.naaf-bringup.env; rm -f /root/.naaf-bringup.env; $remote_cmd" 2>&1 | tee "$log"
  else
    ssh_ "$remote_cmd" 2>&1 | tee "$log"
  fi
}

case "$CMD" in
  sync)
    echo "rsync $REPO -> root@$IP:/opt/naaf" >&2
    ssh_ 'mkdir -p /opt/naaf'
    rsync -az --delete \
      --exclude '.git' --exclude 'deploy/logs' --exclude '*.db' --exclude '*.db-shm' \
      --exclude '*.db-wal' --exclude '.env' \
      -e "ssh ${SSH_OPTS[*]}" "$REPO"/ "root@$IP:/opt/naaf/"
    echo "synced" >&2
    ;;
  step)
    step="${1:?which step, e.g. 20-system}"
    run_logged "bash /opt/naaf/deploy/provision/$step.sh" "$LOGDIR/$(ts)-$step.log"
    ;;
  provision)
    run_logged "bash /opt/naaf/deploy/provision/provision.sh" "$LOGDIR/$(ts)-provision.log"
    ;;
  exec)
    ssh_ "$@" 2>&1 | tee "$LOGDIR/$(ts)-exec.log"
    ;;
  *) echo "unknown subcommand: $CMD" >&2; exit 1 ;;
esac
