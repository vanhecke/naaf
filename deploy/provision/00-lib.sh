#!/usr/bin/env bash
# Shared helpers for the naaf provisioning steps. Sourced by every NN-*.sh, not
# executed directly. Steps are idempotent and safe to re-run — the whole point of
# the staged rollout is running them one-by-one and re-running after a fix.
set -euo pipefail

# Repo root: this file lives at <repo>/deploy/provision/00-lib.sh
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
export REPO_ROOT

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# The one config file. Plain KEY=value with no `export` and no expansion, so
# sourcing it can never execute anything. On a provisioned box it is at
# /etc/naaf/naaf.conf; before 40-app.sh has installed it, fall back to the copy
# in the synced repo so early steps still see the operator's choices.
NAAF_CONF="${NAAF_CONF:-/etc/naaf/naaf.conf}"
if [ -f "$NAAF_CONF" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$NAAF_CONF"
  set +a
elif [ -f "$REPO_ROOT/naaf.conf" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$REPO_ROOT/naaf.conf"
  set +a
fi

# Defaults for anything the config file did not set. These must agree with
# Naaf::Config::DEFAULTS in lib/naaf/config.rb; bin/ci proves the config file
# covers every key, and these are the last-resort fallback when there is no file
# at all (a bare `bash 20-system.sh` on a fresh box).
: "${NAAF_USER:=naaf}"
: "${NAAF_GROUP:=naaf}"
: "${NAAF_APP_DIR:=/opt/naaf}"
: "${NAAF_STATE_DIR:=/var/lib/naaf}"
: "${NAAF_DB:=/var/lib/naaf/naaf.db}"
: "${NAAF_RUN_DIR:=/run/naaf}"
: "${NAAF_HELPER_SOCKET:=/run/naaf/helper.sock}"
: "${NAAF_LOG_DIR:=/var/log/naaf-provision}"
: "${NAAF_RUBY_VERSION:=4.0.6}"
: "${NAAF_RUBY_PREFIX:=/opt/rubies/ruby-$NAAF_RUBY_VERSION}"
: "${NAAF_RV_VERSION:=0.6.0}"
: "${NAAF_WG_INTERFACE:=wg0}"
: "${NAAF_LISTEN_PORT:=51820}"
: "${NAAF_BACKUP_DIR:=/var/lib/naaf/backups}"
: "${NAAF_SWAP_GB:=2}"
: "${NAAF_LITESTREAM_ENABLED:=0}"
: "${NAAF_WSTUNNEL_ENABLED:=0}"
: "${NAAF_WSTUNNEL_PORT:=443}"
# NAAF_CERT_DIR is not optional here the way the wstunnel pair is. 60-certs.sh
# runs unconditionally — only its ACME half is gated — so on exactly the
# no-config-file path this block exists for, `install -d "$NAAF_CERT_DIR"` would
# abort the step with `unbound variable` under `set -u`, and provision.sh turns
# any failed step into a fatal die. shellcheck -S warning does not report SC2154,
# so this default is the only thing standing between that and a dead deploy.
: "${NAAF_CERT_DIR:=/etc/naaf/certs}"
export NAAF_USER NAAF_GROUP NAAF_APP_DIR NAAF_STATE_DIR NAAF_DB NAAF_RUN_DIR \
  NAAF_HELPER_SOCKET NAAF_LOG_DIR NAAF_RUBY_VERSION NAAF_RUBY_PREFIX \
  NAAF_RV_VERSION NAAF_WG_INTERFACE NAAF_LISTEN_PORT NAAF_BACKUP_DIR \
  NAAF_SWAP_GB NAAF_LITESTREAM_ENABLED NAAF_WSTUNNEL_ENABLED NAAF_WSTUNNEL_PORT \
  NAAF_CERT_DIR NAAF_CONF

# The Ruby that rv installs (30-ruby.sh passes the parent of this as
# --install-dir, and rv creates ruby-<version> inside it). Both systemd units are
# templated with this exact path at install time by 40-app.sh.
RUBY_PREFIX="$NAAF_RUBY_PREFIX"
RUBY_BIN="$RUBY_PREFIX/bin/ruby"
export RUBY_PREFIX RUBY_BIN

# Put the installed Ruby on PATH so `bundle exec ruby` and gem executables
# resolve. Harmless before 30-ruby installs it.
case ":$PATH:" in *":$RUBY_PREFIX/bin:"*) ;; *) export PATH="$RUBY_PREFIX/bin:$PATH" ;; esac
