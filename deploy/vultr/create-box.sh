#!/usr/bin/env bash
# Create a Vultr instance for wgcp.
#
#   create-box.sh --vanilla     bare Debian 13, no userdata (Stage 1: you then run
#                               the provisioning steps one-by-one over SSH)
#   create-box.sh --auto        Debian 13 that self-provisions from cloud-init
#                               userdata (Stage 2: clone repo + run provision.sh)
#
# Prints "<instance-id>\t<main-ip>" to stdout once SSH is reachable. Logs to stderr.
#
# Required (no defaults — they are account-specific and a wrong guess would build
# the box in someone else's account or region):
#   WGCP_SSH_KEY_ID  a Vultr SSH key id — `vultr-cli ssh-key list`
#   WGCP_SSH_KEY     the matching private key on this machine, e.g. ~/.ssh/id_ed25519
# Optional (override via env): WGCP_REGION (default ewr) WGCP_PLAN (vc2-1c-2gb)
#   WGCP_OS (2625 = Debian 13 x64) WGCP_LABEL / WGCP_HOSTNAME (wgcp)
#   `vultr-cli regions list`, `vultr-cli plans list`, `vultr-cli os list`
# --auto also needs: WGCP_REPO_URL, WGCP_ADMIN_PASSWORD (min 8 chars);
#   optional WGCP_REPO_REF (default main), WGCP_REPO_TOKEN (private repo),
#   WGCP_ENDPOINT_HOST (the FQDN clients dial, e.g. vpn.example.com).
# Add --firewall to create/attach the wgcp firewall group (see ensure-firewall.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=vanilla
ENSURE_FW=0
LABEL="${WGCP_LABEL:-wgcp}"
while [ $# -gt 0 ]; do
  case "$1" in
    --vanilla) MODE=vanilla ;;
    --auto) MODE=auto ;;
    --firewall) ENSURE_FW=1 ;;
    --label) LABEL="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

REGION="${WGCP_REGION:-ewr}"
PLAN="${WGCP_PLAN:-vc2-1c-2gb}"
OS="${WGCP_OS:-2625}" # Debian 13 x64 (trixie)
# No defaults: these are account-specific. Failing loudly beats silently building
# a box against whatever key happened to be hardcoded here.
: "${WGCP_SSH_KEY_ID:?set WGCP_SSH_KEY_ID — see \`vultr-cli ssh-key list\`}"
: "${WGCP_SSH_KEY:?set WGCP_SSH_KEY to the matching private key, e.g. ~/.ssh/id_ed25519}"
SSH_KEY_ID="$WGCP_SSH_KEY_ID"
SSH_KEY="$WGCP_SSH_KEY"
HOSTN="${WGCP_HOSTNAME:-wgcp}"

log() { printf '[box] %s\n' "$*" >&2; }

fw_args=()
if [ "$ENSURE_FW" = 1 ]; then
  gid="$("$HERE/ensure-firewall.sh")"
  fw_args=(--firewall-group "$gid")
elif [ -n "${WGCP_FIREWALL_GROUP:-}" ]; then
  fw_args=(--firewall-group "$WGCP_FIREWALL_GROUP")
fi

ud_args=()
tmp_ud=""
if [ "$MODE" = auto ]; then
  : "${WGCP_REPO_URL:?set WGCP_REPO_URL for --auto}"
  : "${WGCP_ADMIN_PASSWORD:?set WGCP_ADMIN_PASSWORD for --auto}"
  clone_url="$WGCP_REPO_URL"
  if [ -n "${WGCP_REPO_TOKEN:-}" ]; then
    # Inject a token for a private clone (https://.../owner/repo.git)
    clone_url="https://x-access-token:${WGCP_REPO_TOKEN}@${WGCP_REPO_URL#https://}"
  fi
  # base64 the secrets so odd characters survive the heredoc + cloud-init.
  pw_b64="$(printf '%s' "$WGCP_ADMIN_PASSWORD" | base64 | tr -d '\n')"
  eh_b64="$(printf '%s' "${WGCP_ENDPOINT_HOST:-}" | base64 | tr -d '\n')"
  tmp_ud="$(mktemp)"; trap 'rm -f "$tmp_ud"' EXIT
  cat >"$tmp_ud" <<EOF
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git ca-certificates
rm -rf /opt/wgcp
git clone --depth 1 --branch "${WGCP_REPO_REF:-main}" "$clone_url" /opt/wgcp
export WGCP_ADMIN_PASSWORD="\$(printf '%s' '$pw_b64' | base64 -d)"
export WGCP_ENDPOINT_HOST="\$(printf '%s' '$eh_b64' | base64 -d)"
bash /opt/wgcp/deploy/provision/provision.sh
EOF
  ud_args=(--userdata-file "$tmp_ud")
  log "userdata prepared (repo ${WGCP_REPO_URL}@${WGCP_REPO_REF:-main}, self-provision)"
fi

log "creating $PLAN in $REGION (os $OS, mode $MODE, label $LABEL)"
out="$(vultr-cli instance create \
  --region "$REGION" --plan "$PLAN" --os "$OS" \
  --ssh-keys "$SSH_KEY_ID" --host "$HOSTN" --label "$LABEL" \
  "${fw_args[@]}" "${ud_args[@]}" -o json)"
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
log "main ip: $ip"

log "waiting for SSH on $ip (this can take a couple minutes after boot)"
ok=0
for _ in $(seq 1 90); do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
    -o IdentitiesOnly=yes -o IdentityAgent=none \
    -i "$SSH_KEY" "root@$ip" true 2>/dev/null; then ok=1; break; fi
  sleep 5
done
[ "$ok" = 1 ] && log "SSH is up" || log "WARNING: SSH not reachable yet — the box may still be booting"

printf '%s\t%s\n' "$iid" "$ip"
