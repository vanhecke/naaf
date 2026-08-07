# deploy/ — server-side artifacts

These files are **not** loaded by the application. They are versioned copies of
the host configuration installed on the Debian 13 VPS during setup — see
[`DEPLOY.md`](DEPLOY.md) for the full flow, which installs all of them for you.
Keeping them in the repo makes the deployment reviewable and reproducible. Paths
below assume the app lives at `/opt/naaf`.

| repo file | install to | notes |
|---|---|---|
| `nftables.conf` | `/etc/nftables.conf` | Static base firewall (table `inet filter`). App-owned rules live in `inet naaf` and never touch this. `nft -c -f` then `systemctl enable --now nftables`. |
| `sysctl-99-naaf.conf` | `/etc/sysctl.d/99-naaf.conf` | IPv4 forwarding on, IPv6 forwarding off. `sysctl --system`. |
| `tmpfiles-naaf.conf` | `/etc/tmpfiles.d/naaf.conf` | Recreates `/run/naaf` (socket dir) at boot. `systemd-tmpfiles --create`. |
| `naaf-helper.service` | `/etc/systemd/system/naaf-helper.service` | The only privileged unit (`User=root`). |
| `naaf.service` | `/etc/systemd/system/naaf.service` | Unprivileged app (`User=naaf`, `CAP_NET_BIND_SERVICE` only, `RUBY_YJIT_ENABLE=1`). |

The systemd units reference `/opt/rubies/ruby-4.0.6/bin/ruby` — the path
`ruby-install` produces on the server. Confirm with `ls /opt/rubies/` and adjust
both units if it differs.

## Bring-up (abridged — `deploy/provision/50-bringup.sh` does this for you)

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now naaf-helper
cd /opt/naaf && sudo -u naaf -E bundle exec ruby bin/bootstrap.rb   # sets keys + admin pw
sudo systemctl enable --now naaf          # first apply writes /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
sudo systemctl status naaf --no-pager
```

First-run admin access before any tunnel exists:

```bash
ssh -L 8080:127.0.0.1:8080 <vps>    # then open http://localhost:8080
```
