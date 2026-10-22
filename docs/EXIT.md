# A VPN client as the internet exit

The internet exit (`/exit`, `plan/exit.md`) is usually WARP. It can also be one
of this box's own clients — a machine at home — so full-tunnel clients leave
from that machine's connection instead of the VPS.

```
full client --wg0--> hub --table 159--> wg-exit --UDP to 10.8.0.2:51821 inside wg0--> home client
home client: naaf-exit iface --forward + NAT--> home router --> internet
```

Nothing new on the hub. The exit row's endpoint is the client's VPN address,
so `wg-exit`'s own UDP is hub-originated traffic to `10.8.0.x`: it takes the
main table's connected route into wg0 and rides the client's existing tunnel.
No port forward at home, no NAT traversal — the client's own split tunnel
already holds the path open. Policy rules, table 159, the MSS clamp, the
port-forward mark and the SOCKS proxy all behave exactly as with WARP.

The `/exit` form refuses what cannot work: the hub's own address, an address
no enabled client has, and an MTU that does not fit inside wg0 after the outer
WireGuard header (wg0 MTU − 60, so 1360 on a default box; 1280 is fine). The
client carrying the exit cannot be deleted, nor disabled while the exit is
enabled — IPAM would hand its address to another machine.

## Before you do this

- **When that machine sleeps or goes offline, every full-tunnel client loses
  internet.** No fallback, on purpose (`plan/exit.md`, decision 6). Disable the
  exit on `/exit` to restore WAN masquerade. On a Mac: `pmset -c sleep 0`, and
  a closed lid still sleeps unless it is in clamshell mode with a display.
- **That machine must stay split.** With a full config its own internet would
  enter the hub, leave through `wg-exit`, and come straight back to it.
- Packets cross the VPS↔home path twice and are encrypted twice. Throughput is
  the home uplink at best.
- DNS still resolves on the VPS (the hub's passthrough), so geo-DNS answers for
  the VPS while traffic arrives from home.
- The SOCKS5 proxy follows the exit — its traffic leaves from home too.
- Everything full-tunnel clients do is attributed to the home IP.

## Addresses

Two `/32`s outside `wg_subnet`, every site network, and the home LAN. Below:
`10.99.0.2` is the hub's end (the exit row's *Assigned IPv4 address*, what
`wg-exit` masquerades to) and `10.99.0.1` is the client's end. Port `51821`
is the client's listen port — any UDP port free on that machine.

## Client side: macOS

The App Store WireGuard app keeps running the split tunnel. It allows only
one active tunnel, so the exit listener runs on Homebrew's `wireguard-go`:

```sh
brew install wireguard-tools        # wg, wg-quick, wireguard-go, bash 5
priv=$(wg genkey)
echo "$priv" | wg pubkey            # the "Peer public key" for /exit
```

On the hub, `/exit` → **Add manually** (delete an existing exit first):

| Field | Value |
|---|---|
| Peer public key | the `wg pubkey` output above |
| This box's private key | blank — generated; its public key is shown once in the flash |
| Endpoint host / port | the client's VPN address, e.g. `10.8.0.2` / `51821` |
| Assigned IPv4 address | `10.99.0.2` |
| MTU | `1280` |
| Keepalive | `25` — the hub dials, so the hub keeps it alive |

`/opt/homebrew/etc/wireguard/naaf-exit.conf`, root-owned, mode 0600:

```ini
[Interface]
PrivateKey = <$priv from above>
Address = 10.99.0.1/32
ListenPort = 51821
MTU = 1280
PostUp = sysctl -w net.inet.ip.forwarding=1
PostUp = pfctl -a com.apple/naaf-exit -f /opt/homebrew/etc/wireguard/naaf-exit.pf
PostUp = pfctl -E 2>&1 | awk '/^Token/ {print $3}' > /var/run/naaf-exit.pftoken
PostDown = pfctl -a com.apple/naaf-exit -F all
PostDown = pfctl -X "$(cat /var/run/naaf-exit.pftoken)"
PostDown = sysctl -w net.inet.ip.forwarding=0

[Peer]
# the hub's exit public key, from the /exit flash
PublicKey = <hub exit public key>
AllowedIPs = 10.99.0.2/32
```

No `Endpoint` and no keepalive: the hub dials in. `AllowedIPs` is the hub's
masquerade address only — never `0.0.0.0/0`, which would take this Mac's own
default route.

`/opt/homebrew/etc/wireguard/naaf-exit.pf` — the interface is whatever
`route -n get default` names:

```
nat on en0 inet from 10.99.0.2 to any -> (en0)
```

The stock `/etc/pf.conf`, loaded at boot by `com.apple.pfctl`, already has
`nat-anchor "com.apple/*"`, so it is not edited. `pfctl -E` takes a reference
on pf and `-X` releases only that reference.

Bring it up and check it:

```sh
sudo wg-quick up naaf-exit
sudo wg show naaf-exit          # a handshake with endpoint 10.8.0.1:<port> once the hub dials
sudo pfctl -a com.apple/naaf-exit -s nat
```

Keep it across reboots with `/Library/LaunchDaemons/be.joris.naaf-exit.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>be.joris.naaf-exit</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/wg-quick</string><string>up</string><string>naaf-exit</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/be.joris.naaf-exit.plist
```

`PATH` is load-bearing: `wg-quick` is `#!/usr/bin/env bash` and needs bash 5
and `wireguard-go` from Homebrew, not `/bin/bash` 3.2. If the macOS
application firewall is ever turned on, allow incoming for `wireguard-go`.

## Client side: Linux

Same conf, Linux hooks:

```ini
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft add table ip naaf_exit
PostUp = nft add chain ip naaf_exit post '{ type nat hook postrouting priority srcnat; }'
PostUp = nft add rule ip naaf_exit post ip saddr 10.99.0.2 masquerade
PostDown = nft delete table ip naaf_exit
```

`systemctl enable wg-quick@naaf-exit`. A forward-chain `policy drop` on that
machine (or `ufw`) must let `iifname "naaf-exit"` out and the replies back.

## Check it end to end

```sh
# hub
sudo wg show wg-exit                     # endpoint 10.8.0.2:51821, recent handshake
ip route get 10.8.0.2                    # dev wg0 — the outer path
ip route get 1.1.1.1 from 10.8.0.3 iif wg0   # dev wg-exit
curl -4 https://ifconfig.me              # still the VPS

# a full-tunnel client
curl -4 https://ifconfig.me              # the home IP
```

When it breaks: `docs/TROUBLESHOOTING.md` §1c.
