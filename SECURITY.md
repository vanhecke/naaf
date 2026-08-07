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
