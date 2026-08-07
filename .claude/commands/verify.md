---
description: Run the full gate (bin/ci) plus the relevant runtime checks
argument-hint: [what changed, to scope the runtime checks]
---

Verify the current state of the tree. Context on what changed: **$ARGUMENTS**

Run and report each result plainly — if something fails, show the output; do
not declare success on a partial pass.

## 1. Static gate (always)
```bash
bin/ci
```
That runs `standardrb`, the `sus` suite, and renders the nftables ruleset
through `nft -c -f` where nft is available.

## 2. Runtime checks (on the server)
Pick the subset that touches what changed and run them on the server. Key ones:

```bash
ss -ltnp | grep ':8080'      # EXACTLY two rows: the wg IP and 127.0.0.1, never 0.0.0.0/::
ss -lunp | grep ':53'        # DNS on the wg IP, not 0.0.0.0
systemctl is-active wgcp wgcp-helper
sudo nft list table inet wgcp    # sets populated, dnat rules present
sudo nft list table inet filter  # static base intact, SSH still allowed
sudo wg show wg0                 # peers listed, handshakes recent
```

For a peer/firewall change, also run the zero-disruption proof: start a
continuous ping between two spokes, apply the change, and confirm **zero**
dropped packets (a drop means something used `wg-quick down/up` instead of
`wg syncconf` — find and fix it).

## 3. Key custody (if client/key handling was touched)
```bash
sudo sqlite3 /var/lib/wgcp/wgcp.db '.schema clients' | grep -i priv  # MUST be empty
sudo grep -ri 'PrivateKey' /var/log/ 2>/dev/null | head              # MUST be empty
```

Summarize pass/fail per check.
