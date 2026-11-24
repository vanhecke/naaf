# Admin UI

The admin UI is one person's console for one WireGuard hub. It is dense on
purpose: the job is to see whether a peer is up, read an address, and change a
row without hunting through a marketing layout.

Presentation only. Routes, parameters, the database, the helper, and nftables
are unchanged. The page is still server-rendered ERB, swapped by htmx and the
SSE extension. There is no application JavaScript and no build step.

`vendor/naaf.css` is the only stylesheet (about 18 KB). Bulma is gone.

## Principles

1. **Say the state in words.** Colour and a glyph reinforce it. A peer is never
   "the green one".
2. **Machine text is monospace.** Keys, addresses, CIDRs, endpoints, ports,
   interface names, and commands.
3. **One accent.** Ink blue for the current section, links, focus, and the
   primary action on a form. Status colours are not the accent.
4. **Hairlines, not shadows.** A panel is a border. A fault colours that border
   and still says what is wrong.
5. **Destructive actions confirm.** Disable, delete, and remove open a
   disclosure; the confirm button is a solid red control. Enable stays a plain
   button.
6. **A private key is shown once.** The clients page says so in a banner that
   cannot be mistaken for a normal notice, and the row that still holds the
   key is marked until the download spends it.
7. **Both themes.** `prefers-color-scheme` selects the palette. `data-theme`
   on the document element overrides it. Text and status colours meet WCAG AA
   against their surfaces.

## Tokens

Type is the system UI face and the system monospace face. No webfonts, no CDN.

| Token | Light | Dark | Use |
|---|---|---|---|
| `--bg` | `#f3f4f0` | `#121513` | page |
| `--surface` | `#ffffff` | `#1b1f1c` | panels, inputs |
| `--ink` | `#1a1e1b` | `#e7ebe6` | text |
| `--muted` | `#3e4a43` | `#b7c2ba` | secondary text |
| `--line` | `#d5dbd4` | `#2e342f` | hairlines |
| `--accent` | `#0f4c81` | `#9ec3ee` | links, current nav, primary button |
| `--ok` | `#0a5c32` | `#8fd4a8` | online, enabled, success |
| `--warn` | `#7a4e00` | `#f0d48a` | idle, caution |
| `--bad` | `#8e1b22` | `#f0b4b4` | failure text and borders |
| `--bad-solid` | `#8e1b22` | `#a32028` | confirm-delete fill (white label) |

Chart series are separate from the accent, so "inbound" is not the same blue
as a link: `--naaf-in` and `--naaf-out`. `Renderers::SVG` emits classes only.

Spacing is a 4px rhythm. Body text is 15px; tables are 13px. Page content
stops at 78rem. Below 900px the section rail wraps into a sticky bar.

## Shell

Signed-in pages are a section rail plus a main column. The rail lists every
admin page and holds **Re-apply state**. The current page is `aria-current`
and the accent bar, not colour alone. A skip link targets `#content`.

Signed-out pages are the sign-in card only. Flash errors are `role="alert"`;
notices are `role="status"`.

## Components

| Class | What it is |
|---|---|
| `.panel` | Bordered block. `.naaf-warn` / `.naaf-alert` colour the border when the contents are in a warning or fault state. |
| `.table` | Full-width, compact, header labels in small caps. `.num` is tabular and right-aligned. `.kv` is a label/value table. |
| `.status` | Pill: word, plus a glyph from `::before` when the variant has one. |
| `.kind` | Quiet label for a type (client, site, tcp, global). Not a health state. |
| `.callout` | A note. `.callout-once` is the one-time key. `.callout-bad` is a fault. `.callout-ok` is a success flash. |
| `.empty` | Dashed empty state. The sentence says what is absent and what still works. |
| `.btn` | Default action. `.btn-primary` submits a change. `.btn-quiet` is the QR link. `.btn-warn` is the password change. `.btn-danger` is the disclosure. `.btn-danger-solid` confirms it. |
| `.btn-row` | Config flavors as one segmented control. The QR link sits at the end, outside the flavor loop. |
| `.confirm` | `<details>` whose summary is the danger control and whose button is the real submit. |
| `.meter` | `<progress>`. The percentage is a sibling, never a child — progress elements do not render their contents. |
| `.naaf-log` | Diagnostic output. Wraps, capped height. |
| `.naaf-busy` | Shown only while the issuing element has `.htmx-request`. |

Focus is a 2px accent outline on `:focus-visible`. The live dot's pulse is
removed under `prefers-reduced-motion`; the word "live" remains.

## Status

The word is the status. The glyph and the tone repeat it.

| Class | Glyph | Word the UI uses | Meaning |
|---|---|---|---|
| `.status-online` | filled circle | online | Enabled peer with a handshake in the last 3 minutes (`Collector::ONLINE_WITHIN`). |
| `.status-idle` | open circle | idle | Enabled, and no handshake in that window. This is the stale / not-currently-connected state. There is no separate "offline" counter. |
| `.status-disabled` | dash | disabled | Turned off. A disabled peer is not installed, even if the kernel still remembers it. |
| `.status-ok` | check | enabled, reconciled, exit 0 | Administrative on, or a check that passed. |
| `.status-warn` | exclamation | backups off, masquerade, overridden, not installed | Needs a look. A site with no networks says "not installed — no networks": WireGuard will not install a peer with empty AllowedIPs. |
| `.status-bad` | cross | reconcile failing, servfail, no client connected | Something is wrong. Reconcile failures do not include the helper's message — that text can contain key material. |
| `.status-role` | none | wan, tunnel, exit | Which interface is which. An interface with no role gets no pill. |

"Enabled" and "online" are different questions. The clients page answers the
first (did you turn it on). The peers table answers the second (is it
handshaking). A disabled peer that last handshook recently still reads
**disabled**.

## Pages

The information on each page is the same as before. What changed is the
hierarchy: a page title, one short lede, then the table or the form.

- **Sign in.** Password, one primary button, no section rail.
- **Dashboard.** Health strip, throughput, DNS, CPU, memory, conntrack, the
  packet pipeline, peers, DNS and top talkers, interfaces and policy, process.
  Fragments still swap over one SSE stream (`hx-ext` stays outside every swap
  target) or poll when `NAAF_METRICS_SSE=0`. Each fragment is also `GET
  /metrics/<name>`.
- **Clients.** Subnet, gateway, and the SOCKS5 listen in the header. Flavor
  buttons, one QR for `split`. Disable and delete confirm. The one-time key
  banner is labelled **Shown once** and the row is tinted until the download.
- **Exposed ports.** One panel per client, including clients with nothing
  exposed. Orphaned rows stay in a `.naaf-warn` panel.
- **Port forwards.** Enabled and disabled are different pills. Disable and
  delete confirm.
- **Sites.** The hub's public key is in the instruction callout. Edit sits
  below the summary line so a wide form cannot shove Delete off the screen.
- **Routes.** Site networks are listed read-only. A CIDR that duplicates a
  site is marked, not hidden.
- **DNS.** Automatic records, static records, conditional forwarding. Site-owned
  forwarders link back to Sites.
- **Internet exit.** The empty page is where Cloudflare WARP registration and
  the manual form live. A configured exit is one record, with the same
  disable/delete confirmation. An exit reached through a VPN client says which
  client, because that client cannot be removed while the exit is on.
- **Troubleshoot.** Ping, traceroute, and curl when diagnostics are enabled,
  then the flow tester. Output is a log block with an exit status.
- **Settings.** Editable endpoint and DNS, then a read-only table (subnet,
  gateway, SOCKS5, listen port, server public key, last backup). Certificates
  are not a page: provisioning owns `/etc/naaf/certs` (`docs/CERTS.md`).
  wstunnel is not a page either: it appears as the `split·ws` flavors, and as
  a fault callout when it is enabled but not provisioned. The password change
  is a warning button on its own form — typing the new password is the
  confirmation. Client key reissue is delete-and-readd, which confirms.

## What this file does not change

No new routes, no new client script, no metrics table, no private-key column.
Dashboard history is still the in-memory rings. The helper's vocabulary is
still genkeys, apply, dump, and ping.
