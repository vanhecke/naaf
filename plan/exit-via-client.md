# brainrot as the internet exit (tunnel-in-tunnel)

## Context

brainrot (this Mac, `10.8.0.2`, split config through the WireGuard app on
`utun9`, home LAN on `en0` via `192.168.68.1`) should be the internet exit
for the other machines. Every full-tunnel client's internet then leaves from
the home connection instead of the VPS.

Decisions so far: **all** full-tunnel clients use it (the existing
one-exit model), brainrot **replaces** whatever is in the exit slot now, and
the repo gets **guards and docs**, with no helper or schema change.

The hub already has a reviewed, tested internet exit (`plan/exit.md`): `wg-exit`,
table 159, prefs 15800/15850/15900, MSS clamp, port-forward mark, and the SOCKS
proxy following the exit. The hub's exit peer is just `pubkey + Endpoint`, and
nothing stops that Endpoint from being a VPN address. So **brainrot runs a
small WireGuard listener, and the hub's `wg-exit` dials it at
`10.8.0.2:51821` through wg0.** NAT traversal is solved already, because
brainrot's split tunnel is up and keepalive-ed.

```
full client ─wg0─▶ hub ─(iif wg0 → table 159)─▶ wg-exit ──UDP to 10.8.0.2:51821──▶ wg0 ─▶ brainrot
                                                  src masq → 10.99.0.2              utun9 (app)
brainrot: naaf-exit utun (wireguard-go) ─ forward ─ pf nat on en0 ─▶ home router ─▶ internet
```

Packet walk, checked against the code:
- The client's packet arrives on wg0. Pref 15900 sends it to table 159, `default dev wg-exit`, and `ip saddr <wg_subnet> oifname "wg-exit" masquerade` rewrites the source to the exit address `10.99.0.2`.
- The hub's wg-exit encapsulates it in UDP to `10.8.0.2:51821`. That packet is hub-originated (not `iif wg0`), so it uses the main table, takes the connected route `10.8.0.0/24 dev wg0`, and wg0 sends it to brainrot's peer. No rule loops it back.
- brainrot's `naaf-exit` peer has `AllowedIPs = 10.99.0.2/32`, so the source check passes. With IP forwarding on, the packet leaves on `en0`, where pf rewrites it to the LAN address. The reply is translated back to `10.99.0.2`, wg-quick's `/32` route sends it into `naaf-exit`, and it rides `10.8.0.1` back through utun9.
- Hub input: `ct state established` and `iifname wg0 accept` already let the replies in. `/etc/nftables.conf` is unchanged.
- MTU: wg0 is 1420. The inner tunnel loses 60 bytes (IPv4 + UDP + WireGuard), so it can be at most 1360. The exit's default 1280 (MSS clamp 1240 in both directions) fits.

## Repo changes (branch `feat/exit-via-client`, in a worktree)

No change to the helper, `apply`, the schema, nftables or any renderer. The
kernel gets exactly what it gets for WARP, just with a different Endpoint.

### `lib/naaf/app.rb`

1. **`assert_exit_endpoint!(endpoint, mtu)`**, called from `exit_attrs` (add and edit) and again when `/exit/:id/toggle` turns the exit back on (a row can predate the check, the same pattern as `reserved_port_owner`). It applies only when the endpoint host parses (`IPAM.parse_v4`) to an address inside `wg_subnet`, and then refuses:
   - `settings.server_ip`: the exit would dial itself.
   - an address with no **enabled** client: nothing would answer, or a reused IPAM address would point at the wrong machine.
   - `mtu > settings[:mtu] - 60`: the nested tunnel's MTU must fit inside wg0.
   Public endpoints (WARP or anything manual) behave exactly as before.
2. **Client delete and disable guards** (`/clients/:id/delete` and `/toggle` around L921–931). These routes don't use `submit`, so they get an early flash and redirect:
   - Delete is refused while *any* exit row's endpoint host is this client's `wg_ip`. This also prevents IPAM reuse.
   - Disable is refused while an *enabled* exit points at the client. The flash names the client by `wg_ip`, not its free-text name, because the layout renders flash unescaped.
3. A `GET /exit` helper sets `@exit_via` (client name and `wg_ip`) when the endpoint is a client.

### `views/exit.erb`
- One line next to Endpoint: "Reached through VPN client **name** (10.8.0.2)".
- One line of copy: "If that machine sleeps or goes offline, every full-tunnel client loses internet."

### Docs
- `docs/EXIT.md` (new): "A VPN client as the internet exit". It has the hub row, the full macOS recipe below, a short Linux variant (`ip_forward` plus an nft masquerade), and the caveats.
- `docs/TROUBLESHOOTING.md` §1c: a sub-step for when the endpoint is a client. Check `ip route get 10.8.0.2` (must be `dev wg0`), whether that client is handshaking on wg0, `pmset -g log` (a sleeping Mac looks like a flapping peer), and `sudo wg show naaf-exit` on the client.
- `AGENTS.md`: one bullet under the exit text. An exit endpoint inside `wg_subnet` must be an enabled client, the MTU must be at most wg0 MTU − 60, and a client that hosts the exit can't be deleted or disabled. The privilege boundary is unchanged.
- `plan/exit-via-client.md`: this plan, committed with the code.

### Tests (`test/app_test.rb`, `describe "internet exit"`)
- The endpoint `10.8.0.1` is refused. An address on `wg_subnet` with no client is refused, and so is one whose client is disabled. An enabled client's address is accepted.
- Through a client, MTU 1361 is refused and 1360 accepted. With a public endpoint, 1400 is still accepted (no regression).
- Turning the exit on is refused once its client has been disabled (row inserted directly).
- Deleting the client is refused while the exit row points at it and allowed after the exit is deleted. Disabling is refused while the exit is enabled and allowed once it's disabled.
- The existing WARP and manual exit tests stay green, unchanged.

## brainrot setup

The full recipe is in `docs/EXIT.md`. In short: Homebrew's `wireguard-go` runs a
`naaf-exit` listener on `:51821` (the App Store app keeps the split tunnel and
allows only one active tunnel). Its address is `10.99.0.1/32`, its peer is the
hub's exit key with `AllowedIPs = 10.99.0.2/32`, and it has no Endpoint. The
PostUp hooks turn on `net.inet.ip.forwarding` and load
`nat on en0 inet from 10.99.0.2 to any -> (en0)` into the `com.apple/naaf-exit`
pf anchor. The stock `/etc/pf.conf` already has `nat-anchor "com.apple/*"`, so
it is not edited. A LaunchDaemon runs `wg-quick up naaf-exit` at boot, with
Homebrew's bash on `PATH`.

## Hub setup (production, after the code ships)

On `/exit`, delete the current row if there is one. Then add a manual exit with a blank private key (the hub generates one; its pubkey shows in the flash):
- Endpoint `10.8.0.2` : `51821`
- Address `10.99.0.2`
- MTU 1280
- Keepalive 25

The address is checked against `wg_subnet` and site networks (192.168.1.0/24), and it's clear of both.

## Caveats (written into the docs)

- **When brainrot sleeps, every full-tunnel client loses internet.** There's no fallback, on purpose (decision 6). AC sleep is already 0, but battery sleep is still 1, and closing the lid sleeps the Mac unless it's in clamshell mode with a display. Recovery is to disable the exit on `/exit`.
- **brainrot must stay split.** With a full config, its own traffic would loop hub → brainrot → hub.
- Traffic crosses the VPS↔home path twice and is encrypted twice. Throughput is capped by the home uplink.
- DNS still resolves on the VPS (hub passthrough), so geo-DNS sees the VPS while traffic shows the home IP.
- The SOCKS5 proxy follows the exit, so its traffic leaves from home too.
- Everything full-tunnel clients do appears to come from the home IP.

## Verification

1. After each behavior: `bundle exec sus test/app_test.rb`. Then `bundle exec standardrb --fix` and `bin/ci`.
2. Scratch box `NAAF_LABEL=naaf-e2e-exit-client ./deploy.sh --create`, with two netns clients per TROUBLESHOOTING §2:
   - **A** (split) runs the inner wg listener on `:51821` plus `nft` masquerade.
   - **B** is full-tunnel.
   - Add the exit at A's `wg_ip`.
   - `sudo wg show wg-exit` shows a handshake with endpoint `10.8.0.x:51821`.
   - `ip route get 1.1.1.1 from <B> iif wg0` returns `dev wg-exit`.
   - Traffic from B shows up in rx/tx on A's inner interface. Remove A's masquerade and B loses internet, which proves the path.
   - `apply!` twice, with a continuous spoke↔spoke ping across both applies.
   - Over `ssh -L 8080:127.0.0.1:8080`, click each form refusal (`10.8.0.1`, an unknown address, MTU 1400, deleting and disabling A) and check the flash messages and the empty and populated states.
   - Destroy the box afterwards.
3. Production with brainrot: `curl -4 ifconfig.me` from a full client shows the home IP, while the same command on the hub shows the VPS IP. Sleep brainrot and the full client's internet stops; disable the exit and it comes back through WAN.
