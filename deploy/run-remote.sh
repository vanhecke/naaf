#!/usr/bin/env bash
# Drive provisioning from your workstation against any Debian 13 box you can
# reach over SSH. Syncs the repo, then runs provisioning steps one at a time,
# teeing all output to a local timestamped log under deploy/logs/ so you can
# inspect each step before moving on.
#
#   run-remote.sh <ip> sync              rsync this repo -> the box, install naaf.conf
#   run-remote.sh <ip> config            install naaf.conf only (no code sync)
#   run-remote.sh <ip> step <NN-name>    run one step (e.g. 20-system), tee a log
#   run-remote.sh <ip> provision         run the whole provision.sh, tee a log
#   run-remote.sh <ip> exec <cmd...>     run an arbitrary remote command, tee a log
#
# Env: NAAF_SSH_KEY (optional — a specific private key; unset uses your normal ssh
# config and agent), NAAF_SSH_USER (default root). For `step 50-bringup` or
# `provision`: NAAF_ADMIN_PASSWORD (+ optional NAAF_ENDPOINT_HOST) — shipped to a
# root-only file on the box and deleted in the same command, never placed on the
# remote command line where it would show up in `ps` and in shell history.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LOGDIR="$REPO/deploy/logs"
mkdir -p "$LOGDIR"

# Read the workstation-side settings out of the same one config file.
[ -f "$REPO/naaf.conf" ] && { set -a; . "$REPO/naaf.conf"; set +a; }
: "${NAAF_SSH_USER:=root}"
: "${NAAF_APP_DIR:=/opt/naaf}"
: "${NAAF_GROUP:=naaf}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
if [ -n "${NAAF_SSH_KEY:-}" ]; then
  # An explicit key also pins it: ignore any ssh-agent so an unattended run never
  # blocks on an agent-approval prompt (password-manager agents do this).
  SSH_OPTS+=(-o IdentitiesOnly=yes -o IdentityAgent=none -i "$NAAF_SSH_KEY")
fi
ssh_() { ssh "${SSH_OPTS[@]}" "$NAAF_SSH_USER@$IP" "$@"; }
ts() { date -u +%Y%m%dT%H%M%SZ; }

IP="${1:?usage: run-remote.sh <ip> <sync|config|step|provision|exec> ...}"; shift
CMD="${1:?missing subcommand}"; shift || true

# Everything below the WORKSTATION ONLY marker stays on your machine: SSH key
# paths and repo tokens have no business in the VPN server's environment, and
# /etc/naaf/naaf.conf is EnvironmentFile= for naaf.service.
install_config() {
  if [ ! -f "$REPO/naaf.conf" ]; then
    echo "no naaf.conf here — the box will use naaf.conf.example defaults" >&2
    echo "  (cp naaf.conf.example naaf.conf and edit it to change that)" >&2
    return 0
  fi
  echo "installing naaf.conf -> $NAAF_SSH_USER@$IP:/etc/naaf/naaf.conf" >&2
  sed '/^# ═*.*WORKSTATION ONLY/,$d' "$REPO/naaf.conf" |
    ssh_ "install -d -o root -g $NAAF_GROUP -m 0750 /etc/naaf &&
          cat >/etc/naaf/naaf.conf.tmp &&
          chown root:$NAAF_GROUP /etc/naaf/naaf.conf.tmp &&
          chmod 0640 /etc/naaf/naaf.conf.tmp &&
          mv /etc/naaf/naaf.conf.tmp /etc/naaf/naaf.conf"
}

# Run a remote command, first shipping bring-up secrets to a root-only env file
# when NAAF_ADMIN_PASSWORD is set, then sourcing and removing it. Tees to $2.
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
    echo "rsync $REPO -> $NAAF_SSH_USER@$IP:$NAAF_APP_DIR" >&2
    ssh_ "mkdir -p $NAAF_APP_DIR"
    # naaf.conf is excluded and installed separately to /etc/naaf: $NAAF_APP_DIR
    # is 0755 root:root, so a config holding the session secret must not live
    # there. It is also outside the --delete blast radius in /etc.
    rsync -az --delete \
      --exclude '.git' --exclude 'deploy/logs' --exclude '*.db' --exclude '*.db-shm' \
      --exclude '*.db-wal' --exclude 'naaf.conf' \
      -e "ssh ${SSH_OPTS[*]}" "$REPO"/ "$NAAF_SSH_USER@$IP:$NAAF_APP_DIR/"
    install_config
    echo "synced" >&2
    ;;
  config)
    install_config
    ;;
  step)
    step="${1:?which step, e.g. 20-system}"
    run_logged "bash $NAAF_APP_DIR/deploy/provision/$step.sh" "$LOGDIR/$(ts)-$step.log"
    ;;
  provision)
    run_logged "bash $NAAF_APP_DIR/deploy/provision/provision.sh" "$LOGDIR/$(ts)-provision.log"
    ;;
  exec)
    ssh_ "$@" 2>&1 | tee "$LOGDIR/$(ts)-exec.log"
    ;;
  *) echo "unknown subcommand: $CMD" >&2; exit 1 ;;
esac
