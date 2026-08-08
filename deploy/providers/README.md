# deploy/providers/ — optional conveniences

**Naaf does not need any of this.** It needs a Debian 13 host you can reach as
root over SSH; `./deploy.sh` does the rest. Nothing in the provisioning path
calls a provider API, reads a metadata endpoint, or assumes a network interface
name. The WAN interface is discovered with `ip -o -4 route show to default`, so
`ens3`, `enp1s0`, `eth0` and `eno1` all work with no configuration.

These directories exist because *someone's* box has to be created and *some*
name has to point at it, and a worked example is more useful than a paragraph
describing one. They are two examples, not the supported path.

| set in `naaf.conf` | directory | what it does | needs |
|---|---|---|---|
| `NAAF_PROVIDER=vultr` | `vultr/` | create an instance and print its IP, behind a firewall group allowing only 22/tcp and the WireGuard port | authenticated `vultr-cli` |
| `NAAF_DNS_PROVIDER=dnsimple` | `dnsimple/` | idempotent A (and optional AAAA) upsert so `NAAF_ENDPOINT_HOST` resolves to the box | authenticated `dnsimple` CLI |

Set either and `./deploy.sh --create` uses it. Leave both blank and you bring
your own box.

Every account-specific value is a required environment variable with no default.
That is deliberate: a default SSH key id or DNS zone would silently build a box
in — or rewrite a record belonging to — whoever's account was hardcoded. Read the
header comment of each script for its variables; set them in `naaf.conf` under
the `WORKSTATION ONLY` marker so they never travel to a box.

## Adding another provider

**One script that creates a box and prints its IP address on stdout.** That one
line is the whole contract — everything downstream works against a bare IP.

```
deploy/providers/<name>/create-box.sh     # prints an IP, logs to stderr
deploy/providers/<name>/update-record.sh  # optional: takes <ipv4> [ipv6]
```

Name it in `NAAF_PROVIDER` and `./deploy.sh --create` picks it up. The box it
creates should be bare Debian 13 — no user-data, no cloud-init, nothing that
would have to be kept in sync with `deploy/provision/`.

If you write one for a provider you use, a pull request adding it here is
welcome.
