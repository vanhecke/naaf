# deploy/providers/ — optional conveniences

**Naaf does not need any of this.** It needs a Debian 13 host you can reach as
root over SSH. `deploy/run-remote.sh <ip> sync` and the steps in
`deploy/provision/` are the whole deployment; nothing in the provisioning path
calls a provider API, reads a metadata endpoint, or assumes a network interface
name. The WAN interface is discovered with `ip -o -4 route show to default`, so
`ens3`, `enp1s0`, `eth0` and `eno1` all work with no configuration.

These directories exist because *someone's* box has to be created and *some*
name has to point at it, and a worked example is more useful than a paragraph
describing one. They are two examples, not the supported path.

| directory | what it does | needs |
|---|---|---|
| `vultr/` | create an instance (`--vanilla` or self-provisioning `--auto`); create a firewall group allowing only 22/tcp and the WireGuard port | authenticated `vultr-cli` |
| `dnsimple/` | idempotent A (and optional AAAA) upsert so `NAAF_ENDPOINT_HOST` resolves to the box | authenticated `dnsimple` CLI |

Every account-specific value is a required environment variable with no default.
That is deliberate: a default SSH key id or DNS zone would silently build a box
in — or rewrite a record belonging to — whoever's account was hardcoded. Read the
header comment of each script for its variables; set them in `naaf.conf` under
the `WORKSTATION ONLY` marker so they never travel to a box.

## Adding another provider

One script that creates a box and prints its IP address. Everything downstream —
`run-remote.sh`, the provisioning steps, bring-up — already works against a bare
IP. For a Stage-2 self-provisioning box, hand the provider the user-data script
from `deploy/DEPLOY.md`; it is a plain `#!/bin/bash` cloud-init script with
nothing provider-specific in it.

If you write one for a provider you use, a pull request adding it here is
welcome.
