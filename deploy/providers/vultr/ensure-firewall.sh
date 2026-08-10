#!/usr/bin/env bash
# Create (or reuse) a Vultr firewall group that mirrors the host nftables policy:
# SSH, WireGuard, and — only when NAAF_WSTUNNEL_ENABLED=1 — the wstunnel port.
# Nothing else, and never tcp/80: certificates come from ACME DNS-01, which needs
# no inbound port at all. Belt-and-suspenders in front of the box's own firewall,
# and it covers the brief window during first boot before nftables loads.
#
# SSH source defaults to anywhere (SSH is key-only after hardening, so this is
# safe and avoids locking yourself out behind a CGNAT/WARP egress IP). Set
# NAAF_SSH_SRC_IP=<your.ip> to restrict SSH to a single address.
#
# Logs go to stderr; the firewall group ID is printed to stdout so callers can do:
#   GID=$(deploy/providers/vultr/ensure-firewall.sh)
set -euo pipefail

# Both ports come from the same naaf.conf that renders the host firewall
# (deploy/provision/20-system.sh), so the two cannot drift apart.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
[ -f "$REPO/naaf.conf" ] && { set -a; . "$REPO/naaf.conf"; set +a; }

DESC="${NAAF_FW_DESC:-naaf}"
WG_PORT="${NAAF_LISTEN_PORT:-51820}"
WS_ENABLED="${NAAF_WSTUNNEL_ENABLED:-0}"
WS_PORT="${NAAF_WSTUNNEL_PORT:-443}"

log() { printf '[fw] %s\n' "$*" >&2; }

# SSH source: a single /32 if NAAF_SSH_SRC_IP is set, else anywhere.
if [ -n "${NAAF_SSH_SRC_IP:-}" ]; then
  ssh_subnet="$NAAF_SSH_SRC_IP"; ssh_size=32
else
  ssh_subnet="0.0.0.0"; ssh_size=0
fi

# Reuse an existing group with this description, else create one.
gid="$(vultr-cli firewall group list -o json 2>/dev/null |
  jq -r --arg d "$DESC" '(.firewall_groups // [])[] | select(.description==$d) | .id' | head -1)"

if [ -n "$gid" ]; then
  # Short-circuit: an existing group is never reconciled, only reused. So
  # flipping NAAF_WSTUNNEL_ENABLED on a box that already has a group does NOT
  # open the wstunnel port here — the host's own nftables gets the rule from
  # 20-system.sh and Vultr's group silently keeps dropping it. Add the rule by
  # hand (`vultr-cli firewall rule create "$gid" --ip-type v4 --protocol tcp
  # --size 0 --subnet 0.0.0.0 --port 443`, and the v6 twin) or delete the group
  # and re-run this script.
  log "reusing firewall group $gid ($DESC) — assuming rules already set"
  echo "$gid"
  exit 0
fi

log "creating firewall group '$DESC'"
gid="$(vultr-cli firewall group create -d "$DESC" -o json | jq -r '.firewall_group.id // .id')"
[ -n "$gid" ] && [ "$gid" != "null" ] || { echo "failed to create firewall group" >&2; exit 1; }
log "group $gid created; adding rules"

# SSH (22/tcp)
vultr-cli firewall rule create "$gid" --ip-type v4 --protocol tcp --size "$ssh_size" --subnet "$ssh_subnet" --port 22 \
  --notes "ssh" >&2
# WireGuard (UDP) from anywhere, v4 and v6
vultr-cli firewall rule create "$gid" --ip-type v4 --protocol udp --size 0 --subnet 0.0.0.0 --port "$WG_PORT" \
  --notes "wireguard v4" >&2
vultr-cli firewall rule create "$gid" --ip-type v6 --protocol udp --size 0 --subnet "::" --port "$WG_PORT" \
  --notes "wireguard v6" >&2

# wstunnel (TCP), only when the transport is enabled — same gate as the host's
# own base firewall, which 20-system.sh renders as a bare comment when it is off.
# An open tcp/443 with nothing behind it is an advertisement. No tcp/80 here or
# anywhere: certificates come from ACME DNS-01, which needs no inbound port.
ws_note=""
if [ "$WS_ENABLED" = "1" ]; then
  case "$WS_PORT" in ''|*[!0-9]*) echo "NAAF_WSTUNNEL_PORT '$WS_PORT' is not numeric" >&2; exit 1 ;; esac
  vultr-cli firewall rule create "$gid" --ip-type v4 --protocol tcp --size 0 --subnet 0.0.0.0 --port "$WS_PORT" \
    --notes "wstunnel v4" >&2
  vultr-cli firewall rule create "$gid" --ip-type v6 --protocol tcp --size 0 --subnet "::" --port "$WS_PORT" \
    --notes "wstunnel v6" >&2
  ws_note=", tcp/$WS_PORT<-any"
fi

log "firewall group $gid ready (ssh<-${ssh_subnet}/${ssh_size}, udp/$WG_PORT<-any$ws_note)"
echo "$gid"
