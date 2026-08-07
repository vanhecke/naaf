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
getent group "$NAAF_GROUP" >/dev/null || addgroup --system "$NAAF_GROUP"
getent passwd "$NAAF_USER" >/dev/null ||
  adduser --system --ingroup "$NAAF_GROUP" --home "$NAAF_STATE_DIR" \
    --shell /usr/sbin/nologin "$NAAF_USER"

log "directories"
install -d -o "$NAAF_USER" -g "$NAAF_GROUP" -m 0750 "$NAAF_STATE_DIR"
install -d -o root -g "$NAAF_GROUP" -m 0750 "$NAAF_RUN_DIR"
install -d -o root -g root -m 0755 "$NAAF_APP_DIR"
install -d -o root -g "$NAAF_GROUP" -m 0750 /etc/naaf
# Snapshots live inside the state dir on purpose: it is the app's only writable
# path under ProtectSystem=strict, so no unit change is needed. 0700 because a
# snapshot contains the server private key and the admin password hash.
install -d -o "$NAAF_USER" -g "$NAAF_GROUP" -m 0700 "$NAAF_BACKUP_DIR"

log "IP forwarding (v4 on, v6 off)"
install -m 0644 "$REPO_ROOT/deploy/sysctl-99-naaf.conf" /etc/sysctl.d/99-naaf.conf
sysctl --system >/dev/null
[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] || die "ip_forward did not enable"

log "tmpfiles for /run/naaf (tmpfs is wiped on reboot)"
install -m 0644 "$REPO_ROOT/deploy/tmpfiles-naaf.conf" /etc/tmpfiles.d/naaf.conf
systemd-tmpfiles --create

log "SSH hardening (key-only)"
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-naaf.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t && systemctl reload ssh

# Many Debian cloud images ship ufw with its service enabled. Its iptables-nft
# rules sit on the input/forward hooks and silently drop WireGuard (udp 51820),
# tunnel DNS (udp 53 from wg0), and forwarded full-tunnel traffic — even while
# `ufw status` reads inactive. naaf owns the firewall via nftables (inet filter +
# inet naaf), so disable ufw and drop its tables to remove the conflict.
if command -v ufw >/dev/null 2>&1 || systemctl list-unit-files ufw.service >/dev/null 2>&1; then
  log "disabling ufw (its rules conflict with the nftables firewall)"
  ufw --force disable 2>/dev/null || true
  systemctl disable --now ufw 2>/dev/null || true
  systemctl mask ufw 2>/dev/null || true
fi
nft delete table ip filter 2>/dev/null || true
nft delete table ip6 filter 2>/dev/null || true

log "static base firewall (table inet filter — the app never touches this)"
# Rendered from the template so naaf.conf is the single authority for the
# WireGuard port and interface. Check the RENDERED file before installing it: a
# bad substitution must not be able to land in /etc/nftables.conf, because that
# file is what keeps SSH alive.
tmp_nft="$(mktemp)"
trap 'rm -f "$tmp_nft"' EXIT
sed -e "s#__NAAF_LISTEN_PORT__#$NAAF_LISTEN_PORT#g" \
    -e "s#__NAAF_WG_INTERFACE__#$NAAF_WG_INTERFACE#g" \
    "$REPO_ROOT/deploy/nftables.conf.template" >"$tmp_nft"
grep -q '__NAAF_' "$tmp_nft" && die "unsubstituted placeholder left in the rendered nftables.conf"
nft -c -f "$tmp_nft" || die "rendered nftables.conf failed the syntax check — not installing it"
install -m 0644 "$tmp_nft" /etc/nftables.conf
systemctl enable --now nftables
log "base firewall loaded (wg $NAAF_WG_INTERFACE, udp/$NAAF_LISTEN_PORT)"
