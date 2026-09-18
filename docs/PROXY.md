# SOCKS5 proxy

A tunnel-only SOCKS5 listen on the hub IP so split clients can send individual
apps through the box without a full-tunnel config.

```
Laptop (split) --wg--> 10.8.0.1:1080 microsocks --> WAN (or wg-exit)
```

TCP CONNECT only. No UDP ASSOCIATE. The tunnel is the auth: the process binds
`settings.server_ip` only, never `0.0.0.0`, never the WAN. The base firewall
does not grow a hole — `iifname wg0 accept` already covers it.

## Use

With a split config up:

```sh
curl --socks5-hostname 10.8.0.1:1080 https://ifconfig.me
```

Firefox: Settings → Network → Manual proxy → SOCKS5 host `10.8.0.1` port `1080`,
and tick “Proxy DNS when using SOCKS v5”. `gateway.<dns_domain>:1080` resolves
to the same address.

## Egress

Without an internet exit, destinations see the VPS WAN IP.

With an internet exit enabled, proxy traffic follows `wg-exit` (uid-scoped
`ip rule`s). SSH, ACME, Litestream, Troubleshoot ping/curl, and the WARP
handshake stay on the VPS WAN — they are not the `naaf-proxy` uid.

## Disable

```
NAAF_PROXY_ENABLED=0
./deploy.sh --step 66-socks
```

That removes the unit and, on the next apply, the uid rules. The `microsocks`
package and the `naaf-proxy` user are left in place.
