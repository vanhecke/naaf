# Design

The admin UI is the Bay direction: a warm paper station log, strips for
peers, and a serif name beside monospace facts. `vendor/naaf.css` is the only
stylesheet. There is no Bulma and no build step.

## Principles

The page is an instrument, not a brochure. Density is a feature. A number
that could not be measured is an em dash, never a zero. Color repeats a word
that is already there. Destructive actions name their target and wait for a
second click. The private key of a client is shown in the download and the
QR, not in the HTML.

## Tokens

Light is the paper. Dark is the same objects with the ink reversed. Both are
chosen so body text and the status words clear WCAG AA (4.5:1) against their
own badge.

| Token | Light | Dark | Use |
|---|---|---|---|
| Bay | `#e6e2d6` | `#141311` | Page |
| Paper | `#f7f4ec` | `#221f1a` | Plate, sheets |
| Strip | `#fbfaf6` | `#2c2822` | Peer strips |
| Ink | `#1c1b18` | `#f4efe4` | Text |
| Muted | `#5e584e` | `#c2baab` | Secondary text |
| Line | `#d0c8b6` | `#453f36` | Rules |
| Online | `#0f5c30` on `#e4f3ea` | `#b7e7c8` on `#173224` | ONL |
| Stale | `#7a4e00` on `#f8edd4` | `#f3d59a` on `#3a2e14` | STL |
| Offline | `#8a2e2e` on `#f8e4e1` | `#f3b7b0` on `#3d221e` | OFF |
| Disabled | `#5c574e` on `#eceae3` | `#c2baab` on `#2e2b26` | DIS, hatched |
| Accent | `#0f5c30` fill, white label | `#b7e7c8` fill, `#102116` label | Primary actions |

`--naaf-in` follows online. `--naaf-out` follows stale, and the outbound
series is also dashed, so the duplex chart is not identified by hue alone.
A strip tints the sparkline that sits on it: the row's status color replaces
the inbound stroke.

Focus is a 2px accent outline, offset 2px, on buttons, links, and fields.
`prefers-reduced-motion` stops the live dot.

## Components

- **Plate.** The top of every page: the wordmark, the task nav, policy as a
  second quieter row, Re-apply, and the theme control.
- **Strip.** One peer. A badge on the left carries the mark, the code, and
  the status color. The name is serif. Addresses, keys, and rates are mono.
- **Sheet.** A bordered paper block for a form or a table that is not a peer.
- **Banner.** A full-width note. The one-time key uses the stale hue because
  it expires. A fault uses the offline hue.
- **Confirm.** A `<details>` whose summary is the quiet danger control and
  whose body names the object and holds the real submit.
- **Live.** The word "live" plus a dot. The health line is an SSE target.

## Status semantics

See `docs/UX.md`. The code, the mark, and the word ship together. Hatching is
reserved for "not installed" (disabled, or a site with no networks). Online
is the only green, stale the only amber, offline the only red.

## Type

Liberation Serif for the wordmark and peer names. Liberation Sans for the
UI. JetBrains Mono for keys, addresses, CIDRs, and figures. Tabular numbers
on the figures.

## Files

- `vendor/naaf.css` — this system, served by Roda's public plugin.
- `vendor/naaf.js` — keyboard focus and navigation only. htmx and its SSE
  extension remain the other two scripts.
- `vendor/htmx.min.js`, `vendor/htmx-ext-sse.min.js` — unchanged, digest
  pinned.
