# SOCKS5 proxy

A tunnel-only SOCKS5 listen on the hub IP so split clients can send
individual apps through the box without a full-tunnel config.

```
Laptop (split) --wg--> 10.8.0.1:1080 microsocks --(uid rule)--> WAN or wg-exit
```

Split clients already route `wg_subnet`. No AllowedIPs, flavor, extra_route,
or `inet naaf` input change. Base `inet filter` already has `iifname wg0 accept`.

Do not relitigate the decisions below. Branch: `feat/socks-proxy`.

---

## Decisions

1. **SOCKS5 only.** Debian 13 `microsocks`. TCP CONNECT + remote DNS. No UDP,
   no HTTP CONNECT, no gem, not on the Falcon/DNS reactor.
2. **Bind `settings.server_ip:NAAF_PROXY_PORT` only.** Never `0.0.0.0`, never
   WAN. No base-firewall hole. `reserved_port_owner` unchanged (same class as
   `NAAF_WEB_PORT`).
3. **Auth is the tunnel.** No SOCKS user/pass.
4. **Egress follows the internet exit** when one is up; otherwise WAN. SSH,
   ACME, Litestream, Troubleshoot, and the WARP handshake stay on WAN — they
   are not the proxy uid.
5. **Dedicated `naaf-proxy` system user**, not `User=naaf`, not `DynamicUser`.
   Stable uid is required for `ip rule uidrange`. No `PrivateUsers=`.
6. **`naaf.conf`, not the DB.** No schema, no UI toggle. Default **on**.
7. **Helper vocabulary unchanged.** Optional `proxy` object on the existing
   `exit` payload. `rules` stays exactly prefs `15800/15850/15900`. An older
   helper ignores `proxy` and the proxy stays on WAN.
8. **Step `66-socks.sh`**, unit `naaf-proxy.service`. Do not steal CERTS.md
   §9's `70-proxy.sh` name (that sketch is `70-tls-proxy` / `naaf-tls-proxy`).

---

## Routing (exit up)

```
pref 15800  fwmark 159 lookup main
pref 15850  iif wg0 to $wg_subnet lookup main
pref 15870  uidrange UID-UID to 127.0.0.0/8 lookup main
pref 15875  uidrange UID-UID to $wg_subnet lookup main
pref 15880  uidrange UID-UID lookup 159
pref 15900  iif wg0 lookup 159
```

`15870`/`15875` keep systemd-resolved and spoke/hub dests on main. Do **not**
`raise_if_steals!` those locals — `127.0.0.0/8` covers `lo`, and these rules
*keep* dests on main rather than stealing WAN.

When exit is down, all six prefs go away; proxy uses main → WAN.

---

## Never

- Bind `0.0.0.0` / WAN, or open tcp/1080 on `inet filter`.
- A new helper command; putting the new prefs in `exit.rules` (old helper
  would reject the whole apply).
- `User=naaf`, `DynamicUser`, or `PrivateUsers=` on the proxy unit.
- `meta skuid` in nft (breaks `nft -c -f` where the user does not exist).
- Bulk proxying on the shared reactor.
