#!/usr/bin/env bash
# Create a Vultr instance for naaf and print its IP address.
#
#   create-box.sh [--no-firewall] [--label NAME]
#
# The provider contract is one line on stdout: the IP address of a fresh Debian
# 13 box you can reach as root over SSH. Everything downstream (`./deploy.sh`)
# works against a bare IP, so that is the whole integration surface — adding
# another provider means another script that prints an IP. Logs go to stderr.
#
# The box is bare: no user-data, no cloud-init, nothing to keep in sync with the
# provisioning scripts. `./deploy.sh --create` calls this and then provisions
# over SSH like it would any other host.
#
# Required (no defaults — they are account-specific, and a wrong guess would
# build the box in someone else's account or region):
#   NAAF_SSH_KEY_ID  a Vultr SSH key id — `vultr-cli ssh-key list`
#   NAAF_SSH_KEY     the matching private key on this machine, e.g. ~/.ssh/id_ed25519
# Optional: NAAF_REGION (default ewr) NAAF_PLAN (vc2-1c-2gb)
#   NAAF_OS (2625 = Debian 13 x64) NAAF_LABEL / NAAF_HOSTNAME (naaf)
#   `vultr-cli regions list`, `vultr-cli plans list`, `vultr-cli os list`
#
# A firewall group allowing only 22/tcp and the WireGuard port is created and
# attached by default (see ensure-firewall.sh); --no-firewall skips it, and
# NAAF_FIREWALL_GROUP attaches an existing group instead.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# Same one config file: the WORKSTATION ONLY section holds these values.
[ -f "$REPO/naaf.conf" ] && { set -a; . "$REPO/naaf.conf"; set +a; }

ENSURE_FW=1
LABEL="${NAAF_LABEL:-naaf}"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-firewall) ENSURE_FW=0 ;;
    --label) LABEL="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

REGION="${NAAF_REGION:-ewr}"
PLAN="${NAAF_PLAN:-vc2-1c-2gb}"
OS="${NAAF_OS:-2625}" # Debian 13 x64 (trixie)
# No defaults: these are account-specific. Failing loudly beats silently building
# a box against whatever key happened to be hardcoded here.
: "${NAAF_SSH_KEY_ID:?set NAAF_SSH_KEY_ID — see \`vultr-cli ssh-key list\`}"
: "${NAAF_SSH_KEY:?set NAAF_SSH_KEY to the matching private key, e.g. ~/.ssh/id_ed25519}"
HOSTN="${NAAF_HOSTNAME:-naaf}"

log() { printf '[box] %s\n' "$*" >&2; }

fw_args=()
if [ -n "${NAAF_FIREWALL_GROUP:-}" ]; then
  fw_args=(--firewall-group "$NAAF_FIREWALL_GROUP")
elif [ "$ENSURE_FW" = 1 ]; then
  fw_args=(--firewall-group "$("$HERE/ensure-firewall.sh")")
fi

log "creating $PLAN in $REGION (os $OS, label $LABEL)"
out="$(vultr-cli instance create \
  --region "$REGION" --plan "$PLAN" --os "$OS" \
  --ssh-keys "$NAAF_SSH_KEY_ID" --host "$HOSTN" --label "$LABEL" \
  "${fw_args[@]}" -o json)"
iid="$(printf '%s' "$out" | jq -r '.instance.id // .id')"
[ -n "$iid" ] && [ "$iid" != null ] || { echo "create failed: $out" >&2; exit 1; }
log "instance $iid created"

ip=""
for _ in $(seq 1 90); do
  j="$(vultr-cli instance get "$iid" -o json 2>/dev/null || true)"
  ip="$(printf '%s' "$j" | jq -r '.instance.main_ip // .main_ip // empty')"
  [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] && break
  sleep 5
done
[ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] || { echo "no main IP assigned" >&2; exit 1; }

log "instance $iid is $ip — it may take another minute to accept SSH"
printf '%s\n' "$ip"
