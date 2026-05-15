# Sinapsis (v4.5.0) vs fs-cortex (v3.28.9) — Architectural Comparison

**Investigation date:** 2026-05-15 (Día 0 of Sprint 8)
**Source:** Sonnet read-only spike over `/Users/fmm/github/sinapsis`
**Verdict:** `inspiring_patterns` — NOT `superior_architecture` (no abort of v3.29 needed)

---

## Executive verdict

Sinapsis and fs-cortex solve the **same problem** (continuous learning for Claude Code) with the **same hook topology** (PreToolUse inject + PostToolUse observe + Stop learn). Sinapsis is 1-2 versions ahead on specific engineering pain points but is **not a fundamentally superior architecture**. Critically, Sinapsis v4.3.3 explicitly back-ported 5 features FROM fs-cortex v3.10 (downvote, multi-session promote, repetition detector, agent-pattern detector, path-traversal protection) — the relationship is bidirectional, not one-way obsolescence.

**Decision:** continue Sprint 8 v3.29 as planned, import 2 critical patterns from Sinapsis, defer 4 nice-to-have patterns to v3.30+.

---

## Pattern inventory (6 patterns)

| # | Pattern | Severity | Target release |
|---|---------|----------|----------------|
| 1 | **PreCompact hook** — flushes session-learner before context compaction. Prevents observation data loss in long sessions | 🔴 HIGH | **v3.29.0 (Sprint 8 §4.15)** |
| 2 | **Multi-session promotion gate** — `distinct_sessions >= 3 AND occurrences >= N` before draft→confirmed. Prevents single-session noise promotion | 🟡 MEDIUM | **v3.29.0 (Sprint 8 §5.3 + new gate in distill_engine.py)** |
| 3 | **Atomic O_EXCL lock + tmp+rename** — for any shared JSON write from Stop hooks under parallel sessions | 🟡 MEDIUM | v3.30 |
| 4 | **Confidence decay cycle** — `confirmed inactive 60d → draft, draft inactive 90d → archived`. Prevents instinct index bloat | 🟡 MEDIUM | v3.30 (partial decay exists in cortex but not the confirmed→draft step) |
| 5 | **Single-pass Node.js detector block** — single runtime, no multi-tool regex dispatch | 🟢 LOW | v3.30 (cortex v3.29 detector rewrites already eliminate the worst symptom) |
| 6 | **`id.localeCompare` tiebreaker** — byte-stable systemMessage prefix enables Opus 4.7 prompt-cache hits (~90% token cost reduction on instinct payload) | 🟢 LOW | v3.30+ |

---

## Shared concepts (overlap)

- Observations (`observations.jsonl` per project hash)
- Proposals (`_instinct-proposals.json` / `proposals.json`)
- Instincts with confidence levels (draft/confirmed/permanent)
- Passive rules (always-on guardrails)
- Instinct injection via PreToolUse systemMessage
- Stop hook session-learner
- EOD session summaries
- Dream cycle (index hygiene)
- Downvote / feedback loop
- Backup/restore
- Promote (project → global scope)
- Skill router
- Operator state / cross-project context

## What Sinapsis does that cortex does NOT (today)

- PreCompact hook (data loss vector)
- Confidence decay confirmed→draft (cortex only archives at very low conf)
- Multi-session promotion gate (cortex promotes on total hits, ignoring session distribution)
- Cache-stable instinct ordering (Opus prompt-cache prerequisite)
- HTML observability dashboard at v4.5 polish level (cortex has /cx-dashboard but parity unclear)
- Atomic O_EXCL locks (cortex relies on `flock` in distill_engine but not in session-learner.js writes)
- Single Node.js runtime for detectors (cortex mixes Python + bash + JS)

## What cortex has that Sinapsis does NOT

- Laws layer (injected at SessionStart, ~300 tokens, separate from instincts)
- `/cx-analyze` with Opus 1M for deep cross-project pattern detection (Sinapsis RFC for this exists but is opt-in / unimplemented)
- Cortex impact funnel (`impact.jsonl` with inject → follow → outcome events for nudge ranking)
- v3.27.0 detectors (cross-day boost, time-of-day patterns) — Sinapsis doesn't have these
- v3.28.9 detector matrix decisions (this Sprint)

## Decision rationale

**Why NOT abort:**
- Sinapsis is not architecturally superior; it's better-engineered in specific pain points
- Migrating would lose cortex's unique capabilities (laws layer, /cx-analyze, impact funnel)
- The bidirectional learning history (Sinapsis ← cortex v3.10) suggests the right pattern is **cross-pollination, not replacement**

**Why import #1 (PreCompact) urgently:**
- Real data loss risk: long sessions get compacted by Claude Code without giving Stop hook a chance to run on the discarded observations
- 31 lines of bash, fire-and-forget, 8s cap — minimal risk addition

**Why import #2 (multi-session gate) in v3.29:**
- The detector rewrites in v3.29 produce HUMAN-gated proposals; the gate to AUTO promotion (v3.30) needs to be statistically robust
- `distinct_sessions >= 3` prevents the case where one heavy session creates noise that looks like signal

**Why defer #3-6:**
- Nice-to-have. Sprint 8 should not bloat. v3.30 is the natural home for performance + reliability polish.

---

## References

- Sinapsis repo: `/Users/fmm/github/sinapsis` (v4.5.0)
- Sinapsis README (back-port acknowledgement): v4.3.3 section
- Sinapsis PreCompact: `core/_precompact-guard.sh`
- Sinapsis promotion gate: `core/_instinct-activator.sh:43-63`
- Sinapsis atomic writes: `core/_session-learner.sh:157-227`

This document is kept as long-term reference. Delete only if Sinapsis is sunset or cortex absorbs all 6 patterns.
