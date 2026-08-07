# deploy/ — server-side artifacts

These files are **not** loaded by the application. They are versioned copies of
the host configuration installed on the Debian 13 VPS during setup — see
[`DEPLOY.md`](DEPLOY.md) for the full flow, which installs all of them for you.
Keeping them in the repo makes the deployment reviewable and reproducible. Paths
below assume the app lives at `/opt/naaf`.

| repo file | install to | notes |
|---|---|---|
| `../naaf.conf.example` | `/etc/naaf/naaf.conf` | The one config file, 0640 root:naaf. `EnvironmentFile=` for both units. `40-app.sh` fills in a generated session secret and strips the workstation-only section. |
| `nftables.conf.template` | `/etc/nftables.conf` | Static base firewall (table `inet filter`). Rendered by `20-system.sh` with the WireGuard port and interface from `naaf.conf`, checked with `nft -c -f` **before** installing. App-owned rules live in `inet naaf` and never touch this file. |
| `sysctl-99-naaf.conf` | `/etc/sysctl.d/99-naaf.conf` | IPv4 forwarding on, IPv6 forwarding off. `sysctl --system`. |
| `tmpfiles-naaf.conf` | `/etc/tmpfiles.d/naaf.conf` | Recreates `/run/naaf` (socket dir) at boot. `systemd-tmpfiles --create`. |
| `naaf-helper.service` | `/etc/systemd/system/naaf-helper.service` | The only privileged unit (`User=root`). |
| `naaf.service` | `/etc/systemd/system/naaf.service` | Unprivileged app (`User=naaf`, `CAP_NET_BIND_SERVICE` only, `RUBY_YJIT_ENABLE=1`). |

Both `.service` files and the nftables file are **templates**: the `__NAAF_*__`
placeholders are substituted from `naaf.conf` at install time, so the Ruby path,
the app and state directories, the service user, the WireGuard interface and the
listen port all come from one place. Do not install them verbatim.

## Bring-up (abridged — `deploy/provision/50-bringup.sh` does this for you)

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
