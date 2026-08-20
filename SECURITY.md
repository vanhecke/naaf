# Security

## Reporting a vulnerability

Please report security issues privately via GitHub's **Report a vulnerability**
button under the Security tab, rather than opening a public issue.

Include what you did, what happened, and what you expected. If the issue lets an
unauthenticated party reach the admin UI, drive the root helper, or read a
private key, say so up front so it gets triaged first.

## Trust model

This is a control plane for a WireGuard server. It runs as root-adjacent
infrastructure, so the boundaries are deliberate and worth stating.

**One privileged process, with a fixed vocabulary.** The web application never
runs as root and never holds `CAP_NET_ADMIN`. All privileged work goes through a
separate helper daemon on a unix socket, which accepts exactly four commands —
`genkeys`, `apply`, `dump`, `ping`. That list is fixed on purpose: every addition
widens the privilege boundary. The helper never builds a shell string; every
invocation is an argv array.

**The admin UI spawns three unprivileged binaries, and nothing else.** The
Troubleshoot page runs `ping`, `traceroute` and `curl` in the web process, as the
service user. That is the one exception to "no command on the web path", and the
helper's four-command vocabulary is unchanged by it — putting them behind the
socket would widen a root boundary to gain nothing, since none of the three needs
privilege (Debian ships `ping` with `cap_net_raw+ep`; traceroute's default UDP
mode and curl need none). The constraints on that surface:

- Resolved to an **absolute path** from a fixed candidate list, never through
  `PATH`, and invoked as an **argv array** — never a shell string.
- Every user-supplied part goes through an **anchored whitelist** before it
  becomes an argument: the host must match the same hostname class the rest of
  the app uses (which starts `[a-z0-9]`, so a value beginning `-` cannot become
  an argv flag), the scheme is one of `tcp`/`http`/`https`, the port is 1–65535,
  and the path must start with `/` and hold no spaces or control characters.
- The curl URL is **composed server-side from those validated parts**, never
  accepted as a free-form string, and `--proto` pins what curl may speak.
- `169.254.0.0/16` is **refused for curl**, which is how a cloud instance's
  credentials would otherwise leave it. Ping and traceroute cannot carry a
  response body and are not restricted.
- Bounded by a process-wide semaphore (`NAAF_DIAG_CONCURRENCY`, default 2) and a
  hard deadline (`NAAF_DIAG_TIMEOUT`, default 10s) that kills the whole process
  group and always reaps it.
- Output is scrubbed to valid UTF-8, capped at 64 KiB, and HTML-escaped: it is
  remote text on its way to an admin's browser.
- **Kill switch:** `NAAF_DIAG_ENABLED=0` removes the three routes and their
  panels entirely. The flow tester reads only the database and is unaffected.

**Access to the helper socket is access to root-level `wg` and `nft`.** The
socket is mode 0660, owned `root:<service group>`. Anything running as that group
can drive it. There is no second layer of authentication, by design — the group
membership *is* the authorisation.

**The admin UI is tunnel-only.** It binds exactly two addresses: the WireGuard
server IP and `127.0.0.1`. Never `0.0.0.0`, never the public interface. Before a
tunnel exists, reach it over `ssh -L`. A single admin password, bcrypt-hashed in
the database, guards it.

**Client private keys are never persisted.** They are generated server-side by
the helper, rendered exactly once into the download and QR code, and discarded.
The `clients` table has no private key column, and this is structural rather than
a policy — re-downloading a config is impossible on purpose. The *server* private
key does live in the database, is never logged, never rendered into a view, and
never appears in an error message.

**The database is the whole system.** It holds the server private key, every
peer, and every firewall rule. Anyone who can read it can impersonate the server.
Snapshots and replicas inherit that sensitivity — see `docs/BACKUP.md`.

**The firewall is regenerated wholesale.** Application rules live only in the
nftables table this project owns; the static base table that keeps SSH alive is
never touched by application code. No base chain in the app-owned table uses
`policy drop`, because that would silently override other base chains on the same
hook.

## Scope

Out of scope: findings that require an attacker who already has root on the
server or is already an authenticated admin, and reports against a deployment
that has been modified away from the invariants above (for example, binding the
admin UI publicly).
