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

# The wstunnel port is opened only when the transport is enabled — an open
# tcp/443 with nothing behind it is an advertisement. The disabled branch renders
# a comment, which is a legal empty statement inside a chain block, so the
# placeholder guard below still proves every __NAAF_ token was consumed.
if [ "$NAAF_WSTUNNEL_ENABLED" = "1" ]; then
  # The port lands unquoted in an nft rule, so it has to be digits and nothing
  # else. Anything else is a syntax error in the file that keeps SSH alive.
  case "$NAAF_WSTUNNEL_PORT" in
    "" | *[!0-9]*) die "NAAF_WSTUNNEL_PORT must be numeric, got '$NAAF_WSTUNNEL_PORT'" ;;
  esac
  # %-46s puts the comment in the template's own column 51 (4 spaces of indent
  # are already in the template line).
  wstunnel_rule="$(printf '%-46s# wstunnel (WireGuard inside TLS/WebSocket)' \
    "tcp dport $NAAF_WSTUNNEL_PORT accept")"
  wstunnel_note="wstunnel tcp/$NAAF_WSTUNNEL_PORT"
else
  wstunnel_rule="# wstunnel disabled (NAAF_WSTUNNEL_ENABLED=0)"
  wstunnel_note="wstunnel off"
fi

# `|` is the delimiter for the wstunnel expression while the other two keep `#`,
# and that is not a matter of taste. Both replacement texts contain a `#`, so
# `s#__NAAF_WSTUNNEL_RULE__## wstunnel disabled (…)#g` parses as an empty
# replacement followed by a `w` (write-file) flag: sed exits 0, drops a junk file
# named after the tail of the line in the CWD, and the rendered output still
# passes both the placeholder guard and `nft -c -f`. The enabled branch would
# install a base firewall with the rule silently missing and every check green.
sed -e "s#__NAAF_LISTEN_PORT__#$NAAF_LISTEN_PORT#g" \
    -e "s#__NAAF_WG_INTERFACE__#$NAAF_WG_INTERFACE#g" \
    -e "s|__NAAF_WSTUNNEL_RULE__|$wstunnel_rule|g" \
    "$REPO_ROOT/deploy/nftables.conf.template" >"$tmp_nft"
grep -q '__NAAF_' "$tmp_nft" && die "unsubstituted placeholder left in the rendered nftables.conf"
nft -c -f "$tmp_nft" || die "rendered nftables.conf failed the syntax check — not installing it"
# `enable --now` is NOT enough on a re-run, and that is the whole reason these
# lines are shaped like this rather than being one systemctl call. Debian's
# packaged nftables.service is `Type=oneshot` with `RemainAfterExit=yes`, so once
# it has run it stays `active (exited)` forever and `systemctl start` — which is
# all `--now` does — short-circuits: `ExecStart=/usr/sbin/nft -f
# /etc/nftables.conf` never runs a second time. Flipping NAAF_WSTUNNEL_ENABLED on
# an already-provisioned box would then install a file the kernel never loads —
# a wstunnel listener nothing outside can reach, or tcp/443 left accepted with
# nothing behind it — while every guard above stays green and only verify.sh
# section 8, which reads the LIVE ruleset, notices. That same unit ships
# `ExecReload=/usr/sbin/nft -f /etc/nftables.conf`, the identical command, which
# is what makes a reload the real re-apply.
#
# Only when the rendered file actually differs, because the reload is not free:
# this file opens with `flush ruleset`, which takes table `inet naaf` (the
# spoke<->spoke default-deny, the egress masquerade and every DNAT) down with it,
# and Reconciler#poll! re-applies only when the PEER SET has drifted — a missing
# table is something it never looks for.
if cmp -s "$tmp_nft" /etc/nftables.conf; then
  reload_needed=0
else
  reload_needed=1
fi
install -m 0644 "$tmp_nft" /etc/nftables.conf
systemctl enable nftables
if [ "$reload_needed" -eq 1 ]; then
  # reload-or-restart and not plain reload: on a FIRST provision the unit is
  # inactive and has nothing to reload (`systemctl reload` fails outright), so
  # this starts it instead. `cmp` against a nonexistent file is non-zero too,
  # which is what routes the fresh-box case here.
  log "base firewall changed — reloading it into the kernel"
  systemctl reload-or-restart nftables
  # The reload flushed table `inet naaf` along with everything else, so put it
  # back now instead of leaving the tunnel without its isolation and NAT until
  # the next UI mutation. bin/naaf runs Reconciler#apply! at startup, so a
  # restart is the re-apply. try-restart is a no-op when naaf is not running, and
  # on a first provision naaf is not even installed yet (40-app.sh) — hence the
  # `2>/dev/null || true`, the same shape 45-litestream.sh and 65-wstunnel.sh use
  # for a unit that may not exist.
  log "re-applying table inet naaf (the reload flushed it)"
  systemctl try-restart naaf 2>/dev/null || true
else
  # Unchanged — but a box that has never loaded it still needs it once. `start`
  # is a no-op on an already-active unit, which is exactly what `--now` did.
  systemctl start nftables
fi
log "base firewall loaded (wg $NAAF_WG_INTERFACE, udp/$NAAF_LISTEN_PORT, $wstunnel_note)"
