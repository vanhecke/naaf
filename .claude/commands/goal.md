---
description: Frame a change as an outcome with explicit acceptance criteria
argument-hint: <what you want to achieve>
---

Frame the following objective before any code is written: **$ARGUMENTS**

Do NOT edit files. Produce a short, testable framing:

1. **Outcome** — one sentence describing the observable end state (what the
   admin, a client, or the kernel can do that it could not before).
2. **Acceptance criteria** — a bullet list of concrete, checkable conditions.
   Prefer conditions phrased as runtime checks from `.claude/commands/verify.md`
   or as a `sus` assertion (e.g. "`dig @10.8.0.1 nas.vpn +short` returns the wg IP",
   "renderer emits `ct status dnat masquerade`").
3. **Out of scope** — what this change explicitly does NOT do.
4. **Boundary check** — name which tier in `AGENTS.md` this touches (Always /
   Ask first / Never). If it hits "Ask first" or "Never", stop and surface that
   before proceeding.

Keep it to the DB→render→apply model: state lives in SQLite, the kernel is a
projection. If the objective implies reading kernel state back into the DB,
call that out as an anti-pattern.
