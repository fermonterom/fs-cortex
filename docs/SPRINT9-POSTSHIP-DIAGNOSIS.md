# Sprint 9 post-ship diagnosis — session_id propagation failure

**Status:** DIAGNOSIS for AD review (Codex GPT-5.5). NO code changed yet.
**Date:** 2026-05-29.
**Trigger:** operator ran `/cx-status` + `/cx-analyze` live against the
installed v3.32.0 (2 days after ship). Real production data exposed a
critical bug that synthetic tests missed.
**Reviewer task:** validate the root-cause analysis and the proposed
fix BEFORE any code is written. This is a critical-path change (touches
the Stop hook, the heart of the learning pipeline) crossing three
shipped releases (v3.31.2 + v3.32.0).

---

## 0. TL;DR for the reviewer

One omitted field — the resolved `sessionId` is never propagated from
`session-learner.js` into (a) the proposals it writes, nor (b) the
instinct-tracking entries it updates — silently breaks TWO features
from TWO different releases:

1. **v3.32.0 §4.4 HUMAN→AUTO promotion gate is structurally
   unreachable.** Proposals carry no `session_id`, so
   `can_promote_to_auto` computes `distinct_sessions=0` for every real
   detector source → gate blocked forever.

2. **v3.31.2 §4.1.A grandfather narrow is far broader than the AD
   believed.** `sessions:[]` was assumed to be a rare corruption/legacy
   case; production data shows it is the state of **71% of the corpus**
   because `_mirrorToTrackingMem` never fills sessions. So the "case 2"
   grandfather we added auto-promotes the majority of conf≥0.95
   instincts to LAW without 3 real distinct sessions.

The reviewer must judge whether the proposed fix is correct AND whether
the regime change it causes (71% of instincts stop auto-grandfathering)
is the desired behavior or needs a migration path.

---

## 1. Environment & method

- Installed engine: v3.32.0 (`~/.claude/cortex/version` = 3.32.0),
  verified identical to repo `hooks/lib/distill_engine.py`.
- Repo: `/Users/fmm/github/fs-cortex`, branch `main` (PR #44 merged).
- Read-only inspection of live state files under `~/.claude/cortex/`.
  No code, no engine runs that mutate state beyond the operator's own
  `/cx-analyze`.

---

## 2. Evidence (all from live production data 2026-05-29)

### 2.1 proposals-history.jsonl — session_id coverage

```
total=1710  with_session_id=480 (28%)
by status: {accepted: 140, rejected: 1570}    # accept_rate = 8.2%
top sources:
   480  sid=  480  <none>                       # legacy, pre-source
   277  sid=    0  session-learner:workflow
   274  sid=    0  session-learner:file-coupling
   257  sid=    0  session-learner:correction
   198  sid=    0  session-learner
   101  sid=    0  session-learner:error-fix
    76  sid=    0  cx-analyze
    34  sid=    0  session-learner:repetition
```

**Reading:** every entry that carries a real `source:
session-learner:*` has `session_id` ABSENT (sid count = 0). Only the
480 legacy `source:<none>` entries have a session_id, and those predate
the source field entirely. So the gate's `distinct_sessions` signal is
structurally 0 for every detector it is supposed to evaluate.

### 2.2 instinct-tracking.json — sessions population

```
total entries: 295
entries with sessions==[]: 211 (71%)   with sessions>0: 84 (29%)
count distribution (count_value -> #entries sharing it):
  count=925:  39 entries  (agent-pattern-*)
  count=2013: 34 entries  (gotcha-* generic-trigger)
  count=107:  17 entries  (coupling-*, repeat-*)
  count=2014: 15 entries
  count=2012: 13 entries
  count=966:   9 entries  (correction-*)
```

**Reading 1 — sessions:[] is the norm, not the exception.** 71% of
tracking entries have empty sessions. These are instincts the Stop hook
touches (count goes up) but the injector PreToolUse never injected live
(domain-filter caps injection at 3 per tool, MAX_TOTAL_CHARS=1500), so
the injector's `sessions.push` path never runs for them.

**Reading 2 — count is saturated by broad triggers (B2 quantified).**
34 instincts share EXACTLY count=2013, 15 share 2014, 13 share 2012.
That is not organic: these match generic triggers (`Bash`, `Read`) and
the injector increments them in lockstep (`tracking[key].count++` at
injector-engine.js:355) on every matching tool call. count measures
"how many Bash calls happened while this instinct existed", not
instinct maturity.

### 2.3 auto-validate-skips.jsonl — §4.1.B harvest (answers plan Q4 early)

```
runs=2  sum_total=604  sum_accepted=8
skip reasons:
   503  needs-human-judgment
    93  already-instinct
```

**Reading:** the "42-44 AUTO pending stuck" from the SessionStart
banner are NOT auto-domain proposals blocked by a silent gate. They are
503 HUMAN-domain proposals (correction/coupling/agent-quality) waiting
for `/cx-validate` (by design) + 93 re-emissions of already-captured
patterns (`already-instinct` → dedup candidate at the emitter). This
answers plan v3.33 question Q4 before the observation window even
started.

### 2.4 proposals.json — noise composition

```
total=308  (307 pending + 1 accepted)
by domain: correction 134, coupling 123, error-recovery 49, agent-evolution 2
by id-pattern: coupling-* 123, gotcha-Tool-hash 37, gotcha-named 12, other 136
```

**Reading:** ~160/308 are auto-generated noise (coupling-* +
gotcha-Tool-hash). `/cx-validate` would be a slog. Candidate for a
`/cx-audit` cleanup pass before validation.

---

## 3. Root-cause analysis (file:line)

### 3.1 The session resolution that IS done

`hooks/session-learner.js`:
- line 182: `let sessionId = process.env.CORTEX_SESSION_ID || ''`
- lines 184-185: fallback to `stdinData.session_id`
- lines 196-220: `buildCandidateSids` + observation grouping → resolves
  `sessionId` to the latest real session
- line 228: tags observations with `o._resolvedSession = sessionId`

So `sessionId` IS correctly resolved and available in scope.

### 3.2 Where it is NOT propagated — proposals (bug #1)

Every proposal-construction site pushes `source` + `status:'pending'`
but no `session_id`:

- line 277-294: error-fix proposal
- line 377-388: correction proposal
- line 461-462: agent-pattern proposal
- line 530-539: agent-error-rate proposal
- line 608-619: file-coupling proposal
- line 750: command proposal

None of these include `session_id: sessionId`. Downstream,
`proposals-storage.js::splitForPersist` appends the proposal verbatim
to `proposals-history.jsonl`, so the missing field is permanent.

`distill_engine.py::can_promote_to_auto` (v3.32.0 §4.4) then does:

```python
distinct_sessions = len({
    p.get("session_id", "") for p in reviewed if p.get("session_id")
})
```

→ always 0 for `session-learner:*` sources → gate returns
`distinct_sessions 0 < 3` forever.

### 3.3 Where it is NOT propagated — tracking (bug #4)

`hooks/session-learner.js::_mirrorToTrackingMem` (line 882-895):

```js
function _mirrorToTrackingMem(tracking, instinctId, isoDate, count) {
  if (!instinctId || !tracking) return;
  const entry = tracking[instinctId] || {
    count: 0, sessions: [], projects_seen: [], first_seen: isoDate,
  };
  if (count > (entry.count || 0)) entry.count = count;
  entry.last_seen = new Date().toISOString();
  if (!entry.first_seen) entry.first_seen = entry.last_seen;
  tracking[instinctId] = entry;        // sessions NEVER touched
}
```

Compare the injector, which DOES it correctly
(`hooks/lib/injector-engine.js:354-359`):

```js
if (!tracking[key]) tracking[key] = { count: 0, sessions: [], ... };
tracking[key].count++;
if (!tracking[key].sessions.includes(hookData.session_id || "")) {
  tracking[key].sessions.push(hookData.session_id || "");
  if (tracking[key].sessions.length > 20) tracking[key].sessions = tracking[key].sessions.slice(-20);
}
```

So when the Stop hook is the only writer for an instinct (71% of the
corpus — instincts that match but never get injected), `sessions` stays
`[]` forever.

### 3.4 The cascade into v3.31.2 §4.1.A

`distill_engine.py::auto_promote_to_law` grandfather (shipped PR1):

```python
no_meaningful_tracking = (
    not has_tracking_entry
    or (isinstance(entry, dict) and entry.get("sessions") == [])
)
if no_meaningful_tracking and conf >= LAW_THRESHOLD_CONF:
    distinct_sessions = LAW_MIN_DISTINCT_SESSIONS  # grandfathered
```

The AD P1-1 review approved the `sessions == []` case on the assumption
it was a rare corruption/legacy shape. Production data (§2.2) shows it
is 71% of the corpus. So this clause auto-grandfathers the MAJORITY of
conf≥0.95 instincts straight to LAW, bypassing the 3-distinct-sessions
gate that was the entire point of v3.29.0 §4.16.

---

## 4. Proposed fix (NOT yet applied — for AD judgment)

### 4.1 Bug #1 — stamp session_id on proposals

In `session-learner.js`, add `session_id: sessionId` to all 6
proposal-construction objects (lines 277, 377, 461, 530, 608, 750).
`sessionId` is already in scope (resolved at line 219).

New test: an e2e test that drives the REAL writer (not a hand-authored
fixture) and asserts the persisted proposal carries `session_id`. The
existing `test_promotion_gate.sh` fixtures inject `session_id` by hand,
which is exactly why they passed while production was broken
(instinct `gotcha-ad-por-fase-no-sustituye-e2e`).

### 4.2 Bug #4 — stamp sessions in _mirrorToTrackingMem

Pass the resolved `sessionId` into `_mirrorToTrackingMem` and replicate
the injector's dedup+cap-20 push. Signature becomes
`_mirrorToTrackingMem(tracking, instinctId, isoDate, count, sessionId)`.

### 4.3 The regime-change question (the hard one)

After 4.2, NEW Stop-hook updates fill sessions correctly. But the 211
existing `sessions:[]` entries stay empty. Two options:

- **Option A (passive):** leave existing entries as-is. They keep
  grandfathering until they next get injected live and accumulate real
  sessions. Simpler, but the 71% keep auto-promoting in the meantime.
- **Option B (migration):** one-shot backfill that drops the
  grandfather for `sessions:[]` entries going forward (tighten §4.1.A
  to only grandfather `not has_tracking_entry`, NOT `sessions == []`),
  accepting that some legitimately-old instincts now need to re-earn 3
  sessions. Cleaner long-term, but a harder behavior cut.

### 4.4 Should §4.1.A case-2 be reverted entirely?

Given the data, the `sessions == []` grandfather branch may have been
the wrong call. If `_mirrorToTrackingMem` is fixed to fill sessions,
then a genuinely new instinct will accumulate sessions naturally, and
`sessions:[]` should arguably block (not grandfather) — it now means
"touched by Stop but never injected live", which is precisely the
single-session-burst case the gate was designed to stop.

---

## 5. Questions for the AD (Codex GPT-5.5)

1. **Root cause completeness.** Is "sessionId resolved but not
   propagated" the complete root cause, or is there a third
   producer/path (cross-day-tracker.js? observe.py? impact_log.js?)
   that also writes proposals or tracking and would keep the bug alive
   after fixing the two sites above?

2. **No new breakage.** Does adding `session_id` to proposals interact
   badly with: the dedup logic in the Stop hook, `splitForPersist`,
   `migrateAcceptedRejectedToHistory`, the ghost-guard
   (`_detect_unauthorized_rejections`), or the cross-day boost? Does
   adding sessions to `_mirrorToTrackingMem` risk the same
   concurrent-write loss the v3.29.3 single-flush refactor fixed?

3. **Regime change.** Is the §4.1.A grandfather correct to keep
   (Option A), tighten (Option B), or revert case-2 entirely (§4.4)?
   What is the safest path that does NOT retroactively block legitimate
   pre-v3.29 instincts while also not auto-promoting 71% of the corpus?

4. **Hotfix vs sprint.** Is this a v3.32.1 patch (fix the two sites +
   tests + decide §4.1.A) or does the regime change make it a v3.33.0
   minor? Should the 7-day observation window restart after the fix
   (since the gate was measuring a miscalibrated instrument)?

5. **Data backfill.** The 1570 historical rejects + 211 sessions:[]
   entries cannot be retroactively given session_ids. Is there any
   value in a partial backfill (e.g. inferring session from the
   proposal's detection timestamp vs observations.jsonl), or accept the
   clean-slate-going-forward and document it?

---

## 6. What is NOT in question

- §4.5 laws cap raise + deprecation policy: healthy, unrelated to this
  bug. No action.
- The promotion gate's 4-criteria logic itself: correct. The bug is the
  data feeding it, not the gate.
- The fail-closed marker reader: correct.

---

## 7. Implementation spec — v3.33.0 (operator decisions LOCKED 2026-05-30)

Post-AD (Codex GPT-5.5 verdict REVISE) + live-data re-verification by
Claude Opus. The AD's "clean-slate, no backfill" recommendation was
OVERRULED by data: **79% of history (1361/1711 entries) carries a real
session under the field name `session` (881) or `session_id` (480).**
The gate only reads `session_id`, so 881 entries are silently ignored.
This is recoverable, not lost.

### 7.0 Operator decisions (do not re-litigate)

1. **Naming = BOTH SIDES.** Producer writes canonical `session_id`;
   consumer reads `session_id ?? session ?? sid` (fallback recovers the
   881 historical `session` entries). Fallback may be retired in v3.34
   once old data decays.
2. **Scope INCLUDES `/cx-analyze`** producer (AD P0-2). Both Stop-hook
   detectors AND `/cx-analyze` must stamp `session_id`.
3. **NEW `/cx-backfill` command** to recover historical data.
4. **Backfill rigor = HÍBRIDO POR CONFIANZA.** Generous recovery ONLY
   for instincts with conf≥0.95 AND ≥3 distinct recovered sessions AND
   0 critical rejections in history; everything else normalizes the
   field name but must earn new sessions.
5. **Grandfather = OPTION B (tighten).** §4.1.A grandfathers ONLY when
   the tracking entry is ABSENT, NOT when `sessions == []`. Existing
   `sessions:[]` entries are bug-contaminated (the norm at 71%, not the
   rare corruption the prior AD assumed), so they must not auto-promote.

### 7.1 Verified site map (session-learner.js)

| Line | source | current session field | action |
|------|--------|----------------------|--------|
| 277 | error-fix | `session:` (val `obs._resolvedSession \|\| obs.sid \|\| 'unknown'`) | RENAME → `session_id:` |
| 387 | correction | `session:` (val `edits[0]._resolvedSession \|\| edits[0].sid`) | RENAME → `session_id:` |
| 461 | agent-pattern | `session:` (val `items[0].obs._resolvedSession`) | RENAME → `session_id:` |
| 527-538 | agent-error-rate | NONE | ADD `session_id:` — derive from the obs the detector aggregates (resolve which obs var is in scope) |
| 603-613 | file-coupling | NONE | ADD `session_id:` — derive from the coupling obs pool |
| ~750 | (timeline.jsonl logging) | n/a | DO NOT TOUCH — not a proposal (AD P1-1) |

VERIFIED: no consumer reads the bare `.session` field of a proposal
(grep clean). Renaming `session`→`session_id` is safe; nothing breaks.

### 7.2 Components (8)

- **C1 producer** — apply the 7.1 site map. For agent-error-rate +
  file-coupling, the detector aggregates across sessions; stamp the
  CURRENT resolved sessionId (the session where the pattern was
  detected) — semantically "this review happened in session X". Pass
  the resolved sessionId into those detectors as an argument if it is
  not already reachable from their obs pool.
- **C2 consumer** — `distill_engine.py`: add helper
  `_proposal_session(p)` returning `p.get('session_id') or
  p.get('session') or (p.get('_incident') or {}).get('sid') or ''`.
  Use it in `can_promote_to_auto`'s distinct_sessions set comprehension.
- **C3 tracking** — `_mirrorToTrackingMem(tracking, id, isoDate, count,
  sessionId)`: replicate injector dedup+cap-20 push of sessionId into
  `entry.sessions`. Caller passes the resolved sessionId. Keep the
  single `_flushTracking` after the loop (v3.29.3 invariant — do NOT
  reintroduce per-call writes).
- **C4 grandfather Option B** — `auto_promote_to_law`: remove the
  `or (isinstance(entry,dict) and entry.get('sessions')==[])` branch.
  Grandfather ONLY `not has_tracking_entry`. Update the 5 PR1 tests
  (36-40): test 37 "sessions:[] promotes" INVERTS to "sessions:[]
  blocks"; keep 36 (entry absent → promotes) and the 2 corruption
  guards.
- **C5 `/cx-backfill`** — new `backfill_session_data(dry_run=True)` in
  distill_engine.py + `commands/cx-backfill.md`:
  1. BACKUP `proposals-history.jsonl` + `instinct-tracking.json` to
     `archive/backfill-<ts>/` BEFORE any write.
  2. Normalize: for each history entry with `session` but no
     `session_id`, add `session_id` = that value (keep `session` for
     safety). Idempotent (skip if `session_id` already present).
  3. Rebuild tracking `sessions[]`: for each instinct, collect distinct
     recovered session_ids from history entries whose accepted instinct
     id matches, cap 20, only fill if currently `[]`.
  4. HÍBRIDO: an instinct is "recovery-eligible" iff conf≥0.95 AND ≥3
     distinct recovered sessions AND `_count_critical_rejections`==0 for
     its source. Mark eligible ones so the next `/cx-distill` sees real
     sessions; non-eligible only get the field normalized.
  5. Report: N normalized, M tracking rebuilt, K newly-eligible, and a
     per-source before/after `distinct_sessions` table.
  6. `--dry-run` default TRUE; requires explicit `--apply` to write.
- **C6 cx-analyze producer** — stamp `session_id` on the 3 proposals
  it appends (the diagnosis's §2.1 showed `source:cx-analyze` sid=0).
- **C7 tests** — (a) e2e driving the REAL session-learner writer in a
  sandbox, asserting persisted proposals carry `session_id` (NOT a hand
  fixture — that is the gotcha that hid this bug); (b) gate fallback
  test (entry with only `session` → counts); (c) backfill test:
  normalize + rebuild + hybrid eligibility + idempotency + dry-run
  no-write + backup created.
- **C8** — AD Codex GPT-5.5 on the full diff, then release v3.33.0
  (bump 4 files + CHANGELOG + FEATURES + README commands table for
  `/cx-backfill` + CLAUDE.md). Restart the 7-day observation window
  AFTER the backfill apply (data is now correctly shaped).

### 7.3 Safety invariants (must hold)

- Backfill NEVER deletes; backup-then-modify, idempotent, dry-run
  default.
- `_flushTracking` stays single-call (no concurrent-write regression).
- conf≥0.95 + the OTHER gate criteria still apply to recovery-eligible
  instincts — hybrid only unblocks `distinct_sessions`, not the rest.
- All existing tests stay green; grandfather test inversion is the only
  intended behavior-change to a prior test.

---

## 8. AD-final REJECT remediation spec (v3.33.0 — 3 fixes, LOCKED)

The final Adversarial Defense (Codex GPT-5.5) on the v3.33.0 working
tree returned **REJECT** with 1 P0 + 2 P1, all confirmed by Claude Opus
against the working-tree source. C1-C4, C6, C7 are SOUND and must NOT
be touched. Fix ONLY the three items below. After the fixes, all
existing tests must stay green and 3 new regression tests must be added.

### 8.1 FIX-P0 — backfill apply must be lossless + concurrency-safe

**Files:** `hooks/lib/distill_engine.py` — `_load_proposals_history`
(~1311), `backfill_session_data` (~2466, write path ~2559-2578).

**Problem:** `backfill_session_data(dry_run=False)` rewrites
`proposals-history.jsonl` entirely via `write_text` using ONLY the dict
lines that `_load_proposals_history()` successfully parsed. That
function silently drops unparseable / non-dict lines, so the apply
DELETES them — violating the §7 "backfill NEVER deletes" invariant.
Also the normal Stop-hook writer appends to the same file via
`appendFileSync`, so any append landing between backfill's
read→backup→write is lost (the backup was taken before it).

**Required fix (all of):**
1. **Line-preserving rewrite.** Do NOT rebuild the file from the parsed
   dict view. Read the raw lines; for each non-blank line: parse it, and
   if it is a dict needing the `session_id` backfill, re-serialize ONLY
   that line; otherwise write the ORIGINAL raw line back verbatim
   (unparseable / non-dict lines preserved). Net: output non-blank line
   count == input non-blank line count.
2. **Atomic replace.** Write to `proposals-history.jsonl.tmp.<pid>` then
   `os.replace()` (never a partial `write_text`).
3. **Concurrency guard.** Record the history file `(size, mtime_ns)`
   before reading; re-check immediately before the atomic replace. If
   changed, ABORT with `backfill: history changed during run, aborted —
   no data written; re-run` having written nothing.
4. Same atomic-replace treatment for `instinct-tracking.json` when
   `rebuilt != 0`.
5. Backup (shutil.copy2 to `archive/backfill-<ts>/`) still runs BEFORE
   any write, unchanged.

### 8.2 FIX-P1a — `"unknown"` must not count as a real session

**Files:** `hooks/lib/distill_engine.py` `_proposal_session` (~1338);
`hooks/session-learner.js` producer sites 296/390/464/541/622.

**Required fix:**
1. In `_proposal_session(p)`: treat literal `"unknown"` (case-
   insensitive, trimmed) as empty → return `""`. Excludes it from
   `distinct_sessions` in `can_promote_to_auto` AND from backfill.
2. In the 5 producer sites: drop the `|| 'unknown'` tail (emit the
   resolved sid or empty). Minimal change guaranteeing `"unknown"`
   never reaches a counting path.

### 8.3 FIX-P1b — tracking mirror must not persist `"unknown"`

**Files:** `hooks/session-learner.js` `_mirrorToTrackingMem` (~886),
caller `matchedSessionId` (~848).

**Required fix:** normalize once and reject both `""` and `"unknown"`
before pushing into `sessions[]`. Preserve the single `_flushTracking`
after the loop (v3.29.3 invariant).

### 8.4 Tests required (new regression guards)

1. `tests/test_backfill.sh`: corrupt/non-dict line + valid normalizable
   line → after `--apply`, corrupt line STILL present (lossless) and
   valid line got `session_id`. Assert output line count >= input.
2. `tests/test_backfill.sh`: concurrency guard — size/mtime change
   between read and write → apply ABORTS, original file intact.
3. `tests/test_promotion_gate.sh`: a source whose only "third session"
   is `"unknown"` → `can_promote_to_auto` does NOT count it, gate stays
   blocked.

### 8.5 Out of scope (do NOT touch)

- C1-C4, C6, C7 logic (sound per AD).
- Naming/scope/Option-B/hybrid — LOCKED in §7.
- Version bump / CHANGELOG / tag — Claude handles release after re-review.
