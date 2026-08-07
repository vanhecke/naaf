#!/usr/bin/env bash
# Create a Vultr instance for naaf.
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
#   NAAF_SSH_KEY_ID  a Vultr SSH key id — `vultr-cli ssh-key list`
#   NAAF_SSH_KEY     the matching private key on this machine, e.g. ~/.ssh/id_ed25519
# Optional (override via env): NAAF_REGION (default ewr) NAAF_PLAN (vc2-1c-2gb)
#   NAAF_OS (2625 = Debian 13 x64) NAAF_LABEL / NAAF_HOSTNAME (naaf)
#   `vultr-cli regions list`, `vultr-cli plans list`, `vultr-cli os list`
# --auto also needs: NAAF_REPO_URL, NAAF_ADMIN_PASSWORD (min 8 chars);
#   optional NAAF_REPO_REF (default main), NAAF_REPO_TOKEN (private repo),
#   NAAF_ENDPOINT_HOST (the FQDN clients dial, e.g. vpn.example.com).
# Add --firewall to create/attach the naaf firewall group (see ensure-firewall.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# Same one config file: the WORKSTATION ONLY section holds these values.
[ -f "$REPO/naaf.conf" ] && { set -a; . "$REPO/naaf.conf"; set +a; }

MODE=vanilla
ENSURE_FW=0
LABEL="${NAAF_LABEL:-naaf}"
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

REGION="${NAAF_REGION:-ewr}"
PLAN="${NAAF_PLAN:-vc2-1c-2gb}"
OS="${NAAF_OS:-2625}" # Debian 13 x64 (trixie)
# No defaults: these are account-specific. Failing loudly beats silently building
# a box against whatever key happened to be hardcoded here.
: "${NAAF_SSH_KEY_ID:?set NAAF_SSH_KEY_ID — see \`vultr-cli ssh-key list\`}"
: "${NAAF_SSH_KEY:?set NAAF_SSH_KEY to the matching private key, e.g. ~/.ssh/id_ed25519}"
SSH_KEY_ID="$NAAF_SSH_KEY_ID"
SSH_KEY="$NAAF_SSH_KEY"
HOSTN="${NAAF_HOSTNAME:-naaf}"

log() { printf '[box] %s\n' "$*" >&2; }

fw_args=()
if [ "$ENSURE_FW" = 1 ]; then
  gid="$("$HERE/ensure-firewall.sh")"
  fw_args=(--firewall-group "$gid")
elif [ -n "${NAAF_FIREWALL_GROUP:-}" ]; then
  fw_args=(--firewall-group "$NAAF_FIREWALL_GROUP")
fi

ud_args=()
tmp_ud=""
if [ "$MODE" = auto ]; then
  : "${NAAF_REPO_URL:?set NAAF_REPO_URL for --auto}"
  : "${NAAF_ADMIN_PASSWORD:?set NAAF_ADMIN_PASSWORD for --auto}"
  clone_url="$NAAF_REPO_URL"
  if [ -n "${NAAF_REPO_TOKEN:-}" ]; then
    # Inject a token for a private clone (https://.../owner/repo.git)
    clone_url="https://x-access-token:${NAAF_REPO_TOKEN}@${NAAF_REPO_URL#https://}"
  fi
  # base64 so odd characters survive the heredoc and cloud-init.
  pw_b64="$(printf '%s' "$NAAF_ADMIN_PASSWORD" | base64 | tr -d '\n')"
  eh_b64="$(printf '%s' "${NAAF_ENDPOINT_HOST:-}" | base64 | tr -d '\n')"
  # Carry the local naaf.conf (minus the workstation-only section) so a
  # self-provisioning box gets the operator's subnet, ports and DNS settings.
  # Without this the box would silently come up on naaf.conf.example defaults.
  conf_b64=""
  if [ -f "$REPO/naaf.conf" ]; then
    conf_b64="$(sed '/^# ═*.*WORKSTATION ONLY/,$d' "$REPO/naaf.conf" | base64 | tr -d '\n')"
  fi
  tmp_ud="$(mktemp)"; trap 'rm -f "$tmp_ud"' EXIT
  cat >"$tmp_ud" <<EOF
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git ca-certificates
rm -rf /opt/naaf
git clone --depth 1 --branch "${NAAF_REPO_REF:-main}" "$clone_url" /opt/naaf
if [ -n '$conf_b64' ]; then
  install -d -m 0750 /etc/naaf
  printf '%s' '$conf_b64' | base64 -d >/etc/naaf/naaf.conf
  chmod 0640 /etc/naaf/naaf.conf
fi
export NAAF_ADMIN_PASSWORD="\$(printf '%s' '$pw_b64' | base64 -d)"
export NAAF_ENDPOINT_HOST="\$(printf '%s' '$eh_b64' | base64 -d)"
bash /opt/naaf/deploy/provision/provision.sh
EOF
  ud_args=(--userdata-file "$tmp_ud")
  log "userdata prepared (repo ${NAAF_REPO_URL}@${NAAF_REPO_REF:-main}, self-provision${conf_b64:+, naaf.conf included})"
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
