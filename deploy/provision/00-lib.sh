#!/usr/bin/env bash
# Shared helpers for the naaf provisioning steps. Sourced by every NN-*.sh, not
# executed directly. Steps are idempotent and safe to re-run — the whole point of
# the staged rollout is running them one-by-one and re-running after a fix.
set -euo pipefail

# Repo root: this file lives at <repo>/deploy/provision/00-lib.sh
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
export REPO_ROOT

NAAF_LOG_DIR="${NAAF_LOG_DIR:-/var/log/naaf-provision}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# The Ruby that ruby-install (run as root) produces. Overridable if the version
# ever changes; both systemd units reference this exact path.
RUBY_PREFIX="${NAAF_RUBY_PREFIX:-/opt/rubies/ruby-4.0.6}"
RUBY_BIN="$RUBY_PREFIX/bin/ruby"
export RUBY_PREFIX RUBY_BIN

# Put the built Ruby on PATH so `bundle exec ruby` and gem executables resolve
# (root's login PATH has no chruby). Harmless before 30-ruby builds it.
case ":$PATH:" in *":$RUBY_PREFIX/bin:"*) ;; *) export PATH="$RUBY_PREFIX/bin:$PATH" ;; esac
