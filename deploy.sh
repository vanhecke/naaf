#!/usr/bin/env bash
# Deploy Naaf. One command, one config file (naaf.conf).
#
#   ./deploy.sh                  deploy to NAAF_SSH_HOST from naaf.conf
#   ./deploy.sh <host>           deploy to that host instead
#   ./deploy.sh --create         create the box first (NAAF_PROVIDER), then deploy
#
# A deploy is: create the box (only with --create) -> point DNS at it (only if
# NAAF_DNS_PROVIDER is set) -> push the code and the config -> run every
# provisioning step -> verify. It is idempotent: run it again after changing
# naaf.conf, or against a half-finished box, and it picks up where it left off.
#
# Escape hatches for when something goes wrong, same script and same config:
#   ./deploy.sh --update [host]        push code + restart, no provisioning
#   ./deploy.sh --verify [host]        re-run the post-deploy checks
#   ./deploy.sh --step 30-ruby [host]  re-run a single provisioning step
#   ./deploy.sh --ssh [host] -- <cmd>  run a command on the box
#
# The admin password is asked for interactively on a first deploy and shipped to
# a root-only file the box deletes in the same command, so it never reaches a
# remote command line, `ps`, or a log. Set NAAF_ADMIN_PASSWORD to skip the
# prompt. On a box that is already bootstrapped it is not needed at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="$HERE/deploy/logs"

# Every provisioning step, in the one order that works. 45-litestream runs before
# 50-bringup so replication is already up when the database gets its server key.
STEPS=(05-swap 10-packages 20-system 30-ruby 40-app 45-litestream 50-bringup)

usage() {
  cat <<'EOF'
Deploy Naaf. One command, one config file (naaf.conf).

  ./deploy.sh                  deploy to NAAF_SSH_HOST from naaf.conf
  ./deploy.sh <host>           deploy to that host instead
  ./deploy.sh --create         create the box first (NAAF_PROVIDER), then deploy

A deploy is: create the box (only with --create) -> point DNS at it (only if
NAAF_DNS_PROVIDER is set) -> push the code and the config -> run every
provisioning step -> verify. It is idempotent: run it again after changing
naaf.conf, or against a half-finished box, and it picks up where it left off.

Escape hatches for when something goes wrong, same script and same config:

  ./deploy.sh --update [host]        push code + restart, no provisioning
  ./deploy.sh --verify [host]        re-run the post-deploy checks
  ./deploy.sh --sync [host]          push code + config only, run nothing
  ./deploy.sh --step 30-ruby [host]  re-run a single provisioning step
  ./deploy.sh --ssh [host] -- <cmd>  run a command on the box

--sync plus --step is how you restore a database onto a fresh box before it
generates its own identity; see docs/BACKUP.md.
EOF
}
log()   { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
info()  { printf '    %s\n' "$*" >&2; }
die()   { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ts()    { date -u +%Y%m%dT%H%M%SZ; }

ACTION=deploy
CREATE=0
STEP=""
HOST=""
CMD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --create) CREATE=1 ;;
    --update) ACTION=update ;;
    --verify) ACTION=verify ;;
    --sync)   ACTION=sync ;;
    --ssh)    ACTION=ssh ;;
    --step)   ACTION=step; STEP="${2:?--step needs a step name, e.g. 30-ruby}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; CMD=("$@"); break ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  [ -z "$HOST" ] || die "unexpected argument: $1"; HOST="$1" ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────────── config
if [ ! -f "$HERE/naaf.conf" ]; then
  cat >&2 <<EOF
No naaf.conf here. It is the one file you edit before deploying:

    cp naaf.conf.example naaf.conf
    \$EDITOR naaf.conf        # set NAAF_SSH_HOST, and NAAF_ENDPOINT_HOST if you have a name

Then re-run this. The defaults in naaf.conf.example are a working deployment on
their own — you only need to say which box to deploy to.
EOF
  exit 1
fi
set -a
# shellcheck source=/dev/null
. "$HERE/naaf.conf"
set +a
: "${NAAF_SSH_USER:=root}"
: "${NAAF_APP_DIR:=/opt/naaf}"
: "${NAAF_GROUP:=naaf}"
: "${NAAF_DB:=/var/lib/naaf/naaf.db}"
: "${NAAF_WEB_PORT:=8080}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "${NAAF_SSH_KEY:-}" ]; then
  # An explicit key also pins it: ignore any ssh-agent so an unattended run never
  # blocks on an agent-approval prompt (password-manager agents do this).
  SSH_OPTS+=(-o IdentitiesOnly=yes -o IdentityAgent=none -i "$NAAF_SSH_KEY")
fi
ssh_() { ssh "${SSH_OPTS[@]}" "$NAAF_SSH_USER@$HOST" "$@"; }

for c in ssh rsync; do
  command -v "$c" >/dev/null || die "$c is required on this machine"
done

# ──────────────────────────────────────────────────────────── box creation
# Provider contract: deploy/providers/<name>/create-box.sh prints the new box's
# IP address on stdout and nothing else. Everything downstream works against a
# bare IP, so that one line is the whole integration surface.
create_box() {
  local p="${NAAF_PROVIDER:-}"
  [ -n "$p" ] || die "--create needs NAAF_PROVIDER in naaf.conf (e.g. vultr; see deploy/providers/)"
  local script="$HERE/deploy/providers/$p/create-box.sh"
  [ -x "$script" ] || die "no create-box.sh for provider '$p' at $script"
  log "creating a box with provider '$p'"
  HOST="$("$script")"
  [ -n "$HOST" ] || die "provider '$p' did not print an IP address"
  info "box is $HOST"
}

wait_for_ssh() {
  log "waiting for SSH on $HOST"
  local i
  for i in $(seq 1 60); do
    if ssh_ -o BatchMode=yes true 2>/dev/null; then info "reachable after ${i}0s"; return 0; fi
    sleep 10
  done
  die "no SSH on $HOST after 10 minutes"
}

point_dns() {
  local p="${NAAF_DNS_PROVIDER:-}"
  [ -n "$p" ] || return 0
  local script="$HERE/deploy/providers/$p/update-record.sh"
  [ -x "$script" ] || die "no update-record.sh for DNS provider '$p' at $script"
  log "pointing DNS at $HOST with provider '$p'"
  "$script" "$HOST"
}

# ────────────────────────────────────────────────────────── admin password
# Only a first deploy needs it: 50-bringup.sh skips bootstrap once the server
# keypair exists, which is also what makes restore-onto-a-new-box work.
remote_is_bootstrapped() {
  ssh_ "sqlite3 '$NAAF_DB' \"select count(*) from settings where coalesce(server_pubkey,'') != ''\" 2>/dev/null" \
    2>/dev/null | grep -qx 1
}

ensure_admin_password() {
  [ -z "${NAAF_ADMIN_PASSWORD:-}" ] || return 0
  if remote_is_bootstrapped; then
    info "already bootstrapped — no admin password needed"
    return 0
  fi
  [ -t 0 ] || die "first deploy needs an admin password: set NAAF_ADMIN_PASSWORD or run interactively"
  log "admin password for the web UI (first deploy only)"
  info "stored as a bcrypt hash in the database; the plaintext is kept nowhere"
  local a b
  read -rsp "    password: " a; echo >&2
  read -rsp "    again:    " b; echo >&2
  [ -n "$a" ] || die "empty password"
  [ "$a" = "$b" ] || die "passwords do not match"
  [ "${#a}" -ge 8 ] || die "use at least 8 characters"
  NAAF_ADMIN_PASSWORD="$a"
  export NAAF_ADMIN_PASSWORD
}

# ──────────────────────────────────────────────────────────── code + config
# naaf.conf is installed to /etc/naaf rather than $NAAF_APP_DIR because the rsync
# below is --delete: anything kept in the app directory is one sync away from
# being erased, and this file carries the session secret.
install_config() {
  info "naaf.conf -> $NAAF_SSH_USER@$HOST:/etc/naaf/naaf.conf"
  # Everything below the WORKSTATION ONLY marker stays here: SSH key paths and
  # provider tokens have no business in the VPN server's environment, and this
  # file is EnvironmentFile= for naaf.service.
  #
  # `sync` normally runs before 20-system.sh has created the service group, so the
  # group is applied only if it already exists; 40-app.sh enforces the final
  # ownership either way. Root-only in the meantime is the safe direction.
  sed '/^# ═*.*WORKSTATION ONLY/,$d' "$HERE/naaf.conf" |
    ssh_ "install -d -o root -g root -m 0750 /etc/naaf &&
          cat >/etc/naaf/naaf.conf.tmp &&
          chmod 0640 /etc/naaf/naaf.conf.tmp &&
          if getent group $NAAF_GROUP >/dev/null 2>&1; then
            chown root:$NAAF_GROUP /etc/naaf/naaf.conf.tmp
          else
            chown root:root /etc/naaf/naaf.conf.tmp
          fi &&
          mv /etc/naaf/naaf.conf.tmp /etc/naaf/naaf.conf"
}

sync_code() {
  log "syncing $HERE -> $NAAF_SSH_USER@$HOST:$NAAF_APP_DIR"
  ssh_ "mkdir -p $NAAF_APP_DIR"
  rsync -az --delete \
    --exclude '.git' --exclude 'deploy/logs' --exclude '*.db' --exclude '*.db-shm' \
    --exclude '*.db-wal' --exclude 'naaf.conf' \
    -e "ssh ${SSH_OPTS[*]}" "$HERE"/ "$NAAF_SSH_USER@$HOST:$NAAF_APP_DIR/"
  install_config
}

# Run a remote command, first shipping the run's secrets to a root-only env file
# that is sourced and deleted in the same command, so they never land on a remote
# command line where `ps` and the shell history would see them, and never sit on
# the box's disk after the run.
#
# These are deliberately NOT in naaf.conf: that file is EnvironmentFile= for
# naaf.service, so anything in it becomes an environment variable of the
# tunnel-facing web app. The object-store keys go on to /etc/naaf/litestream.env
# (root:naaf 0640, read only by litestream) via 45-litestream.sh; the admin
# password is consumed once and only its bcrypt hash survives.
run_remote() {
  local remote_cmd="$1" logfile="$2"
  mkdir -p "$LOGDIR"
  if [ -n "${NAAF_ADMIN_PASSWORD:-}${NAAF_LITESTREAM_ACCESS_KEY_ID:-}" ]; then
    ssh_ "cat >/root/.naaf-deploy.env && chmod 600 /root/.naaf-deploy.env" <<EOF
export NAAF_ADMIN_PASSWORD=$(printf '%q' "${NAAF_ADMIN_PASSWORD:-}")
export NAAF_ENDPOINT_HOST=$(printf '%q' "${NAAF_ENDPOINT_HOST:-}")
export NAAF_LITESTREAM_ACCESS_KEY_ID=$(printf '%q' "${NAAF_LITESTREAM_ACCESS_KEY_ID:-}")
export NAAF_LITESTREAM_SECRET_ACCESS_KEY=$(printf '%q' "${NAAF_LITESTREAM_SECRET_ACCESS_KEY:-}")
EOF
    ssh_ "set -a; . /root/.naaf-deploy.env; rm -f /root/.naaf-deploy.env; $remote_cmd" 2>&1 | tee "$logfile"
  else
    ssh_ "$remote_cmd" 2>&1 | tee "$logfile"
  fi
}

verify() {
  log "verifying"
  # Not piped through tee: the exit status has to survive so a failed deploy
  # fails the command.
  ssh_ "bash $NAAF_APP_DIR/deploy/verify.sh"
}

summary() {
  local mins=$(((SECONDS + 30) / 60))
  log "done in ~${mins}m"
  cat >&2 <<EOF
    Admin UI is bound to the tunnel and to loopback, never to a public address,
    so reach it over an SSH forward until you have a client:

        ssh ${NAAF_SSH_KEY:+-i $NAAF_SSH_KEY }-L $NAAF_WEB_PORT:127.0.0.1:$NAAF_WEB_PORT $NAAF_SSH_USER@$HOST
        open http://localhost:$NAAF_WEB_PORT

    Add a client there, scan the QR, and you are on the tunnel.
EOF
  if [ -z "${NAAF_ENDPOINT_HOST:-}" ]; then
    cat >&2 <<EOF

    NAAF_ENDPOINT_HOST is unset, so client configs dial $HOST directly and are
    pinned to this box. Set it to a name you control and re-deploy if you want to
    be able to migrate by repointing DNS.
EOF
  fi
}

# ─────────────────────────────────────────────────────────────────── actions
if [ "$CREATE" = 1 ]; then
  [ -z "$HOST" ] || die "--create makes a new box; do not also pass a host"
  [ "$ACTION" = deploy ] || die "--create only makes sense with a full deploy"
  create_box
  wait_for_ssh
  point_dns
  # A name pointed at the box is only useful if clients dial it. Filling this in
  # from the DNS settings is the difference between a box you can migrate off and
  # one every client is pinned to.
  if [ -z "${NAAF_ENDPOINT_HOST:-}" ] && [ -n "${NAAF_DNS_NAME:-}" ] && [ -n "${NAAF_DNS_ZONE:-}" ]; then
    export NAAF_ENDPOINT_HOST="$NAAF_DNS_NAME.$NAAF_DNS_ZONE"
    info "clients will dial $NAAF_ENDPOINT_HOST (from NAAF_DNS_NAME + NAAF_DNS_ZONE)"
  fi
fi

HOST="${HOST:-${NAAF_SSH_HOST:-}}"
[ -n "$HOST" ] || die "no host — pass one, set NAAF_SSH_HOST in naaf.conf, or use --create"

case "$ACTION" in
  deploy)
    ensure_admin_password
    sync_code
    log "provisioning $HOST — ${#STEPS[@]} steps"
    info "Ruby ${NAAF_RUBY_VERSION:-4.0.6} compiles from source: expect 15-30 minutes on 1 vCPU"
    info "per-step logs land in /var/log/naaf-provision/ on the box"
    run_remote "bash $NAAF_APP_DIR/deploy/provision/provision.sh" "$LOGDIR/$(ts)-deploy.log"
    verify
    summary
    ;;
  sync)
    # Deliberately runs nothing afterwards. This is the first move of a restore
    # onto a fresh box, where the database has to be in place before 50-bringup
    # so the box keeps the original server identity (docs/BACKUP.md).
    sync_code
    ;;
  update)
    # Code only. Provisioning is skipped, so this is the fast path for a change
    # to the app itself. The helper is restarted too because it is cheap and
    # stateless, and forgetting it after a bin/naaf-helper change is the classic
    # way to spend ten minutes debugging a stale socket.
    sync_code
    log "restarting"
    ssh_ "systemctl restart naaf-helper naaf && systemctl --no-pager --lines=0 status naaf"
    ;;
  verify)
    verify
    ;;
  step)
    printf '%s\n' "${STEPS[@]}" | grep -qx "$STEP" ||
      die "unknown step '$STEP' — one of: ${STEPS[*]}"
    # Only bring-up needs the password, and only on a box that has never been
    # bootstrapped — no reason to prompt before re-running the Ruby build.
    if [ "$STEP" = 50-bringup ]; then ensure_admin_password; fi
    run_remote "bash $NAAF_APP_DIR/deploy/provision/$STEP.sh" "$LOGDIR/$(ts)-$STEP.log"
    ;;
  ssh)
    [ "${#CMD[@]}" -gt 0 ] || die "usage: ./deploy.sh --ssh [host] -- <command...>"
    ssh_ "${CMD[@]}"
    ;;
esac
