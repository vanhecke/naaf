---
description: Produce a read-only file + test plan for a feature (no edits)
argument-hint: <feature to plan>
---

Plan the implementation of: **$ARGUMENTS**

This is a READ-ONLY step. Do not modify any files. Read the relevant sources
first (`lib/naaf/`, `db/schema.rb`, `views/`, existing `test/`), then output:

1. **Files to change / create** — each path with a one-line reason. Distinguish
   renderers (pure), the app (Roda routes), the reconciler, and views.
2. **Data model impact** — any `db/schema.rb` change. Schema changes are an
   "Ask first" item in `AGENTS.md`; flag them and wait for approval.
3. **Apply path** — confirm the change flows DB write → `Reconciler#apply!` →
   helper → kernel, and that no renderer gains a side effect.
4. **Tests** — the exact `sus` files and the specific assertions to add. Every
   renderer change needs a test asserting the emitted text; firewall output must
   be validated with `nft -c -f`.
5. **Privilege check** — confirm nothing needs a new helper command or new
   capability. If it does, stop: that is an "Ask first" boundary.
6. **Verification** — which runtime checks from `.claude/commands/verify.md` prove
   it works.

Present the plan and wait for approval before implementing.
