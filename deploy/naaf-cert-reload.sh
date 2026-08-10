#!/usr/bin/env bash
# Restart every consumer registered against one certificate. Installed by
# 60-certs.sh as /usr/local/sbin/naaf-cert-reload (0755 root:root) and invoked
# as acme.sh's --reloadcmd after a renewal:
#
#   /usr/local/sbin/naaf-cert-reload vpn.example.com
#
# The .sh suffix exists only in the repo, so bin/ci's `deploy/*.sh` shellcheck
# glob lints this file; it is installed without one because it is a command.
#
# THIS RUNS AS ROOT, unattended, from cron, with an argument that came out of a
# config file acme.sh wrote — so it trusts nothing. It re-validates its own $1
# with the same shape check that minted the slug in the first place, and it
# treats the contents of consumers.d/ as untrusted names rather than as a list
# of things to hand to systemctl: without the suffix filter and the `--`, one
# file named `--now` turns a certificate renewal into a root-chosen systemctl
# invocation.
#
# Deliberately self-contained — it does not source deploy/provision/lib-certs.sh
# even though the shape check is duplicated there. This must keep working while
# /opt/naaf is mid-rsync, and it is the one root entry point into the store, so
# re-validating locally is the point rather than a redundancy.
set -euo pipefail

log() { printf '[%s] naaf-cert-reload: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'naaf-cert-reload: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ "$#" -eq 1 ] || die "usage: naaf-cert-reload <slug>"

slug="$1"
# Same validation as cert_slug in deploy/provision/lib-certs.sh: shape, not just
# the character set. `.` and `..` are made entirely of allowed characters and
# would resolve to the store root and to /etc/naaf.
case "$slug" in
  "" | . | ..) die "refusing the degenerate slug '$slug'" ;;
  */*) die "'$slug' contains a path separator" ;;
  .*) die "'$slug' starts with a dot" ;;
  *..*) die "'$slug' contains '..'" ;;
  *[!A-Za-z0-9._-]*) die "'$slug' has a character with no place in a path" ;;
esac
case "$slug" in
  [A-Za-z0-9_] | [A-Za-z0-9_]*[A-Za-z0-9_]) ;;
  *) die "'$slug' does not begin and end with an alphanumeric" ;;
esac

# acme.sh's cron inherits none of the provisioning environment, so the store
# location is read out of naaf.conf when it is not already set. Read with sed
# rather than sourced (the 40-app.sh:30 idiom): nothing in this script should be
# able to execute a line of a config file, however well-owned that file is.
CERT_DIR="${NAAF_CERT_DIR:-}"
if [ -z "$CERT_DIR" ] && [ -r /etc/naaf/naaf.conf ]; then
  CERT_DIR="$(sed -n 's/^NAAF_CERT_DIR=//p' /etc/naaf/naaf.conf | head -1)"
fi
CERT_DIR="${CERT_DIR:-/etc/naaf/certs}"
# The grammar allows a quoted value; a path containing a quote is not a thing.
CERT_DIR="${CERT_DIR//[\"\']/}"
case "$CERT_DIR" in /*) ;; *) die "NAAF_CERT_DIR is not an absolute path" ;; esac

dir="$CERT_DIR/$slug"
[ -d "$dir" ] || die "no certificate at $dir"

# Renewal rewrites both files. acme.sh copies with `cat >file`, which preserves
# an existing mode, but a store rebuilt by hand or a first install under root's
# 022 umask would leave key.pem world-readable — and this is the one place that
# runs after every renewal, attended or not, so it is where the modes get
# re-pinned rather than assumed.
chown root:root "$dir/cert.pem" "$dir/key.pem" 2>/dev/null || true
chmod 0644 "$dir/cert.pem" 2>/dev/null || true
chmod 0600 "$dir/key.pem" 2>/dev/null || true

failed=0
found=0
for marker in "$dir/consumers.d"/*; do
  [ -e "$marker" ] || continue   # an unmatched glob stays literal
  unit="${marker##*/}"
  case "$unit" in
    # The suffix filter IS the security control. Anything else in this directory
    # is not a unit name and must never reach the command line.
    *.service | *.socket | *.target) ;;
    *) log "ignoring $unit — not a .service, .socket or .target"; continue ;;
  esac
  case "$unit" in
    *[!A-Za-z0-9@._-]*) log "ignoring $unit — not a usable unit name"; continue ;;
  esac
  found=$((found + 1))
  # A consumer that has been turned off leaves its marker behind (the store is
  # not wstunnel's to prune), and a stale marker must not make every future
  # renewal report failure.
  if ! systemctl cat -- "$unit" >/dev/null 2>&1; then
    log "$unit is not installed — skipping the stale marker"
    continue
  fi
  # restart, not reload: systemd's LoadCredential= takes a start-time snapshot of
  # the certificate, so a consumer using it cannot see a renewal any other way.
  # Sub-second, roughly every 60 days, and WireGuard re-handshakes within 5 s.
  if systemctl restart -- "$unit"; then
    log "restarted $unit"
  else
    log "FAILED to restart $unit"
    failed=$((failed + 1))
  fi
done

[ "$found" -gt 0 ] || log "no consumers registered for $slug"
[ "$failed" -eq 0 ] || die "$failed consumer(s) failed to restart"
log "done ($slug)"
