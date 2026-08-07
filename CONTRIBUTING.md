# Contributing

Read **[AGENTS.md](AGENTS.md)** first. It is the real conventions document —
architecture invariants, the frontend rules, secrets handling, and a three-tier
boundary list (Always / Ask first / Never). It is short, and the Never tier
exists because each entry has a specific failure behind it.

## The loop

```sh
git checkout -b feat/<thing>
bundle install
bundle exec sus                 # tests
bundle exec standardrb --fix    # style; standardrb is the single authority
bin/ci                          # the full gate: standardrb + sus + an nft render check
```

`bin/ci` must be green before a change is done. There is no `.rubocop.yml` and no
arguing with standardrb.

## What a good change looks like

- **Branch per change.** Commits are `<type>: <imperative ~60 chars>`.
- **Renderers are pure functions of the database.** Every renderer change needs a
  test asserting the emitted text. `nft -c -f` is the real validator for firewall
  output — `bin/ci` runs it where nftables is available.
- **Mutations follow one path**: write the DB, then `Reconciler#apply!`, then the
  helper, then the kernel. Never read kernel state to populate the DB; the kernel
  is a projection. Only handshake and traffic stats flow inward.
- **New long-running work is an `Async` task on the existing reactor** — not a
  new process, not a Thread. Everything runs on one shared reactor in one process.
- **No client-side JavaScript** beyond the vendored htmx. No app `.js` file, no
  inline `<script>`, no framework, no Node, no npm, no package.json. If something
  seems to need scripting, move the behaviour to the server.

## Things to ask about first

Opening an issue before writing the code will save you time on: any change to the
helper daemon's command vocabulary or privileges, schema changes, changing the
WireGuard subnet, anything touching server private key handling, and adding a
gem.

## Security

Do not open a public issue for a vulnerability — see [SECURITY.md](SECURITY.md).
