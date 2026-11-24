# Admin UX

The admin UI is a station log. The operator's job is to see who is up, open
that peer, and change what that peer is allowed to do. Pages are grouped that
way. The data model, the helper, the renderers, and the meaning of each POST
are unchanged; this document is only about where those operations live.

## Navigation

| Group | Item | Path |
|---|---|---|
| Observe | Dashboard | `/` |
| Observe | Troubleshoot | `/troubleshoot` |
| Peers | Clients | `/clients` |
| Peers | Client | `/clients/:id` |
| Peers | Sites | `/sites` |
| Peers | Site | `/sites/:id` |
| Peers | Internet exit | `/exit` |
| Zone | DNS | `/dns-records` |
| Policy | Exposed ports | `/exposed-ports` |
| Policy | Port forwards | `/port-forwards` |
| Policy | Routes | `/extra-routes` |
| System | Settings | `/settings` |

Policy stays reachable as its own pages — a cross-peer list is still the
fastest way to see every forward — and the same forms also sit on the peer
that owns the row. Re-apply stays in the plate, posting to `/apply`.

Keyboard, when focus is not in a field: `/` focuses search, `?` opens the
shortcut list, `g` then `d c s n e t ,` jumps to dashboard, clients, sites,
DNS, exit, troubleshoot, settings. The same list is in the footer without
script.

Light and dark are a posted preference (`POST /theme`), stored in the session.
With no preference the page follows the OS.

## Status

A peer is one of five states. The word and the mark are the meaning; the hue
is a second channel.

| State | Code | Mark | When |
|---|---|---|---|
| Online | ONL | filled circle | Enabled, handshake within 3 minutes |
| Stale | STL | half circle | Enabled, handshake within 2 hours |
| Offline | OFF | hollow circle | Enabled, older than that, or never |
| Disabled | DIS | dash, hatched badge | The admin switched the peer off |
| No networks | NON | hollow, hatched | A site with an empty AllowedIPs set, so it is not installed |

The collector's `online` flag is still the 3-minute cut the stall detector
reads. The split between stale and offline is display only.

## Flows

### Add a client

Before: the form sat under the list. A successful POST returned to `/clients`
with a banner, and the key existed only inside the download and the QR.

After: the form is still on the list (search and status sit above it). A
successful POST lands on `/clients/:id`. That page is the one-time step: the
banner, the split QR (it peeks, it does not spend the key), and the flavor
downloads (the first download spends the key). The private key is still not
written into the HTML and still not stored.

### Expose a port

Before: `/exposed-ports` was a page of every client, with one form at the
bottom that named the client in a select.

After: the same page remains, for the cross-peer view. On `/clients/:id` the
form has no client select — the client is the page — and posts to the same
`/exposed-ports` with `next=/clients/:id`, so apply returns to the peer.
Delete still posts to `/exposed-ports/:id/delete`.

### Toggle and delete

Before: both posted from the list and returned to the list. Delete asked for
a second click via `<details>`.

After: the list and the detail both post to the same URLs. A hidden `next`
sends the operator back to the page they started on, when it is a same-origin
path under this app; otherwise the historical destination is used. Delete
still requires the confirm control, and the confirm names the peer. Nothing
is deleted by the first click.

### Find a client

Before: the list was every client, ordered by address.

After: `q` matches name, hostname, address, and public key. `status` is one
of the five states. `sort` is address (default), name, or handshake. The
controls are a GET form. htmx refetches the roster as the query changes and
pushes the URL, so a filtered list can be reloaded. An idle unfiltered roster
refreshes itself every 30 seconds. The health line on the clients, sites, and
detail pages is the dashboard's SSE `health` event.

### Sites, DNS, exit, routes

Before: each was one long page and the only place its forms existed.

After: `/sites/:id` is one site — networks, forwarded domains, masquerade,
edit, enable, delete. The list links there. DNS, exit, and routes keep their
URLs and their fields. A client's detail lists that client's forwards, extra
routes, and A records, and links to the zone for anything that is not theirs.

## What did not move

Login, the session gate, CSRF, the one-shot key stash, config and QR
downloads, the reconciler's apply after a write, the helper's commands, and
the bind addresses. A form that used to insert a row still inserts that row.
