#!/usr/bin/env bash
# System wiring: service user, directories, IP forwarding, the /run socket dir,
# SSH hardening, and the static base firewall. Installs the committed artifacts
# from the repo verbatim (they are the reviewable source of truth). Mirrors
# SETUP §1a–§1c.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
require_root

log "service user + group"
getent group wgcp >/dev/null || addgroup --system wgcp
getent passwd wgcp >/dev/null ||
  adduser --system --ingroup wgcp --home /var/lib/wgcp --shell /usr/sbin/nologin wgcp

log "directories"
install -d -o wgcp -g wgcp -m 0750 /var/lib/wgcp
install -d -o root -g wgcp -m 0750 /run/wgcp
install -d -o root -g root -m 0755 /opt/wgcp

log "IP forwarding (v4 on, v6 off)"
install -m 0644 "$REPO_ROOT/deploy/sysctl-99-wgcp.conf" /etc/sysctl.d/99-wgcp.conf
sysctl --system >/dev/null
[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] || die "ip_forward did not enable"

log "tmpfiles for /run/wgcp (tmpfs is wiped on reboot)"
install -m 0644 "$REPO_ROOT/deploy/tmpfiles-wgcp.conf" /etc/tmpfiles.d/wgcp.conf
systemd-tmpfiles --create

log "SSH hardening (key-only)"
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-wgcp.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t && systemctl reload ssh

# Many Debian cloud images ship ufw with its service enabled. Its iptables-nft
# rules sit on the input/forward hooks and silently drop WireGuard (udp 51820),
# tunnel DNS (udp 53 from wg0), and forwarded full-tunnel traffic — even while
# `ufw status` reads inactive. wgcp owns the firewall via nftables (inet filter +
# inet wgcp), so disable ufw and drop its tables to remove the conflict.
if command -v ufw >/dev/null 2>&1 || systemctl list-unit-files ufw.service >/dev/null 2>&1; then
  log "disabling ufw (its rules conflict with the nftables firewall)"
  ufw --force disable 2>/dev/null || true
  systemctl disable --now ufw 2>/dev/null || true
  systemctl mask ufw 2>/dev/null || true
fi
nft delete table ip filter 2>/dev/null || true
nft delete table ip6 filter 2>/dev/null || true

log "static base firewall (table inet filter — app never touches this)"
install -m 0644 "$REPO_ROOT/deploy/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable --now nftables
log "base firewall loaded"
