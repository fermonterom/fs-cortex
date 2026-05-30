# Sprint v3.34 — Plan (DRAFT for next session)

**Status:** DRAFT — created 2026-05-30 right after v3.33.0 shipped (PR #50).
**Author:** session that fixed the post-ship session_id bug. This session is
nearly context-exhausted; this doc is the handoff so a fresh session can
execute v3.34 cold.
**Prereq:** PR #50 (v3.33.0) merged to main + `bash install.sh` run.

---

## 0. Read this first (cold-start context)

Two things happened across the prior sessions that frame v3.34:

1. **v3.32.0 shipped a HUMAN→AUTO promotion gate that was structurally
   dead** because the producer never wrote `session_id`. v3.33.0 (PR #50)
   fixed the propagation end-to-end. The gate now CAN collect signal going
   forward — but it has not yet, because no detector has accumulated n≥20
   reviewed since the fix.

2. **The operator's real complaint** — "llevo un mes sin avanzar, Cortex
   está estancado" — is NOT primarily the session_id bug. Two independent
   bottlenecks were discovered with live data and remain UNADDRESSED:
   - **Laws cap saturated 15/15.** Even with the gate fixed, no instinct
     can promote to LAW without deprecating an existing one. The
     `/cx-distill --swap` machinery exists (v3.32.0) but has never been
     exercised on real data.
   - **307+ pending proposals**, ~160 of them auto-generated noise
     (`coupling-*`, `gotcha-Tool-hash`). `/cx-validate` is unusable until
     this is triaged. The §4.1.B harvest already proved the dominant skip
     reasons are `needs-human-judgment` (503) + `already-instinct` (93).

**Strategic note for whoever runs v3.34:** the backfill (`/cx-backfill`)
recovers **0 promotions** on the operator's current corpus
(`newly_eligible=0`, verified by dry-run on real data). So enabling
`--apply` (#49) is correctness work, NOT a value unlock. The real value
unlock for the operator is **P0/P1 below (cap + pending triage)**, not the
backfill. Sequence accordingly: do the unblock first, the backfill
hardening second.

---

## 1. The 5 open GitHub issues (all verified NOT fixed by v3.33.0)

Audited 2026-05-30 against the working tree — none are addressed:

| # | Title | Evidence it's open | Priority here |
|---|-------|--------------------|---------------|
| [#49](https://github.com/fermonterom/fs-cortex/issues/49) | enable `/cx-backfill --apply` (P0 write race + 2 P2) | `--apply` gated off at distill_engine.py:2649 | P2 |
| [#45](https://github.com/fermonterom/fs-cortex/issues/45) | LOCK_FILE wrap for `manual_promote_detector` + `manual_swap_promote` | 0 flock refs in those fns | P2 |
| [#46](https://github.com/fermonterom/fs-cortex/issues/46) | regression test for future schema v2 of `.promoted-detectors.json` | 0 schema-v2 tests | P3 |
| [#47](https://github.com/fermonterom/fs-cortex/issues/47) | chmod 0o600 on `~/.claude/cortex/log/*.jsonl` | 0 chmod in distill_engine.py | P3 |
| [#48](https://github.com/fermonterom/fs-cortex/issues/48) | trust-boundary doc in `cx-promote.md` | 0 "trust boundary" in cx-promote.md | P3 |

**Do NOT close any of these before the work lands** — closing unfixed
issues was explicitly rejected this session.

---

## 2. Root architectural problem behind #49 + #45 (the real design work)

Both #49 and #45 are symptoms of one missing abstraction: **there is no
shared write-lock between the Stop hook and the distill engine.**

- `hooks/session-learner.js` appends to `proposals-history.jsonl` via
  `appendFileSync` and writes `instinct-tracking.json` via `_flushTracking`
  — neither takes `LOCK_FILE`.
- `hooks/lib/distill_engine.py` has `LOCK_FILE = CORTEX_DIR /
  '.distill-engine.lock'` but `manual_promote_detector`,
  `manual_swap_promote`, and `backfill_session_data` don't use it.
- So any "lock on the engine side only" is illusory — the JS Stop hook
  races it. This is why v3.33.0 GATED `--apply` instead of shipping a
  one-sided lock.

**v3.34 P0 decision (needs operator confirmation):** pick ONE of —
- **(A) Shared advisory lock**: both the JS Stop hook AND the Python engine
  take `flock` on `LOCK_FILE` before touching `proposals-history.jsonl` /
  `instinct-tracking.json`. Cross-language (Node `fs` + Python `fcntl`,
  msvcrt fallback on Windows). Cleanest, but touches the hot Stop path.
- **(B) Quiescence requirement**: `/cx-backfill --apply` and
  `/cx-promote --auto` refuse to run unless no Stop hook has fired in the
  last N seconds (mtime check on a heartbeat marker), and document
  "run while idle". Simpler, no Stop-path change, but operationally fragile.

Recommendation: **(A)** for correctness, but it is the biggest single
change in v3.34 — scope it carefully and AD it (Codex GPT-5.5) before
implementing. (B) is acceptable as a v3.34.0 stopgap if (A) proves too big.

---

## 3. Priorities

### P0 — Unblock the operator's actual stuck state (NOT in any issue yet)

This is the work that makes Cortex "advance again". Two parts:

**P0.a — Laws cap triage (15/15 saturated).**
- Run `/cx-distill` to surface the deprecation candidates the engine
  already computes (`_find_least_impactful_law`, v3.32.0).
- For each conf≥0.95 instinct currently blocked by the cap, decide:
  promote-by-swap (deprecate the least-impactful law via `/cx-distill
  --swap <old> <new> --confirm`) or leave as instinct.
- Open question to answer with data: is 15 the right cap, or should it
  rise to 18-20 now that token budgets allow? Measure SessionStart token
  cost at 15 vs proposed before deciding.

**P0.b — Pending proposals triage (307+, ~160 noise).**
- Build/extend a `/cx-audit` pass that buckets `proposals.json` by
  id-pattern (`coupling-*`, `gotcha-Tool-hash`, named) and bulk-archives
  the auto-generated noise so `/cx-validate` becomes usable.
- Root-cause the `already-instinct` re-emissions (93 in the §4.1.B harvest):
  add dedup at the emitter (session-learner.js detectors) so the same
  pattern isn't re-proposed every Stop. This is the B3 follow-up from the
  original Sprint 9 plan.
- Consider raising `VALIDATE_MIN_CONF` if `low-confidence` dominates a
  fresh harvest (re-read `auto-validate-skips.jsonl` first — decide with
  data, not assumption).

### P1 — Verify the v3.33.0 fix actually works in the wild

- After 7 days of real sessions post-v3.33.0, re-run the dry-run analysis:
  do `session-learner:*` sources now accumulate real `distinct_sessions`
  in `proposals-history.jsonl`? (They should — the producer fix is live.)
- Confirm no detector wrongly counts `"unknown"` (the P1a/b fix).
- Confirm the grandfather Option B didn't retroactively block any
  legitimate pre-v3.29 instinct (entry-absent should still grandfather).

### P2 — Backfill apply hardening (#49 + #45)

- Implement the shared lock (§2 decision A or B).
- Re-enable `_cmd_backfill --apply` (remove the v3.33.0 gate at
  distill_engine.py:~2649).
- #45: wrap `manual_promote_detector` + `manual_swap_promote` in the same
  lock.
- #49 P2 sub-items: tmp-file cleanup on replace failure (reuse
  `_atomic_write`'s try/finally pattern, distill_engine.py:~289-306);
  add the `(size, mtime_ns)` guard to the tracking write too (currently
  only history has it).
- New test: concurrent Stop-hook append DURING `--apply` → no data loss
  (genuine serialization, not just abort).
- Only after this lands: re-run `/cx-backfill --apply` on real data and
  confirm it normalizes the 881 legacy `session`→`session_id` entries
  safely.

### P3 — Small hardening (cheap, batch together)

- #47: `os.chmod(path, 0o600)` after creating
  `auto-validate-skips.jsonl` + `security-events.jsonl` (and audit all
  `_atomic_write` callers handling PII/session_id). +1-2 tests.
- #48: add a "Trust boundary" section to `commands/cx-promote.md` and
  `commands/cx-distill.md` (single-user threat model; any local process
  as the operator's UID can call the writer). Doc-only.
- #46: regression test that a `version: 2` `.promoted-detectors.json`
  is rejected by the v1 reader AND preserved (not overwritten) — extends
  the v3.32.0 quick-win archive-on-corrupt behavior.

---

## 4. Suggested sequencing (2 PRs)

**PR1 — v3.34.0 "unblock" (P0 + P3, low risk):**
- P0.a laws cap triage (mostly operator decisions + `/cx-distill --swap`
  runs; little code).
- P0.b pending triage + emitter dedup (code: session-learner.js detectors).
- P3 batch (#47 chmod, #48 doc, #46 test) — cheap, no architectural risk.
- This PR delivers the operator's actual value and closes #46/#47/#48.

**PR2 — v3.34.1 or v3.35.0 "backfill apply" (P2, higher risk):**
- The shared-lock architecture (§2). AD with Codex GPT-5.5 BEFORE coding.
- Re-enable `--apply`, wrap promote/swap (#45), tmp cleanup + tracking
  guard (#49 P2).
- Closes #45 + #49.
- Higher risk because it touches the hot Stop-hook write path — isolate it.

---

## 5. Process notes (what worked, carry forward)

- **The bug was found by the operator running `/cx-status` + `/cx-analyze`
  on live data, not by tests.** Synthetic tests passed while production was
  broken (the fixtures hand-wrote `session_id`). The instinct
  `gotcha-ad-por-fase-no-sustituye-e2e` was validated AGAIN — the e2e test
  now drives the real session-learner.js writer. Keep that discipline:
  any v3.34 test touching session/promotion data must exercise the REAL
  writer, never a hand fixture.
- **3 AD rounds (Codex GPT-5.5) on the same apply path** each found a
  distinct issue (P0 line-loss → fixed; P0 TOCTOU residual → gated). The
  shared-lock work in PR2 MUST get its own AD round before merge.
- **Honesty over optics:** v3.33.0 gated `--apply` rather than ship a
  one-sided lock that looks safe but isn't. Hold that line in v3.34.
- **Routing:** code via `fs-codex:code` (gpt-5.3-codex), review/AD via
  `fs-codex:rescue` (gpt-5.5), final holistic review by Opus. This
  GPT→Claude→GPT diversity caught bugs no single model's self-review would.

---

## 6. Quick reference — key files & line anchors (as of v3.33.0)

- `hooks/lib/distill_engine.py`
  - `backfill_session_data` ~2466 (apply path ~2580-2622; gate `_cmd_backfill` ~2649)
  - `_proposal_session` ~1338 (the session_id ?? session ?? sid + "unknown"→"" helper)
  - `can_promote_to_auto` ~1393
  - `auto_promote_to_law` grandfather ~966 (Option B: entry-absent only)
  - `manual_promote_detector` ~2244, `manual_swap_promote` ~2258 (need LOCK_FILE, #45)
  - `LOCK_FILE` constant — exists, underused
- `hooks/session-learner.js`
  - 5 producer sites: 296/390/464/541/622 (now emit `session_id`)
  - `_mirrorToTrackingMem` ~886 (fills sessions[], rejects ''/"unknown")
  - `_flushTracking` ~908 (single-call invariant — do NOT move into loop)
  - history append via `proposals-storage.js` (no lock — the #49 root cause)
- `commands/cx-backfill.md` — `--apply` documented as gated to v3.34
- Tests: `tests/test_backfill.sh` (11), `test_promotion_gate.sh`,
  `test_distill_engine.sh` (grandfather inverted), `test_hooks_e2e.sh`
  (real-writer session_id assert)

---

**v3.34 plan DRAFT — review + refine in a fresh session, then execute
PR1 (unblock) first.**
