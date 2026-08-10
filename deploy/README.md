# deploy/ — server-side artifacts

These files are **not** loaded by the application. They are versioned copies of
the host configuration installed on the Debian 13 VPS during setup — `./deploy.sh`
installs all of them for you; see [`DEPLOY.md`](DEPLOY.md). Keeping them in the
repo makes the deployment reviewable and reproducible. Paths below assume the app
lives at `/opt/naaf`.

| repo file | install to | notes |
|---|---|---|
| `../naaf.conf.example` | `/etc/naaf/naaf.conf` | The one config file, 0640 root:naaf. `EnvironmentFile=` for both units. `deploy.sh` installs your copy with the workstation-only section stripped; `40-app.sh` fills in a generated session secret and appends keys new in a release. |
| `nftables.conf.template` | `/etc/nftables.conf` | Static base firewall (table `inet filter`). Rendered by `20-system.sh` with the WireGuard port and interface from `naaf.conf`, plus a conditional `tcp dport <wstunnel port> accept` that becomes a bare comment unless `NAAF_WSTUNNEL_ENABLED=1`. Checked with `nft -c -f` **before** installing. tcp/80 is never opened: ACME is DNS-01. App-owned rules live in `inet naaf` and never touch this file. |
| `sysctl-99-naaf.conf` | `/etc/sysctl.d/99-naaf.conf` | IPv4 forwarding on, IPv6 forwarding off. `sysctl --system`. |
| `tmpfiles-naaf.conf` | `/etc/tmpfiles.d/naaf.conf` | Recreates `/run/naaf` (socket dir) at boot. `systemd-tmpfiles --create`. |
| `naaf-helper.service` | `/etc/systemd/system/naaf-helper.service` | The only privileged unit (`User=root`). |
| `naaf.service` | `/etc/systemd/system/naaf.service` | Unprivileged app (`User=naaf`, `CAP_NET_BIND_SERVICE` only, `RUBY_YJIT_ENABLE=1`). Also pulls in `-/etc/naaf/wstunnel.env` for the path prefix, which is deliberately not a `naaf.conf` key. |
| `naaf-wstunnel.service` | `/etc/systemd/system/naaf-wstunnel.service` | Optional TLS-WebSocket transport (`DynamicUser=yes`, never `naaf` — it faces the public internet and holds no state). Installed by **`65-wstunnel.sh`**, not `40-app.sh`: it shares none of that loop's six placeholders, and unlike the other two it must be absent from disk entirely unless `NAAF_WSTUNNEL_ENABLED=1`. |
| `naaf-cert-reload.sh` | `/usr/local/sbin/naaf-cert-reload` | Installed without the `.sh` by `60-certs.sh` (the suffix exists only so `bin/ci`'s shellcheck glob catches it). Restarts every unit registered in a certificate's `consumers.d/`; acme.sh's `--reloadcmd` is its only caller. |

The three `.service` files and the nftables file are **templates**: the
`__NAAF_*__` placeholders are substituted from `naaf.conf` at install time, so the
Ruby path, the app and state directories, the service user, the WireGuard
interface and both listen ports all come from one place. Do not install them
verbatim. `20-system.sh` and `65-wstunnel.sh` grep the rendered file for a
leftover `__NAAF_` and refuse to install it; `40-app.sh` does not, so a typo in
one of its six placeholder names shows up as a unit that fails to start.

## Bring-up (abridged — `50-bringup.sh` does this for you, as part of `./deploy.sh`)

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now naaf-helper
cd /opt/naaf && sudo -u naaf -E bundle exec ruby bin/bootstrap.rb   # sets keys + admin pw
sudo systemctl enable --now naaf          # first apply writes /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
sudo systemctl status naaf --no-pager
```

`deploy/providers/` holds optional per-provider helpers for creating a box and
pointing DNS at it. Nothing in the list above needs them.

First-run admin access before any tunnel exists:

```bash
ssh -L 8080:127.0.0.1:8080 <vps>    # then open http://localhost:8080
```
