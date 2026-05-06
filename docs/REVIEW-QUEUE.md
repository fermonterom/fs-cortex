# Review Queue — fs-cortex

Persistent queue of items pending review or follow-up. Read this at the
start of every session so nothing depends on operator memory. Update or
remove entries as they are resolved.

> **Last updated:** 2026-05-06 (after `/cx-status --impact --days 4`)

---

## 🔴 Time-bound — has a target date

### Sprint 5 Gates 1+2 — formal close on 2026-05-09

- **What:** delete `docs/SPRINT-5-PENDING-GATES.md`, drop the
  "Pending validation" reference in `CLAUDE.md`, add a one-line note to
  `CHANGELOG.md` under the next release.
- **Why hold until 2026-05-09:** the agreed measurement window was
  7 clean days post-v3.23.4 (installed 2026-05-04). Today is day 3;
  numbers already pass by 6×–50× margin but the rule is "wait the full
  window".
- **How to confirm before closing:** run the evaluators inside
  `docs/SPRINT-5-PENDING-GATES.md` (Gate 1 + Gate 2 sections). All four
  conditions must say `PASS`.
- **Owner action on 2026-05-09:** ask the operator for the green light,
  then execute the close commit.

---

## 🟡 Process improvements — no deadline but worth doing soon

### v3.24 audit follow-ups

The 4-agent audit on 2026-05-05 produced 7 P0 + 4 P1 fixes that shipped
in v3.24.0/v3.24.1. Re-audit after Gates 1+2 close to confirm none of
the fixes regressed against new data, and to surface anything the audit
missed because the matchers were still warming up.

### Reflex maintenance candidates (read-only signal)

Surfaced by `/cx-status --reflexes` on 2026-05-06:

- **`bash-cat-use-read`** — useful 114, noise 5 (ratio 22.8×). Is
  flagged `NOISY` by absolute-noise rule but the ratio is excellent.
  Do **not** disable. Consider relaxing the absolute-noise heuristic
  in `session-learner.js` so ratio overrides the absolute count when
  ratio ≥ 10×.
- **5 low-useful reflexes** firing without picking up usefulness:
  `git-merge-verify`, `security-headers`, `nextjs-suspense-boundary`,
  `python3-bypass-write-tool`, `git-tag-after-amend`. Either the
  matchers are too narrow or the cohort doesn't run those commands.
  Decide on next `/cx-distill` whether to prune or refine.

### Pending pipeline work

- **`.learn-pending` flag is set** (50+ unprocessed observations).
  Run `/cx-analyze` to surface candidate instincts.
- **5 proposals queued** for `/cx-validate`.
- **Promotion candidates queued** for `/cx-distill`.

These are routine maintenance — not blockers — but if left for weeks
they degrade the signal/noise of every future session.

---

## 🟢 Idea bin — capture, decide later

### Cortex memory.json

Currently missing on this machine. Not a problem for current operation,
but if the system expects it elsewhere, document or stub.

### Status command UX

`/cx-status` (no flags) is great as a debug dump. Consider a
`/cx-status --brief` that prints just: laws count, instincts count,
reflex health summary, pending action items. The full dump is rarely
needed during a working session.

---

## How to use this file

- **Add an entry** when you notice work that should not be lost between
  sessions but doesn't justify a full ticket.
- **Move to a real GitHub issue** if it grows beyond a paragraph.
- **Delete** as soon as the item is resolved — this file is a queue,
  not a log. Use git history if you need the audit trail.
- **Tier:** 🔴 has a date, 🟡 actionable now no deadline, 🟢 ideas.
- **Reference from `CLAUDE.md`** so it loads on every session start.
