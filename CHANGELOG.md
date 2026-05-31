# Changelog

All notable changes to fs-cortex will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [3.34.0] — 2026-05-31

### Added
- **Core/Domain law split — `demote_law_to_domain()` + `/cx-distill --demote`
  (Phase 2 of `docs/DESIGN-LAW-INJECTION-V2.md`).** A Domain law can now be
  demoted back to the relevance-gated instinct pool: it stops being injected at
  every SessionStart (~40 tok saved each) and re-joins the PreToolUse injector,
  surfacing only when its `trigger` matches. Reversible (law `.txt` archived to
  `laws/archive/<id>.<ts>.txt`) and **fail-safe** — it refuses to demote a law
  with no instinct-yaml backing or no `trigger`, rather than inventing one and
  silently dropping the law from all injection.
- **`law_eligible: false` instinct frontmatter flag + guard in
  `auto_promote_to_law`.** A demoted instinct is never re-promoted to a law, so
  the next distill cycle cannot unravel the split.
- **`tests/test_law_tier.sh`** (14 cases) — unit coverage for demote
  (success / no-yaml refusal / archive-restore / dry-run / missing-law) and the
  promote guard, plus an **e2e gate** that demotes a law and asserts the real
  `injector-engine.js` re-injects it via its trigger (satisfies instinct
  `gotcha-ad-por-fase-no-sustituye-e2e`). Wired into `.githooks/pre-push`.

### Changed
- `commands/cx-distill.md` documents the new `--demote` sub-mode.

## [3.33.1] — 2026-05-31

### Fixed
- **`max_laws` config desync (10 → 15).** `core/memory.template.json` and the
  `docs/FEATURES.md` config table still declared `max_laws: 10` while the engine
  has enforced `LAW_MAX_ACTIVE = 15` since v3.32.0 §4.5. New installs therefore
  seeded a stale `max_laws: 10` into their `memory.json` config. Both synced to
  15. Runtime was unaffected (the engine constant always governed) — but the
  operator-facing config and the docs were lying.

### Added
- **`docs/DESIGN-LAW-INJECTION-V2.md`** — design doc for the Core/Domain law
  split (Phase 2/3 of the law-cap redesign). Grounded in live-Cortex curation
  data (1714 proposals-history rows, 300 tracked instincts, 170 yaml-orphans)
  and an honest comparison against Sinapsis v4.5 (`skill-router`,
  `_instinct-activator.sh`, per-injection token cap). Informs
  `docs/SPRINT-V3.34-PLAN.md`. No code behavior change.

## [3.33.0] — 2026-05-30

Post-ship fix for a critical bug found by running `/cx-status` +
`/cx-analyze` against live production data two days after v3.32.0:
the resolved `sessionId` was never propagated from `session-learner.js`
into proposals (field was named `session`, not `session_id`) nor into
instinct-tracking entries. This made the v3.32.0 HUMAN→AUTO promotion
gate structurally unreachable (`distinct_sessions=0` for every detector)
and made the v3.31.2 grandfather clause auto-promote 71% of the corpus
(every `sessions:[]` entry) to LAW. Diagnosis + remediation spec:
`docs/SPRINT9-POSTSHIP-DIAGNOSIS.md`. Three AD rounds (Codex GPT-5.5)
+ Claude Opus review hardened the fix.

### Fixed

- **`hooks/session-learner.js`** — the 5 proposal producer sites now
  emit `session_id` (was `session`, or absent for agent-error-rate /
  file-coupling), so `can_promote_to_auto` can count distinct sessions.
  The `|| 'unknown'` fallback was dropped (`|| ''`) so the literal
  `"unknown"` never reaches a counting path.
- **`hooks/session-learner.js:_mirrorToTrackingMem`** — now fills the
  tracking `sessions[]` (dedup + cap 20) from the resolved sessionId,
  rejecting `""` and `"unknown"`. The single `_flushTracking` after the
  loop (v3.29.3 invariant) is preserved.
- **`hooks/lib/distill_engine.py:can_promote_to_auto`** — counts
  distinct sessions via new `_proposal_session(p)` helper with legacy
  fallback `session_id ?? session ?? _incident.sid`, returning `""`
  for the literal `"unknown"`.
- **`hooks/lib/distill_engine.py:auto_promote_to_law`** — grandfather
  clause narrowed to **entry-absent only** (Option B). `sessions:[]`
  entries no longer auto-grandfather to LAW, because production data
  showed `sessions:[]` is the norm (71%), not the rare corruption case
  the v3.31.2 narrow assumed.
- **`commands/cx-analyze.md`** — the cx-analyze proposal producer now
  stamps `session_id` too.

### Added

- **`/cx-backfill`** command (`commands/cx-backfill.md`,
  `hooks/lib/distill_engine.py:backfill_session_data`) — recovers
  legacy `session` → `session_id` in `proposals-history.jsonl` and
  selectively rebuilds empty tracking `sessions[]` for high-confidence
  instincts (conf≥0.95 + ≥3 distinct recovered sessions + 0 critical
  rejections). The write path is lossless (line-preserving, preserves
  unparseable/non-dict lines verbatim), atomic (tmp+os.replace), and
  has a (size, mtime_ns) concurrency guard.
  **`--apply` is GATED OFF in v3.33.0** (runs a safe dry-run + prints a
  deferral notice): the normal Stop hook appends to history without a
  shared lock, leaving a residual write race. Enabling `--apply` is
  deferred to v3.34 (issue #49). The dry-run report is fully safe.

### Tests

- `tests/test_backfill.sh` NEW — 11 cases (dry-run safety, apply
  lossless/atomic, concurrency-guard abort, hybrid eligibility,
  idempotency, CLI `--apply` gate).
- `tests/test_promotion_gate.sh` — +2 cases (legacy `session` field
  fallback, `"unknown"` excluded from distinct_sessions).
- `tests/test_distill_engine.sh` — grandfather test inverted
  (`sessions:[]` now BLOCKS, not promotes) per Option B.
- `tests/test_hooks_e2e.sh` — asserts the REAL session-learner.js
  writer persists `session_id` on proposals (regression guard for the
  exact bug; not a hand fixture).
- `tests/test_install.sh` + `tests/test_integrity.sh` — command count
  bumped for `/cx-backfill` (21 files; 20 in EXPECTED_COMMANDS subset).
- Full suite: **487 PASS, 29 suites**.

### Notes

- This bug existed since v3.32.0 (gate) and v3.31.2 (grandfather). The
  fix is forward-only; historical proposals without `session_id` are
  not retroactively repaired (the gated `/cx-backfill` will do that in
  v3.34). On the operator's real corpus the backfill dry-run reports
  `newly_eligible=0` — the fix unblocks the gate going forward, it does
  not manufacture past promotions.

## [3.32.0] — 2026-05-27

Sprint 9 PR2 — autopilot foundation: HUMAN→AUTO promotion gate
(statistical-strict, operator-confirmed) + laws cap raise (12→15)
with deprecation policy. Sprint 8 invariants preserved end-to-end via
the renamed acceptance gate. Plan: `docs/SPRINT-9-AUTOPILOT.md` v3
FINAL (AD Codex GPT-5.5 round 1 absorbed: 4 P0 + 7 P1 + 3 P2).

### Added

- **`hooks/lib/distill_engine.py:can_promote_to_auto`** (§4.4.b). New
  4-gate statistical check for HUMAN→AUTO promotion: n ≥ 20 reviewed
  AND accept_rate ≥ 70 % AND distinct_sessions ≥ 3 AND
  critical_count == 0. Visibility tier at n=10 surfaces partial
  progress (`visible-only (N/20)`) without enabling promotion
  (AD P1-2). Source: `~/.claude/cortex/proposals-history.jsonl`
  (AD P0-1).
- **`hooks/lib/distill_engine.py:manual_promote_detector`** (§4.4.d
  writer). ÚNICO entrypoint that writes `.promoted-detectors.json`
  with the v1 schema `{version, promoted: [{source, since,
  approved_by, gate_snapshot}]}`. Requires `confirm=True`. Idempotent
  re-promotion is a no-op. Atomic via `_atomic_write`. AD P0-4 absorbed.
- **`hooks/lib/distill_engine.py:_load_promoted_detectors`** —
  fail-closed reader: any parse / schema / source-regex violation
  → empty set, every HUMAN domain stays HUMAN. All fail-closed paths
  are logged to `~/.claude/cortex/log/security-events.jsonl` so the
  operator can audit (rotated to `.1` at 512KB, mirror of
  session-learner.js rotation).
- **`_count_critical_rejections`** (§4.4.c) uses the new optional
  `rejection_category` enum (`security` / `breaking` / `injection` /
  `noise` / `other`) first; legacy rejects without the field fall back
  to a keyword heuristic over `rejected_reason` (ES: seguridad /
  inseguro / rompedor / inyecci / vulnerab; EN: security / breaking /
  injection / unsafe / vulnerab). AD P1-6 absorbed.
- **`hooks/lib/distill_engine.py:auto_validate_proposals`** — now
  loads `promoted_sources` once per pass; HUMAN-domain proposals with
  `source ∈ promoted_sources` fall through to the AUTO accept path
  via BOTH skip checks (first HUMAN-domain skip AND the second
  AUTO-domain skip, the latter fix surfaced by Assert 10 of the e2e
  gate — validates AD P1-5 / instinct gotcha-ad-por-fase-no-sustituye-e2e).
- **`hooks/lib/distill_engine.py:_find_least_impactful_law`** (§4.5).
  Heuristic: lowest `useful_14d / (1 + noise_14d)` ratio; tie-break
  by oldest mtime. Returns None when every law is younger than
  `LAW_DEPRECATE_MIN_AGE_DAYS=7` (AD P1-3) or when the best candidate
  has ratio > 1.0 (don't churn productive cohorts).
- **`hooks/lib/distill_engine.py:manual_swap_promote`** (§4.5,
  AD P1-7). Atomic swap with explicit rollback: pre-check both files,
  copy old law to `LAWS_DIR/archive/<id>.<ts>.txt`, unlink old, write
  new via `_atomic_write`. If the new-law write fails, restore old
  from the in-memory backup so the cohort stays at the same count.
- **`commands/cx-promote.md`** — new "Sub-mode --auto" section
  documents `--auto <source> --confirm` (gate snapshot UI, marker
  schema, audit log, removal note).
- **`commands/cx-distill.md`** — new "Sub-mode --swap" section
  documents `--swap <to_deprecate> <new_iid> --confirm` (dry-run,
  atomic flow, rollback, deprecation algorithm with the 4 guards).
- **`commands/cx-validate.md`** — Step 4b "Reject proposal" now lists
  the fields written to `proposals-history.jsonl` and adds the
  `rejection_category` ask with the 5-enum + legacy fallback.

### Changed

- **`LAW_MAX_ACTIVE` 12 → 15** in `hooks/lib/distill_engine.py`
  (§4.5 Eje A). Token cost: ~480 → ~600 tok/session baseline. Quality
  gate intact (`LAW_THRESHOLD_CONF`, `LAW_SUSTAINED_DAYS`,
  `LAW_MIN_DISTINCT_SESSIONS`, `LAW_MAX_NOISE_14D` unchanged).
- **Doc sync** for the cap raise: `README.md` (3 sites),
  `docs/FEATURES.md` (3 sites), `commands/cx-distill.md` (2 sites),
  `hooks/session-start.py:52` docstring. Stale line-number anchors
  (`distill_engine.py:83`) replaced with symbol anchors
  (`distill_engine.py:LAW_MAX_ACTIVE`) to prevent future doc drift.
- **`auto_promote_to_law` Criterion 7** (cap check) now reports a
  human-actionable `failed_reason`. When a candidate exists:
  `laws == 15/15 saturated; would deprecate <X> via /cx-distill
  --swap <X> <new> --confirm`. When none qualifies: `laws == 15/15
  saturated; no deprecation candidate (all productive OR < 7d age)`.
  Engine NEVER auto-swaps.
- **`tests/test_v329_acceptance.sh` renamed → `tests/test_v332_acceptance.sh`**
  via `git mv` (preserves blame). Header / banner / summary refreshed
  for v3.32.0. `.githooks/pre-push` updated (3 references).

### Fixed

- **`hooks/lib/distill_engine.py:manual_promote_detector`** — corrupted
  `.promoted-detectors.json` (parse fail, schema-version mismatch, or
  wrong type for `promoted`) is now renamed to
  `.promoted-detectors.json.corrupt-<UTC-ts>` via new
  `_archive_corrupted_marker()` helper, instead of silently overwritten
  with an empty `{"version": 1, "promoted": []}`. Fallback: if rename
  fails (file already gone after read), the in-memory original is
  written to the archive path. Every recovery path emits a distinct
  `promoted-detectors:archived-corrupt-marker` row in
  `~/.claude/cortex/log/security-events.jsonl` so the operator can
  recover prior operator-approved sources. Closes the PR #44 review
  finding "discards corrupted marker silently".
- **`README.md` Commands table** — `/cx-promote` and `/cx-distill` rows
  now mention the new `--auto <source> --confirm` and
  `--swap <old> <new> --confirm` sub-modes plus the cap raise to 15.
  Previously discoverable only via per-command markdown.

### Tests

- `tests/test_promotion_gate.sh` NEW — 11 cases. Tests 1-8: all four
  gate branches, n=10 visibility tier, enum + heuristic critical
  rejections, fail-closed marker (corrupted JSON + bad schema version).
  Tests 9-11 (PR #44 quick wins): confirm-false-blocks-write,
  idempotent-double-promote, corrupt-marker-archive (preserves prior
  content verbatim). 11 PASS / 0 FAIL.
- `tests/test_distill_engine.sh` +7 cases (43-49) for §4.5 + quick win:
  cap raise promotes the 13th law, `_find_least_impactful_law`
  lowest-ratio + tie-break by oldest mtime, age guard 7d (AD P1-3),
  `manual_swap_promote` golden path, write-failure rollback (AD P1-7),
  empty-impact-tie-break (PR #44 quick win: empty `impact_per_iid` →
  oldest law wins). Test 10 updated to seed 15 laws (was 12) so the
  cap check still triggers under the new cap. Suite: 48 PASS / 0 FAIL.
- `tests/test_v332_acceptance.sh` +2 e2e asserts (9 + 10) for §4.7:
  marker fail-closed + full promotion cycle (history → can_promote →
  manual_promote → marker → auto_validate ACCEPTS HUMAN proposal).
  Assert 10 surfaced + fixed the second-skip bug in
  `auto_validate_proposals` that all per-function unit tests had
  missed. 11 PASS / 0 FAIL.
- Baseline post-PR2 (incl. PR #44 quick wins): **476/476 PASS, 28/28
  suites** (was 456/456 in v3.31.2 + 20 new cases: 8 promotion-gate +
  3 promotion-gate quick wins + 6 distill §4.5 + 1 distill quick win
  + 2 e2e asserts).

### Notes

- This is PR2 of Sprint 9. Sprint 8 plan §5.1/§5.2 (`analyze_engine.py`
  + auto-analyze trigger) remain **deferred to v3.33+** per AD P0-2 /
  P0-3 (queue-only contradicted "autopilot real"; Opus 1M detection
  from a hook is not testable). Reentry post-7d-data of
  `auto-validate-skips.jsonl` with explicit `CORTEX_OPUS_1M=1` env var.
- (deferred) `docs/SPRINT-8-*.md`, `GHOST-*.md`, `SINAPSIS-*.md`
  scheduled for deletion at v3.33+ once Sprint 9 retrospective is
  complete (§4.6 — Q5 mantener until v3.33+).
- v3.30 was never published (jumped 3.29.5 → 3.31.0).

## [3.31.2] — 2026-05-26

Sprint 9 PR1 — three cleanup bug fixes. No detector signal changes:
the Sprint 8 observation window stays protected. Plan checked in at
`docs/SPRINT-9-AUTOPILOT.md` v3 FINAL (AD Codex GPT-5.5 round 1
absorbed: 4 P0 + 7 P1 + 3 P2 findings).

### Fixed

- **`hooks/lib/distill_engine.py:auto_promote_to_law`** — narrow the
  §4.16 grandfather clause to fire ONLY when (entry absent) OR
  (`sessions == []` explicit). Pre-v3.31.2 ANY non-dict tracking entry
  was treated as missing, which hid tracking corruption shapes
  (`sessions: null`, missing `sessions` key, wrong type) behind a
  successful promotion. After: corruption shapes keep blocking with
  `sessions 0/3 (need 3 more)` so the operator can detect them.
  AD P1-1 absorbed.

### Added

- **`hooks/lib/distill_engine.py:auto_validate_proposals`** — emits a
  new `skip_breakdown` Counter in the return dict and appends one
  JSONL row per non-dry-run to
  `~/.claude/cortex/log/auto-validate-skips.jsonl` (ts / total /
  accepted / skipped / skip_breakdown). Log rotates to `.1` at 512KB,
  mirror of `hooks/session-learner.js:60-76`. High-cardinality reasons
  (`orphan-domain:*`, `unsafe-trigger:*`, `validate_instinct:*`) are
  bucketed by prefix so the breakdown stays readable; low-cardinality
  reasons (`low-confidence`, `already-instinct`, `needs-human-judgment`)
  pass through unchanged. Logging is best-effort: any `OSError` is
  swallowed so logging cannot break auto-validate. Instrumentation
  only — no behavior change in any accept / skip / hold / reject path.
  AD P1-4 absorbed (no 24-48h window: investigation of the 42 stuck
  AUTO pending proposals is deferred to v3.33+ once 7d of these logs
  exist).
- **`hooks/lib/dream_cycle.py:archive_proposals_backups_if_due`** —
  new function wires `tests/archive_proposals_backups.sh` into the
  `/cx-dream` weekly cycle so `proposals.json.bak*` files stop
  accumulating. Reads/writes a `.last-proposals-archive` marker for
  the 7-day cooldown. Auto-detects repo_root from this file's path;
  falls back to `script-not-installed` (no crash) when running in an
  installed setup that does not ship the repo `tests/` directory.
  Invokes the shell script with `CORTEX_DIR` exported and a 30s
  timeout. Touches the marker only on `returncode 0` so a failed run
  is retried next cycle instead of waiting another 7 days.
- **`commands/cx-dream.md`** — new `Step 3d` documents the helper
  invocation and the three possible outcomes (archived / cooldown /
  not-installed).

### Tests

- `tests/test_distill_engine.sh` +7 cases (5 grandfather narrow +
  2 skip-breakdown logging). 41 PASS / 0 FAIL.
- `tests/test_dream_cycle.sh` +2 cases (first-run archives + cooldown
  skip). 40 PASS / 0 FAIL.
- Baseline: **447/447 PASS** pre-PR1; after PR1: **456/456 PASS** (+9).
- `test_integrity.sh` and `test_security.sh` green.

### Notes

- This is the PR1 of Sprint 9. PR2 will ship v3.32.0 with §4.4
  promotion gate `HUMAN→AUTO` + §4.5 laws cap raise + deprecation
  policy. Sprint 8 plan §5.1/§5.2 (analyze_engine + auto-analyze
  trigger) are **deferred to v3.33+** per AD P0-2/P0-3 (see
  `docs/SPRINT-9-AUTOPILOT.md` §4.2+4.3 DEFERRED block).
- v3.30 was never published (jumped 3.29.5 → 3.31.0); see commit
  history for details.

## [3.31.1] — 2026-05-20

### Fixed

- **`hooks/session-start.py:load_laws()`** — removed hard-coded `[:10]` slice
  on `sorted(LAWS_DIR.glob('*.txt'))`. The slice was stale since v3.29.2
  raised `LAW_MAX_ACTIVE` from 10 to 12 in `hooks/lib/distill_engine.py:83`.
  After v3.29.2, the loader kept truncating to 10 alphabetically, so the
  two laws sorting last in the directory (e.g. `pattern-test-after-change`,
  `project-bootstrap`) never reached the SessionStart context, even though
  `/cx-status` reported 12 active. Engine `_active_law_count()` and
  `auto_promote_to_law()` correctly used the new cap, masking the bug.
  Loader now reads all `*.txt` in `laws/`; cap is enforced upstream by the
  distill engine, so removing the loader slice is safe.

### Changed

- **`hooks/session-start.py:load_laws()` docstring** — updated to
  `"Read all active law files. Engine caps total at LAW_MAX_ACTIVE=12
  (see hooks/lib/distill_engine.py:83)."` Previous docstring still said
  `(max 10)`.
- **`commands/cx-distill.md`** — lines 16 and 99 updated from `max 10`
  to `max 12`, with cross-reference to `hooks/lib/distill_engine.py:83`
  (`LAW_MAX_ACTIVE` constant) and the v3.29.2 cap raise. Catches up the
  doc-sync miss in v3.29.3 (which updated `README.md` and `FEATURES.md`
  but missed the slash-command spec).
- **Internal `docs/CORTEX-AUDIT.md`** (gitignored) — local copy updated
  for the same `max 10 → max 12 since v3.29.2` sync. Not included in the
  PR diff (file is gitignored).

### Tests

- `tests/test_distill_engine.sh` — 0 failures.
- `tests/test_integrity.sh` — 0 failures.
- `tests/test_install.sh` — 42/42 PASS.

## [3.31.0] — 2026-05-17

### Changed

- **`hooks/session-learner.js:writeContextFile`** — replaced the v3.30 telemetry
  blob (`Tools used: Bash (7799), Read (4609)...` + full absolute file paths,
  reaching 2KB+ on long sessions) with a Sinapsis-style narrative format:
  `## Proyecto:` header in Spanish, total observation count, basenames-only
  (deduped, max 6), and an explicit `Posibles gotchas detectados: N — ejecuta
  /cx-analyze` CTA when errors were observed. Output now caps at ≤ 500 bytes
  by design. Cross-platform `pathBasename()` helper added — handles both
  POSIX (`/`) and Windows (`\`) separators without depending on `path.basename`
  semantics.
- **`hooks/session-start.py:inject_context_bridge`** — reads the full
  `context.md` (now ≤ 500 bytes) instead of the first 10 lines space-joined.
  Wraps the content in a `[project-context]` semantic tag so Claude can
  distinguish the bridge from other injected blocks. Newlines preserved.
- **`hooks/session-start.py:inject_eod_resume`** — wraps the resume in a
  `[eod-summary YYYY-MM-DD]` semantic tag with the EOD date.

### Added

- **`hooks/lib/dream_cycle.py:cleanup_corrupted_context_files`** — new helper
  that rotates legacy English-format `context.md` files (starting with
  `## Project:`) to `.legacy-YYYYMMDD` backups. Idempotent: subsequent runs
  match nothing because backups don't satisfy the `context.md` glob. Wired
  into `/cx-dream` Step 3c (Cleanup module).
- **`bin/cleanup-context-once.sh`** — standalone one-shot migration script.
  Same criterion as the dream helper (format, not size); safe to run before
  or after the new writer ships.
- **`tests/test_context_bridge.sh`** — 12 regression cases covering writer
  output size, Spanish headers, gotcha CTA conditional, basename cap/dedup,
  Windows path normalization, reader tag prefix, newline preservation,
  cleanup helper rotation/preservation, one-shot script idempotency, and
  EOD tag wrapping.
- **`.githooks/pre-push`** — runs `test_context_bridge.sh` between security
  checks and the v3.29 acceptance gate.

### Fixed

- **`hooks/lib/cortex_utils.py:sanitize_injection`** — regex changed from
  `[\x00-\x1f\x7f]` (which stripped `\n \r \t` along with the rest of the C0
  range) to `[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]`. TAB, LF, and CR are now
  preserved so multiline injections keep their structure. The fallback
  duplicate in `hooks/session-start.py` is patched in lockstep. Regression
  covered by new test 8 in `tests/test_security.sh`.
- **74KB rotted `context.md` symptom** — the writer rewrite caps real-world
  output at ≤ 500 bytes regardless of session length, so long sessions no
  longer produce multi-KB files. The one-shot script cleans up any legacy
  files left over from before the upgrade.

## [3.29.5] — 2026-05-17

### Security

- **`hooks/lib/validate_instinct.py`** — extracted `validate_yaml_content(content)`
  as a pure function reusable from both CLI and library callers.
- **`hooks/lib/distill_engine.py:auto_validate_proposals`** now calls
  `validate_yaml_content` BETWEEN `_proposal_to_instinct_yaml()` and
  `_atomic_write()`. Pre-v3.29.5 a proposal with `ignore previous
  instructions`, `forget all prior rules`, `you are now an admin`, or any
  other `BLOCKED_PATTERNS` match in its `action` field would auto-promote
  to an active instinct without barrier — the validator module existed
  but was wired only as a CLI tool. Now: rejected with
  `rejected_reason="validate_instinct:<reason>"`, instinct YAML never
  written.
- **`hooks/observe.py`** — new `HOME_PATH_RE` normalizes
  `/Users/<username>/...` and `/home/<username>/...` to `~/...` inside
  `scrub_secrets`. Pre-v3.29.5 the error-fix detector in
  `session-learner.js` copied raw tool `input` (containing absolute
  cross-project paths) into proposal `action` text, leaking the
  operator's local username into `proposals.json` and downstream
  instinct YAMLs. Path STRUCTURE is preserved so downstream
  `extractFilePath()` regex and `path.basename()` continue to work
  identically. Cross-user new-id consistency becomes possible going
  forward.

### Fixed

- **`hooks/lib/distill_engine.py`** — new `KNOWN_DOMAINS = VALIDATE_AUTO_DOMAINS
  ∪ VALIDATE_HUMAN_DOMAINS`. Proposals whose `domain` falls outside this
  union were previously skipped with `needs-human-judgment` but their
  `status` stayed `pending` forever — invisible to `/cx-validate` (which
  only surfaces `held`) and never processable. They now get HELD with
  `hold_reason="orphan-domain:<name>"`. The operator gets the signal in
  `/cx-validate` and the engineering team gets a signal that a detector
  emitting that domain is missing from the whitelists.
- **`hooks/lib/cross-day-tracker.js`** — `appendDetection()` no longer
  mutates `_trackerCache` in-session. Pre-v3.29.5 a proposal emitted in
  the same Stop run saw the just-added cache entry via Jaccard ≥ 0.70
  trigger matching, counted today's date a second time, and reported
  inflated `dayCount` (1 → 2 → 3 …). Effect at scale (Sprint 8 §4.8
  reactivation, observed 1,077-proposal first run): dozens of
  HUMAN-gated coupling proposals received tier-1 cross-day boost (+0.05
  to +0.15) without genuine cross-day evidence, pushing many into the
  0.70+ band. The v3.28.4 dedup guard against Stop-hook re-emit is
  preserved via a separate per-session memo `_appendedThisSession`
  (Set<date|pattern_id>), independent of the boost-input snapshot.
- **`hooks/session-learner.js:writeProposals`** + new
  **`hooks/lib/proposals-storage.js`** — `proposals.json` →
  `proposals-history.jsonl` archive split. Pre-v3.29.5 `proposals.json`
  held every proposal ever created (pending + accepted + rejected +
  held); production file had 1,206 entries and grew monotonically. Every
  Stop hook re-read and re-wrote the full array. New layout:
  `proposals.json` keeps only live entries (pending + held);
  `proposals-history.jsonl` is append-only, one JSON object per line.
  One-shot migration is idempotent via `.migrated-to-history.jsonl`
  flag. Downstream consumers (`/cx-validate`, `/cx-audit`, `/cx-retro`)
  continue reading `proposals.json` for the live working set.

### Sprint 8 observation window — protected

**Zero changes to detector signal:** none of `detectErrorResolutions`,
`detectUserCorrections`, `detectFileCoupling`, `detectAgentPatterns`,
`detectAgentSubtypes`, nor the `BOOST_TIERS` / `applyCrossDayBoost` boost
logic was touched in this release. The 5 fixes above are exclusively in
the downstream safety layer + privacy scrubber + storage layout.
Deferred to a future release: detector cap-per-session, correction
action wording rewrite, `dedupProposalsByIncident` coverage for coupling
and agent-pattern, productivity-patterns lock, kill-switch rename,
`SessionStart` pending counter accuracy.

### Tests

- New `tests/test_v329_5_safety.sh` — 9/9 PASS (F1 orphan-domain held,
  F2 injection rejected + YAML not written, F2b clean accepted, F4
  macOS + Linux path scrub + secret-scrub regression, F5 split +
  idempotent).
- Extended `tests/test_cross_day_tracker.sh` — +2 cases (F3
  no-in-session-inflation, F3 historical-evidence-boost-regression).
  14/14 PASS.
- Regression: `test_security` 7/7, `test_dream_cycle` 38/38,
  `test_integrity` 14/14.

## [3.29.4] — 2026-05-16

### Security

- **`hooks/observe.py`** — new `_scrub_git_remote()` strips embedded
  credentials (`user:token@host`) from HTTPS git remotes before they
  reach `registry.json`, the project cache, or the `project_id` hash.
  `scrub_secrets` only runs on observation `input`/`output`/`err_msg`
  fields and never inspects the registry, so a remote configured with
  an in-URL PAT was being persisted in plaintext.

- **`hooks/session-learner.js:1387`** — `evalErrorMonitor()` now gates
  user-supplied `ev.error_pattern` through `isSafeRegex()` from
  `lib/regex-guard.js` before compiling, matching the ReDoS guards
  already in place at `:912` and `:921`. A malformed instinct trigger
  pattern could previously hang the Stop hook during impact-funnel
  evaluation.

### Fixed

- **`hooks/observe.py:450`** — `hashlib.md5` → `hashlib.sha256` for the
  observation dedup hash. MD5 raises `ValueError` under FIPS-enforced
  Python (RHEL / CentOS hardened deployments) and the top-level except
  in `main()` only writes to stderr under `CORTEX_DEBUG` — observations
  were silently discarded in production. SHA256 is FIPS-compliant and
  equally fast for the 16-char prefix used.

- **`hooks/session-learner.js:122`** — `shortHash()` MD5 → SHA256.
  Same FIPS failure mode in Node: `crypto.createHash('md5')` throws,
  the outer try/catch in `main()` swallows it, and the entire Stop hook
  exits without producing proposals or updating instincts.

- **`hooks/observe.py:108,574`** — `write_with_lock()` accepts an
  optional `pre_write_fn` that runs inside the lock immediately before
  the append. `main()` now passes `archive_if_needed` as `pre_write_fn`
  so the size check + rename happen under the same lock as the append,
  closing a race where a concurrent writer could append into a
  just-renamed file. The archive timestamp also switched to
  `datetime.now(timezone.utc)` to match the rest of the file.

- **`hooks/session-learner.js:477`** — `slugifySubtype()` second
  `&&`-operand was recomputing `slug` so the equality check was a
  tautology — sanitized-but-collision-prone inputs (`foo/bar` and
  `foo-bar` both → `foo-bar`) returned the same id and the
  hash-suffix path documented at `:475` never ran. Corrected to
  `slug === lower`, so the hash suffix fires whenever the input had
  characters stripped or normalized.

- **`hooks/lib/distill_engine.py:241`** — `_atomic_write` wrapped in
  try/finally so a failed `os.replace` (EACCES, cross-device,
  Windows `EBUSY`) no longer leaks `.tmp.PID` files. Matches the
  pattern already in `hooks/observe.py:atomic_write_json`.

- **`hooks/lib/distill_engine.py:752`** — `/cx-distill` audit message
  now uses `f"projects < {LAW_MIN_PROJECTS} ({proj_count} seen)"`
  instead of the stale literal `"projects < 3 (...)"`. The constant
  was lowered from `3` to `1` in v3.24.0; the audit message had been
  misleading operators ever since.

- **`hooks/session-learner.js:1576`** — `knowledge-log.md` append
  failures now surface under `CORTEX_DEBUG` instead of being swallowed
  by `catch {}`. Plain append is intentional — concurrent Stop hooks
  tolerate interleaved single-line writes, while tmp+rename without a
  lock would drop concurrent updates.

### Changed

- **`skills/cortex/SKILL.md`** — header bumped `v3.28.5` → `v3.29.4`
  (3-release drift caught by the prior frontmatter scan; v3.29.1/.2/.3
  did not touch the SKILL header).

### Notes

This release is the direct output of an Adversarial Defense pass with
Codex GPT-5.5 on a 5-blocker diagnosis emitted by an internal
`sonnet-reviewer` audit. Codex confirmed 3 blockers as-is, rewrote 2
fixes (slug tautology and knowledge-log strategy), and surfaced 4
P1 findings sonnet had missed: the two FIPS-MD5 sites, the git remote
credential leak, the ReDoS gap, and the archive/write race. All 9
landed in this patch.

### Tests

- Pre-push suites still green: `test_security.sh`, `test_dream_cycle.sh`,
  `test_integrity.sh`. No new test files added — all 9 fixes are
  surgical patches to code paths exercised by the existing 433-PASS
  suite from v3.29.0.

## [3.29.3] — 2026-05-16

### Fixed

- **`hooks/observe.py:108`** — `write_with_lock()` Windows fallback was
  taking the lock on the data file's own FD and calling `f.seek(0)` before
  `msvcrt.locking(..., LK_UNLCK, 1)`. On Windows installs this could
  corrupt the append cursor for `observations.jsonl`. Rewritten to lock
  a SEPARATE `.lock` file (parity with the POSIX `fcntl.flock` path,
  which was already correct and is untouched). Adds an inner
  `try/except OSError` that degrades to plain append if the lock is
  unavailable so the hook never blocks. POSIX behavior unchanged.

- **`hooks/injector.sh:7,24`** — dropped `set -e` and switched `echo
  "$INPUT_JSON"` → `printf '%s\n' "$INPUT_JSON"`. The hook documents
  itself as "exits 0 silently on any error (never blocks Claude)", but
  with `set -e` a failure in `mktemp`/`chmod`/redirect would exit
  non-zero mid-script before reaching the explicit `exit 0`. `printf`
  also avoids `echo` interpreting payloads starting with `-` as flags.
  Both critical steps now use explicit `|| exit 0`.

- **`hooks/session-learner.js:785-878`** — `updateInstincts()` no longer
  reads and rewrites `instinct-tracking.json` once per matched instinct
  (N updates = 2N atomic ops + race window where two concurrent Stop
  hooks could lose writes). The tracking file is now read ONCE before
  the loop (lazy), mutated in memory via the new
  `_mirrorToTrackingMem(tracking, ...)` helper, and flushed ONCE after
  the loop via `_flushTracking(tracking)`. Behavior preserved: counts
  never regress, `last_seen` is timestamped at write time, missing
  `first_seen` is backfilled.

### Changed

- **`README.md` + `docs/FEATURES.md`** — doc sync for the v3.29.2 cap
  raise. `README.md:37` `Laws (max 10) ~550 tokens` → `(max 12) ~630
  tokens` (SessionStart injection point); `README.md:268` data
  directory tree `# One-liners (max 10 active)` → `(max 12 active)`;
  `README.md:336` token budget row `Laws (max 10) | ~300` →
  `(max 12) | ~480`. `docs/FEATURES.md:112` `Injects Laws (max 10)`
  → `(max 12)`; `docs/FEATURES.md:510` token budget row
  `Laws (max 10) | ~400` → `(max 12) | ~480`.

- **`docs/FEATURES.md`** — `CORTEX_AUTODISTILL_OFF` documented as the
  third Sprint 8 kill switch alongside `CORTEX_OBSERVE_OFF` and
  `CORTEX_DETECTORS_OFF`. It lives at `hooks/lib/distill_engine.py:1396`
  and was already shipped in v3.29.0, just absent from the feature
  reference.

### Tests

- All 3 mandatory pre-push suites still green: `test_security.sh` 7/7,
  `test_dream_cycle.sh` 38/38, `test_integrity.sh` 14/14. No new tests
  added — all three fixes are surgical patches to existing code paths
  exercised by the current suite.

## [3.29.2] — 2026-05-16

### Changed

- **`hooks/lib/distill_engine.py:82`** — `LAW_MAX_ACTIVE` raised from
  `10` to `12`. After Sprint 8 (v3.29.0) cleaned the detector pipeline,
  `auto-distill-candidates.md` accumulated 25 conf≥0.95 instincts blocked
  on the single failure reason `laws == 11 (max 10)`. The cap was the
  bottleneck, not the quality gates. Net token cost: +80 tok/session
  baseline (2 extra laws × 40 tok per session). All other promotion
  gates unchanged: `LAW_THRESHOLD_CONF=0.95`, `LAW_SUSTAINED_DAYS=14`,
  `LAW_MIN_DISTINCT_SESSIONS=3`, `LAW_MAX_NOISE_14D=0`,
  `LAW_MIN_USEFUL_14D=5`. The universality filter applied by `/cx-distill`
  Step 3a still rejects niche candidates.

### Notes

- Companion to a manual `/cx-distill` pass run the same day: archived
  2 non-universal laws (`workflow-repo-first-install-after`,
  `fersora-wikilink-path-drift-in-templates`), archived 2 stale global
  instincts (`fersora-downloads-read-not-cat` duplicated the law
  `macos-downloads-read-tool`, `agent-pattern-658cb3c0` was detector
  noise), and promoted `pattern-test-after-change` to a new law. Net
  active laws after the manual pass: 10. The cap raise to 12 leaves
  room for the next 2 auto-promotions to land without a manual
  intervention.

## [3.29.1] — 2026-05-16

### Removed

- **`/cx-stop` command** — retired. The Stop hook fires automatically when
  Claude Code closes a session normally, and v3.29.0's PreCompact hardening
  (§4.15) closed the `/compact` data-loss gap that was the only remaining
  real use case for the manual trigger. The command was carried in the
  catalog and banners for 1 minor release but never used in practice.
  Removed from: `commands/cx-stop.md` (file deleted), `commands/cx-router.md`
  (catalog table), `core/claudemd-section.md` (CLAUDE.md section template),
  `hooks/session-start.py` (commands hint string), `skills/cortex/SKILL.md`
  (frontmatter description + `### Commands (21)` → `(20)` header + table
  row), `README.md` (`## Commands (21)` → `(20)` + table row + tests line),
  `docs/FEATURES.md` (tests table + version history),
  `tests/test_install.sh` (21 → 20 commands count assert),
  `tests/test_install_ps1.ps1` (required-sources list),
  `tests/test_v328_operational.sh` (removed `cx-stop: session-learner exits
  0` test case, 5 → 4 in the suite).

### Tests

- `test_v328_operational.sh`: 5 → 4 PASS (removed `cx-stop` test).
- `test_install.sh`: still 42 PASS (count assert updated 21 → 20).
- Full suite: **432 PASS / 0 FAIL** (was 433 in v3.29.0, -1 for the removed
  cx-stop test case).

## [3.29.0] — 2026-05-16

Sprint 8 — Detector overhaul + autopilot foundation. Largest single release
since Sprint 5. Full plan in `docs/SPRINT-8-DETECTOR-OVERHAUL.md` (v7 final,
post 3 rounds of Codex AD review).

### Added

- **`hooks/lib/regex-utils.js`** — new shared module with canonical
  `escapeRegex()` helper. Used by `detectFileCoupling` and
  `detectUserCorrections` (formerly each had an inline escape).
- **`hooks/lib/distill_engine.py`** — `coupling` + `agent-quality` registered
  in `VALIDATE_HUMAN_DOMAINS`. Pre-v3.29 both were orphan domains: detectors
  emitted them but no whitelist accepted them, so every proposal fell through
  `needs-human-judgment` forever and no instinct ever materialised.
- **`hooks/lib/distill_engine.py`** — new `_detect_unauthorized_rejections()`
  ghost guard runs at the top of `auto_validate_proposals()`. Restores
  proposals rejected by identities NOT in `VALIDATE_AUTHORIZED_REJECTERS`
  (intentionally excludes `cx-validate-auto`, the 2026-05-05 bulk-reject
  ghost — see `docs/GHOST-CX-VALIDATE-AUTO.md` for git archaeology).
- **`hooks/lib/distill_engine.py`** — new multi-session law promotion gate:
  `LAW_MIN_DISTINCT_SESSIONS=3`, defensive `_count_distinct_sessions()`
  reader (handles missing file / malformed schema / duplicates / empty
  UUIDs), grandfather clause so pre-v3.29 conf≥0.95 instincts without a
  tracking entry promote without retroactive blocking. Source pattern:
  Sinapsis `core/_instinct-activator.sh:43-63` (see
  `docs/SINAPSIS-COMPARISON.md`). Visible in `/cx-status --pipeline` as
  `sessions N/3 (need M more)` for blocked candidates.
- **`hooks/observe.py`** — `CORTEX_OBSERVE_OFF=1` kill switch (§4.8).
  Returns before any write: observations.jsonl, dedup files, registry,
  archive, obs-count all stay untouched.
- **`hooks/session-learner.js`** — `CORTEX_DETECTORS_OFF=1` kill switch
  (§4.8). Short-circuits the 5 proposal-emitting detectors to []. Side-
  effecting detectors (time-of-day, command-usage) keep running so
  productivity-patterns.json + timeline.jsonl + reflexes + impact +
  outcome-nudge are preserved.
- **`hooks/lib/distill_engine.py`** — `CORTEX_AUTODISTILL_OFF=1` kill
  switch (§4.8). Returns BEFORE rate-limit AND any state mutation:
  proposals, instinct YAMLs, laws, evolved drafts, candidates markdown,
  cross-day-tracker prune, .last-auto-distill marker all skipped.
- **`hooks/precompact.py`** — hardening (§4.15): `CORTEX_OBSERVE_OFF` +
  `CORTEX_DETECTORS_OFF` honored at top of main(), `CORTEX_SESSION_ID`
  exported to spawned learner as env var (belt-and-suspenders for the
  stdin pipe), entire main() wrapped in try/except for guaranteed exit 0.
- **`tests/cleanup_retired_instincts.sh`** — one-shot ops script,
  idempotent + reversible mover of orphan `repeat-*` / `workflow-*` YAMLs
  from active instinct dirs to `archive/retired-instincts-<TS>/` with
  manifest.
- **`tests/archive_proposals_backups.sh`** — one-shot ops script bundling
  `$CORTEX_DIR/proposals.json.bak*` files into a timestamped tar.gz +
  SHA-256 + manifest. Originals removed AFTER archive on disk.
- **`tests/test_kill_switches.sh`** NEW (10 cases) — isolation tests for
  the 3 env-var switches.
- **`tests/test_session_start.sh`** NEW (4 cases) — `check_maintenance`
  banner gating tests.
- **`tests/test_precompact.sh`** NEW (11 cases) — PreCompact hardening
  contract: smoke, env prop, stdin prop, fire-and-forget against hung
  child, crash safety, idempotent double-flush, both kill switches.
- **`tests/test_e2e_pipeline.sh`** NEW (10 cases) — end-to-end:
  synthetic observations → Stop hook → proposals → SessionStart →
  auto-distill → asserts. Covers happy path, HUMAN-gated isolation,
  both kill switches, ghost-guard restoration round-trip.
- **`tests/test_v329_acceptance.sh`** NEW (9 invariants) — pre-ship
  acceptance gate run in a clean install sandbox (HOME-isolated +
  `install.sh` + 6-newline defaults). Wired into `.githooks/pre-push`
  as a BLOCKING check between Security and Version-sync gates.
- **`docs/GHOST-CX-VALIDATE-AUTO.md`** — git archaeology of the
  2026-05-05 bulk-reject incident. Verdict: external non-reproducible,
  ghost guard is the preventive mitigation.
- **`docs/SINAPSIS-COMPARISON.md`** — Día 0 spike comparing fs-cortex
  with Sinapsis 3.2. Verdict: `inspiring_patterns` (no migration).
- **`docs/SPRINT-8-DETECTOR-OVERHAUL.md`** — full plan v7 (final after 3
  rounds of Codex AD review).

### Changed

- **`hooks/session-learner.js` `detectFileCoupling`** — rewritten emit
  (§4.2). Trigger from malformed `Edit|f1|f2` (a degenerate alternation
  the runtime matcher interpreted as "match literal Edit OR f1 OR f2
  anywhere") to safe regex `Edit.*(?:${escapeRegex(baseA)}|${escapeRegex(baseB)})`
  evaluated against the runtime `toolName + " " + JSON.stringify(input)`
  matchTarget (verified at `injector-engine.js:89`). Action from
  descriptive statistic to imperative "When editing baseA, also check
  baseB — coupled in N+ sessions in this project." Confidence 0.40 →
  0.55 (above `VALIDATE_MIN_CONF`). `scope: 'project'` (NEW, critical
  to prevent cross-project bleed). `project_id` propagated from
  `observations[0]._projectId`.
- **`hooks/session-learner.js` `detectUserCorrections`** — rewritten as
  HUMAN-gated emitter (§4.3). Domain `user-preference` → `correction`
  (semantically correct — a repeat-correct on the same file is a
  code-quality signal, not a user preference). Confidence 0.40 → 0.55.
  Action imperative: "Before editing ${file}, scan recent commits —
  corrected N+ times. Pattern likely needs deeper attention." Scope
  `'project'` + project_id propagated.
- **`hooks/session-learner.js` `detectAgentSubtypes`** — rewritten as
  HUMAN-gated emitter (§4.4). Confidence 0.45 → 0.50 (at validate
  floor). Imperative action: "Before spawning Agent subagent_type=X
  again, switch to general-purpose or refine the prompt — current
  type errored in N% of M uses." Domain `agent-quality` unchanged but
  now registered in `VALIDATE_HUMAN_DOMAINS`.
- **`hooks/session-learner.js` `detectAgentPatterns`** — min items
  3 → 4 (§4.5). At 3 the first emitted confidence was exactly 0.55
  (tied with the validate floor); at 4 the floor is 0.60.
- **`hooks/session-start.py` `check_maintenance`** — `[ACTION]` banner
  counts only proposals whose domain is in `VALIDATE_AUTO_DOMAINS`
  (§4.10). Pre-v3.29 every pending proposal triggered the nag, so
  HUMAN-gated detectors caused permanent noise. HUMAN-gated proposals
  now surface via `/cx-status --pipeline` instead.

### Fixed

- **`hooks/precompact.py`** — pre-v3.29 only the `_spawn_learner` block
  was wrapped in try/except, so a failure in `_parse_session_id` or
  `_already_flushed` would bubble up and Claude Code would log a hook
  failure even though precompact's contract is fire-and-forget.

### Removed

- **`hooks/session-learner.js` `detectRepetitions`** — retired
  (deleted function + call site + module.exports). Confidence 0.30
  was sub-floor and the action was descriptive not directive; in
  6 months produced 210 unactionable proposals with no rewrite path.
- **`hooks/session-learner.js` `detectWorkflowChains`** — retired
  (deleted function + call site + module.exports + local helper
  in `tests/test_session_learner.sh:80`). Trigger emitted only the
  first tool of the trigram so sequence context was lost in the
  resulting instinct; no viable rewrite.
- **`CORTEX_LEGACY_DETECTORS` env var** — retired (the 3 gated
  detectors are now live by default after the §4.2-§4.5 rewrites;
  the new `CORTEX_DETECTORS_OFF` replaces it as the opt-out).
- **`docs/V3.27-GATES-CLOSED.md`** — closure record removed (Sprint 5
  and v3.27 gates fully closed in v3.28.9; the doc was kept as
  history through Sprint 8 and is no longer needed).

### Tests

- Full suite: **433 PASS / 0 FAIL** (was 366/0 pre-Sprint-8, +67 cases).

## [3.28.9] — 2026-05-15

### Changed

- **`hooks/lib/impact_log.py` `gate_recommendation()`** — switched from `useful_ratio_user` / `health_ratio_user` to the aggregate `useful_ratio` / `health_ratio`. Rationale: reflex feedback (the dominant signal) is always written with `source: "agent"` by `correlateReflexFeedback` in `session-learner.js:1553`. The previous formula excluded agent-sourced events, making Sprint 5 Gate 1 structurally unable to ever PASS for any reflex even when `reflexes.json` showed healthy useful/noise ratios (e.g. bash-grep-use-grep-tool = useful=60, noise=3, ratio=20× was invisible to the gate). The new formula treats agent self-evaluations against the tool-substitution / error-monitor evaluators as valid signal (those evaluators are deterministic). Closes Sprint 5 Gate 1.
- **`hooks/session-learner.js`** — five detectors with structural bugs gated behind `CORTEX_LEGACY_DETECTORS=1` (default OFF):
  - `detectRepetitions` (conf=0.30 sub-floor, descriptive action)
  - `detectUserCorrections` (domain `user-preference` human-gated, action non-directive)
  - `detectWorkflowChains` (trigger only emits first tool of trigram, loses sequence context)
  - `detectAgentSubtypes` (domain `agent-quality` orphaned — not in any `distill_engine.py` whitelist, every proposal falls through to needs-human-judgment skip)
  - `detectFileCoupling` (trigger `Edit|f1|f2` is malformed regex alternation; domain `coupling` orphaned)
  Result: these no longer emit proposals on Stop. `detectErrorResolutions`, `detectAgentPatterns`, `detectTimeOfDayPatterns` and `detectCommandUsage` stay active. Sprint 8 (v3.29.x) will rewrite the disabled detectors with valid triggers / actions / whitelisted domains.

### Fixed

- Bulk-rejected stale pending proposals from the 5 disabled detectors with reason `v3.28.9-detector-disabled`. Clean slate for the new pipeline.

### Removed

- `docs/SPRINT-5-PENDING-GATES.md` (Sprint 5 closed; Gate 2 was already PASS with ratios 14× / 4× / 20×, Gate 1 was unmeasurable due to the metric bug above)

### Documentation

- `docs/V3.27-DETECTOR-GATES.md` renamed to `docs/V3.27-GATES-CLOSED.md` with closure summary. Gates C (productivity) + D (cross-day boost) PASS; A + B were symptoms of orphan-domain bugs and are deferred to Sprint 8.
- `docs/SPRINT-8-DETECTOR-OVERHAUL.md` added — full diagnosis of three structural bugs (broken Gate 1 metric, 5 noisy detectors, orphan `cx-validate-auto` script) plus the forward plan for end-to-end pipeline automation in Sprint 8.
- `CLAUDE.md` "Pending validation" section replaced with "Active sprint" pointing to Sprint 8 plan.

## [3.28.8] — 2026-05-13

### Changed

- `commands/cx-analyze.md` — added `Step 0: Preflight — MUST run on Opus 1M` at the top of the Implementation section. The command now refuses to proceed unless the active session is `claude-opus-4-7` (or newer Opus) with the `[1m]` context flag, and prints a switch-model instruction. Sonnet/Haiku and Opus without 1M cannot fit the 1.5-3 MB compressed observation payload in a single context, which previously caused silent sampling, mid-analysis failures, or workaround sub-Agent fanout that defeats the purpose of inline cross-project visibility.

## [3.28.7] — 2026-05-09

### Fixed

- `commands/cx-status.md` collector script — replace all bare `open()` calls with `with` context managers (8 sites: laws, registry, YAML parser, obs count loop, reflexes, settings, last-obs, tracking). Eliminates fd leak risk on large registries. Fix unsafe `int(sess)` cast in tracking parser: now `(int(sess) if isinstance(sess, (int, float)) else 0)` instead of bare `int(sess)` which raised on dict/None/unexpected types.

## [3.28.6] — 2026-05-09

### Changed

- `commands/cx-status.md` — replace 3-round multi-step data collection with a single Python3 collector script. All 7 dashboard sections (laws, instincts, projects, reflexes, health, tracking, evolved) are now gathered in one Bash call that outputs JSON, eliminating ~4 LLM turns of latency. Regex-based flat YAML parser (no pyyaml dependency). No behavior change — same dashboard, same flags, same output format.

## [3.28.5] — 2026-05-09

### Fixed (AD GPT-5.5 audit findings, post-v3.28.4)

- **`hooks/session-learner.js` `detectRepetitions`** — emitted `source: 'session-learner'` plain (no suffix) while the other 5 detectors used `'session-learner:<name>'`. Inconsistent schema broke pipeline-stats per-detector counters and produced 210 hard-to-classify production proposals. Now emits `'session-learner:repetition'`.
- **`hooks/session-learner.js` `detectAgentSubtypes` + `detectFileCoupling`** — both v3.27.0 detectors omitted the `status: 'pending'` field that the other 5 detectors include. `writeProposals()` dedup at line 956 (`existing.status !== 'pending'`) treats `undefined !== 'pending'` as truthy, so legacy entries without status were preserved as final/unupdateable. `/cx-validate` filters by `status === 'pending'` exactly, so the 129 file-coupling proposals were invisible to the validation queue. Both detectors now emit `status: 'pending'`. Runtime data file backfilled in this release (129 proposals → status='pending').
- **`hooks/session-learner.js` `detectAgentSubtypes` security** — `subagent_type` from `JSON.parse(obs.input)` is user-controlled and was embedded raw in proposal id (which becomes a YAML filename). New `slugifySubtype()` allowlists `[a-z0-9_-]`, caps at 40 chars, hashes if anything was stripped. Raw value preserved only in the action text (already sanitized). Closes path-traversal vector via `subagent_type: '../../etc/passwd'`.
- **`hooks/lib/distill_engine.py` `_prune_cross_day_tracker()`** — Python port of v3.28.4 dedup logic was missing. The Node `prune()` compacted same-day duplicates but the Python prune (called by `run_auto_distill()`) did not. Now both prune paths compact identically. Parity restored.
- **`hooks/session-start.py` `write_daily_snapshot()`** — `observations` field was misnamed: held lifetime line-count of `observations.jsonl`, not daily volume. Field renamed to `observations_total_active`; new `observations_on_date` filters lines whose `ts` starts with `last_date`. Daily snapshot files now reflect actual daily activity vs. cumulative file size.

### Added
- 3 new schema-completeness tests in `tests/test_detectors_v327.sh` (12 → 13 PASS): agent-subtype slugify, status='pending' assertions on detectAgentSubtypes + detectFileCoupling.
- `tests/test_v328_operational.sh` snapshot test updated for split fields.

### Known limitations (documented, deferred)

- **`detectFileCoupling` sid scope** — when `CORTEX_SESSION_ID` matches observations the detector receives 1 sid → cannot emit (needs 5+). Only fires in the fallback path (last-200 cross-project obs) which mixes sessions of different projects. Re-evaluate threshold/scope on the 2026-05-11 gate review with measured data; full redesign deferred to v3.29.0.
- **`detectTimeOfDayPatterns` race** — concurrent Stop hooks reading `productivity-patterns.json` then computing merged data race on rename (last-writer-wins). Documented in code comment; full lock deferred to v3.29.0.
- **`writeProposals` rejected retention** — 677 proposals with `status='rejected'` accumulate without archival policy. Policy + per-detector noise metrics in `/cx-status --pipeline` deferred to v3.29.0.

## [3.28.4] — 2026-05-09

### Fixed
- **`hooks/lib/cross-day-tracker.js`** — `applyCrossDayBoost()` was unconditionally appending to `cross-day-tracker.jsonl` on every call. The Stop hook re-processes observations and re-emits the same proposals on each session close, so the tracker grew by 21× expected size: a real install accumulated **15,061 entries with only 703 distinct pattern_ids in a single day**. The bug was discovered immediately after v3.28.3 install via the v3.27 detector gates baseline. **Fix:** add `same-day same-pattern_id` guard before `appendDetection()` — only append the first detection per `(date, pattern_id)` pair. Distinct-date counting (the boost logic) is unaffected because the first append of the day is always made, so `cross_day_count` and the +0.05/+0.10/+0.15 tiers behave identically. **Forward-only:** existing bloated trackers self-heal on next `run_auto_distill()` (see prune fix below).
- **`hooks/lib/cross-day-tracker.js`** — `prune()` now also compacts same-day same-pattern_id duplicates accumulated before the v3.28.4 guard was added. Idempotent: keeps the first occurrence per `(date, pattern_id)` pair. Existing tracker files with 15k bloat will compact to ~700 unique entries on the next auto-distill cycle.

### Added
- 2 new tests in `tests/test_cross_day_tracker.sh` (10 → 12 PASS): same-day re-append guard, prune() same-day dedup of legacy data.

## [3.28.3] — 2026-05-09

### Added
- `docs/V3.27-DETECTOR-GATES.md` — measurement plan with 5 gates (A-E) for the 3 new v3.27.0 detectors + the v3.26.0 cross-day boost. Each gate has a pass criterion, a measurement bash one-liner, and an action plan if FAIL. Re-check date: **2026-05-11 (Monday)**. Gates A-B measure proposal accept ratios (`detectAgentSubtypes`, `detectFileCoupling`); Gate C measures `productivity-patterns.json` aggregates; Gate D measures `cross-day-tracker.jsonl` boost activity; Gate E sanity-checks new detectors' confidence vs old detectors.
- `.gitignore` — `!docs/V3.27-DETECTOR-GATES.md` allowlist entry.
- `CLAUDE.md` — Pending validation section now references both `SPRINT-5-PENDING-GATES.md` and the new gates file with measurement context.

## [3.28.2] — 2026-05-09

### Documentation
- `skills/cortex/SKILL.md` header bumped from stale `v3.19.2` → `v3.28.2`. Drift accumulated across 9 releases.
- `README.md` `## Commands (20)` → `(21)`, added `/cx-stop` row.
- `README.md` Tests section rewrite — listed all 20 bash test suites + 1 PowerShell suite (was listing 11 outdated suites with stale counts). Added: test_impact, test_distill_engine, test_yaml_normalize, test_guard_corpus, test_install_downgrade, test_migrate_legacy_iid, test_reflex_matchers, test_cross_day_tracker, test_detectors_v327, test_v328_operational. Updated all per-suite counts.

## [3.28.1] — 2026-05-09

### Fixed
- `tests/test_install.sh` expected hardcoded count of 20 commands but v3.28.0 added `/cx-stop` (now 21). CI on Ubuntu+macOS × Python 3.11/3.13 × Node 22/24 was failing on `Fresh Install / commands: 21 (expected 20)`. Test corrected to 21.
- `core/claudemd-section.md` Commands list missing `/cx-stop` — added (used by installer to write Cortex section into user CLAUDE.md).
- `commands/cx-router.md` table missing `/cx-stop` row — added with cost estimate.
- `hooks/session-start.py` `Cortex commands:` hint string missing `/cx-stop` — added.
- `skills/cortex/SKILL.md` description frontmatter, command count (20→21), and table all missing `/cx-stop` — added.

## [3.28.0] — 2026-05-09

### Added
- `commands/cx-stop.md` — new `/cx-stop` command that manually triggers the Stop hook pipeline (`session-learner.js`) on demand without closing the chat. Uses `uuidgen` with Python UUID fallback for portability. Writes log to `$TMPDIR`.
- `hooks/session-start.py` — `write_daily_snapshot(last_date)` function: writes `~/.claude/cortex/daily-snapshots/YYYY-MM-DD.json` on the first SessionStart of each new day. Captures `observations` counts per project, `proposals_count`, `instincts_global`, `instincts_project_total`, `laws_count`. Idempotent (skips if file already exists). Atomic write via tmp+replace. Permissions 0o600.
- `commands/cx-analyze.md` — `--deep` flag spec: before compressor runs, concatenates `observations.archive/*.jsonl` (archives first, chronological) with active `observations.jsonl`. Warns if total >5MB.
- `tests/test_v328_operational.sh` — 5 tests: snapshot creates correct JSON, snapshot is idempotent, snapshot graceful with empty CORTEX_DIR, cx-stop session-learner exits 0, cx-analyze --deep spec is present.

### Changed
- `session-start.py` `main()` now calls `write_daily_snapshot(last_date)` when `is_new and last_date` fires (v3.28.0).

## [3.27.0] — 2026-05-09

### Added
- `detectAgentSubtypes(obs)` in `hooks/session-learner.js` — emits a proposal when a specific `Agent` subagent type has ≥3 uses with >30% error rate; confidence 0.45; exported for tests.
- `detectFileCoupling(obs)` in `hooks/session-learner.js` — emits a proposal when two files are edited together in ≥5 distinct sessions; confidence 0.40; exported for tests.
- `detectTimeOfDayPatterns(obs)` in `hooks/session-learner.js` — accumulates tool-use counts and error rates into `~/.claude/cortex/productivity-patterns.json` (by-hour and morning/afternoon/evening/night buckets) on every Stop hook; returns `[]` (side-effect only); exported for tests.
- `commands/cx-status.md` — `--reflect` flag reads and renders `productivity-patterns.json` with hourly breakdown, bucket stats, and auto-generated insights.
- `commands/cx-status.md` — `--help` flag shows command reference without running the dashboard.
- `tests/test_detectors_v327.sh` — 12 tests covering all three new detectors (emit threshold, no-emit, error-rate gate, file-path filtering, JSON structure, merge accumulation, insights generation, corrupted-file no-clobber, `::` path edge case).

### Changed
- `session-learner.js` `main()` now calls all three new detectors; `agentSubtypeProposals` and `couplingProposals` are merged into `rawProposals`; `detectTimeOfDayPatterns` called for side-effect.
- `setTimeout` in `session-learner.js` now uses `.unref()` so `require()` in tests does not hold the Node process alive.
- `detectFileCoupling` pair key delimiter changed from `::` to null byte (`\x00`) — file paths containing `::` no longer corrupt the pair split.

### Fixed
- `detectTimeOfDayPatterns`: JSON parse failure on existing `productivity-patterns.json` now aborts the write (returns `[]`) instead of silently clobbering historical data with an empty aggregate.
- `detectTimeOfDayPatterns`: merge+write block restructured — existing file read moved inside the write try-block to minimize the read-modify-write race window (known race documented, same pattern as `cross-day-tracker.js`).

## [3.26.0] — 2026-05-09

### Added

- `hooks/lib/cross-day-tracker.js` — append-only tracker (`~/.claude/cortex/cross-day-tracker.jsonl`) for cross-day pattern detection. Generic wrapper `applyCrossDayBoost()` boosts confidence (+0.05/+0.10/+0.15) when same pattern repeats across distinct days. Survives `proposals.json` cleanup (independent file). Jaccard ≥0.70 fallback on `trigger_norm` handles regex variants. Confidence capped at 0.95.
- `_prune_cross_day_tracker()` in `hooks/lib/distill_engine.py` — auto-prunes entries >365 days during `run_auto_distill()`.
- `tests/test_cross_day_tracker.sh` — 9 tests (PASS): roundtrip, boost tiers (1/2/4/8 days), cap at 0.95, Jaccard match, prune, concurrent append.

### Changed

- `hooks/session-learner.js` — all 5 detectors that emit proposals (errorResolutions, repetitions, userCorrections, workflowChains, agentPatterns) now have their output wrapped with `applyCrossDayBoost` AFTER `dedupProposalsByIncident` and BEFORE `writeProposals`. Each emitted proposal carries `cross_day_count` and `cross-day-N` tag. `detectCommandUsage` is unchanged (it does not emit proposals).
- `hooks/observe.py` — defaults: `MAX_FILE_SIZE_MB` 10→5, `ARCHIVE_DAYS` 30→90. Configurable via `memory.json` `config.max_observations_mb` and `config.archive_days`.

### Fixed (AD GPT-5.5 findings)

- `hooks/lib/cross-day-tracker.js` — Jaccard matching now requires ≥2 tokens in both triggers before activating, preventing false cross-day links between unrelated proposals with single-token triggers (e.g. `Bash`, `Edit`). New test `test_cross_day_tracker.sh` #9.
- `docs/FEATURES.md` — Config table `max_observations_mb`/`archive_days` defaults corrected to 5/90 (were stale at 10/30).

### Known limitation

- `prune()` in `cross-day-tracker.js`: a concurrent `appendFileSync` between `readFile` and `renameSync` causes 1 tracker entry to be lost. Impact is negligible (cross-day-count off by 1 on one run, self-heals next session). Cross-language locking deferred.

### Migration

- Existing `proposals.json` entries are preserved unchanged. New proposals after upgrade carry the new fields.
- `cross-day-tracker.jsonl` starts empty and grows organically.
- Users with `memory.json` overrides keep their values (only defaults change).

## [3.25.5] — 2026-05-09

### Changed

- `hooks/observe.py` — `LEARN_THRESHOLD` default raised from 50 to 100 (configurable via `memory.json` `config.learn_threshold`)
- `hooks/session-start.py` — `check_learn_pending()` now reads `learn_threshold` from `memory.json` config instead of hardcoding 50; both the flag-path and count-path use the same threshold

## [3.25.4] — 2026-05-08

### Fixed

- `commands/cx-analyze.md` — Step 6 added: after displaying results, delete `~/.claude/cortex/.learn-pending` and rewrite `~/.claude/cortex/.last-learn-count` with the current observation total, so session-start does not re-fire the "50+ new observations" banner until ≥50 genuinely new observations accumulate.
- `commands/cx-distill.md` — Step 6 extended: after `touch .last-distill`, truncate `~/.claude/cortex/auto-distill-candidates.md` to empty, so session-start `[MAINT]` reminder suppresses until `distill_engine.py` finds new candidates on the next SessionStart.

## [3.25.3] — 2026-05-08

### Fixed

- `commands/cx-analyze.md`: stale reference to `observe.sh` updated to `observe.py` — fixes `test_integrity.sh` failure across all 8 CI matrix jobs (Python 3.11/3.13 × Node 22/24 × ubuntu/macos)
- `hooks/session-start.py`: remove `[CORTEX ATTENTION]` forced injection — Cortex pending items no longer interrupt every session start; data remains in context for passive awareness
- `.githooks/pre-push`: new pre-push hook running `test_integrity.sh` + `test_security.sh` + version sync check + AI code review (via `claude` CLI) before every push
- `docs/FEATURES-visual.html`: removed — `docs/FEATURES.md` is the single source of truth for feature inventory

## [3.25.2] — 2026-05-07

### Fixed

- **`commands/cx-analyze.md` — Step 3 compressor schema corrected**: The pre-processing pseudocode referenced a stale schema (`timestamp`, `args.*`, `result`, `status`) that never matched what `observe.sh` actually writes to `observations.jsonl`. Real schema: `ts`, `ev` (`"ts"` = tool-start / `"tc"` = tool-complete), `input` (serialized JSON string containing `command`/`file_path`/etc.), `output` (on `tc` events only), `err` (boolean). Wrong compressor stripped all signal and delivered lines like `{"tool":"Bash"}` to the Opus agent — resulting in 0 proposals. Fixed pseudocode now parses `input` as JSON to extract key args, distinguishes `ts`/`tc` event types, and preserves truncated `output` on `err=true` completions. Reduces 10 MB → ~0.5 MB with actual actionable content.

## [3.25.1] — 2026-05-07

### Hotfix — silent downgrade through stale local repo

After v3.25.0 was merged to `main` (commit `a2b304d`), the operator's
local clone of the repo was still at `f9f6bed` (v3.24.1) because no
`git pull` had run. Re-running `bash install.sh` from that stale repo
silently DOWNGRADED a fresh v3.25.0 installation back to v3.24.1
without any warning. The installer is a copy-not-merge of
`hooks/`/`commands/`, so it overwrote the new SessionStart and
session-learner code with the older versions, while preserving
counters — exactly the kind of partial-rewind that is hard to notice
afterwards.

### Fixed

- **`install.sh`** — added explicit downgrade detection. New helper
  `version_lt A B` (uses `sort -V`) is called when an existing
  installation is detected. If the shipped version is older than the
  installed one, the script now aborts with a `DOWNGRADE BLOCKED`
  message that names both versions and suggests `git pull origin main`
  as the likely fix. Pass `--allow-downgrade` to override deliberately.
- **`install.ps1`** — Windows parity. New `Test-VersionLessThan`
  helper (uses `[version]` cast) and the same abort behaviour.
  Accepts `--allow-downgrade` (also `-AllowDowngrade`).
- **`install.sh` / `install.ps1`** — also added a same-version branch:
  re-running the installer with the same version no longer prints
  "Upgrading…" — it now says "already installed — refreshing files".

### Added

- **`tests/test_install_downgrade.sh`** — 5 sandbox tests
  (clean install / same-version refresh / downgrade blocked /
  `--allow-downgrade` override / real upgrade path) using
  `mktemp -d` + `HOME=$SANDBOX` isolation. Reads `NEW_VERSION` from
  `install.sh` so the tests track future bumps automatically. 5/5
  PASS.

### Notes

- Forward-only: existing installations are not migrated. The
  safeguard takes effect on the next `bash install.sh` run.
- Total tests: 17 suites green (the new `test_install_downgrade.sh`
  joined the 16 pre-existing).
- `install.ps1` change was sandbox-tested only via `install.sh` (the
  shared shape); a Windows runner exists in CI and will exercise it.

## [3.25.0] — 2026-05-07

### Two P0/P1 fixes that unlock autonomous operation

After a Codex GPT-5.5 adversarial review of the full pipeline, two
structural issues were surfacing as the user pain "Cortex is not
autonomous, I have to /cx-validate everything by hand": (a) the
highest-signal detector was emitting proposals one tick below the
auto-validate threshold, parking every gotcha in `proposals.json`
forever; and (b) SessionStart was injecting pipeline status as silent
`additionalContext`, so the user never saw the validate / promote /
evolve work that Cortex had already done or was waiting on.

### Fixed

- **`hooks/session-learner.js:266`** — `error-fix` detector confidence
  raised from `0.40` to `0.50`. Domain `error-recovery` is already in
  `VALIDATE_AUTO_DOMAINS` (`hooks/lib/distill_engine.py:84`), but the
  threshold at `VALIDATE_MIN_CONF=0.50` was rejecting the proposal by
  exactly one tick. Net effect of the change: the autonomous pipeline
  *observation → error-fix detector → auto-validate → instinct →
  distill → law* now flows end-to-end without manual intervention.
  The other detectors (`repeat`, `correction`, `workflow`) remain in
  `VALIDATE_HUMAN_DOMAINS` by design — they encode taste/judgment that
  benefits from human review.
- **`hooks/session-start.py:282-360`** — pipeline activity, learn-pending
  banners, and `[ACTION]`/`[MAINT]` reminders now arm a single
  trailing `[CORTEX ATTENTION — present to user in FIRST response]`
  block whenever they have content. Pre-v3.25.0 only `EOD Resume`
  carried that "surface to user" instruction; everything else was
  silently injected as `additionalContext` and the agent buried it.
- **`commands/cx-status.md`** (`--reflexes` panel) — `STATUS` rules
  updated to mirror the v3.24.1 auto-disable gate. The panel was
  labelling reflexes with `useful=116, noise=5` (ratio 23×) as
  "auto-disable candidate" even though the runtime would never
  disable them. New rule: `NOISY` requires `noiseCount >= 3 AND
  fireCount >= 10 AND usefulCount < noiseCount`. Label and gate now
  agree.

### Changed

- **`commands/cx-router.md`** — added the three commands that were
  silently missing from the catalog: `/cx-dashboard`, `/cx-feedback`,
  `/cx-feedback-auto`. Catalog now has 20 entries, matching
  `commands/cx-*.md` and `docs/FEATURES.md`.
- **`hooks/session-start.py:294`** — commands hint string updated to
  list all 20 commands. Pre-v3.25.0 it listed 16 (missing
  `/cx-dashboard`, `/cx-feedback`, `/cx-feedback-auto`,
  `/cx-timeline`).

### Caught by the Codex AD pass and folded in

The same Codex GPT-5.5 review that signed the patch off as `SHIP` also
auto-applied three follow-on fixes that are part of this release:

- **`hooks/session-start.py:384`** — the new `[CORTEX ATTENTION]` block
  was gated behind `elif user_actionable:`, so EOD and ATTENTION could
  never coexist in the same SessionStart. Changed to `if`. Now an EOD
  morning that also has pending pipeline work surfaces both blocks.
- **`tests/test_session_learner.sh:53`** — the `error-fix` fixture used
  the pre-v3.25.0 `confidence: 0.40`. Bumped to `0.50` so the test
  reflects the shipped detector value and future regressions are
  catchable.
- **`README.md` and `skills/cortex/SKILL.md`** — catalog drift
  cleaned. `README.md` was missing `/cx-dashboard`, `/cx-feedback`,
  `/cx-feedback-auto`. `skills/cortex/SKILL.md` was missing those
  three plus `/cx-timeline`; the row count was also corrected
  16 → 20.

### Notes

- No regressions vs v3.24.1: full 16-suite test run passes (16/16).
- Local-only counter tightening was applied to
  `~/.claude/cortex/reflexes.json` for two non-shipped reflexes
  (`python3-bypass-write-tool`, `nextjs-suspense-boundary`) — those
  reflexes are user-local customisations and were *not* added to the
  repo defaults. Backup at
  `/tmp/reflexes-backup-20260507-092415.json`.
- Adversarial Defense review run by Codex GPT-5.5 (model auto-routed
  via the `fs-codex` plugin). Codex's full report is in the PR
  description; the P0 in this changelog is the top-priority item it
  surfaced.
- Command consolidation (20 → 5 canonical) is **deferred** to v3.26.0.
  It is the largest and most invasive change Codex proposed and
  warrants its own release with explicit deprecation aliases for the
  13 commands that would be folded.

## [3.24.1] — 2026-05-05

### Hotfix — auto-disable threshold ignored useful/noise ratio

Within hours of v3.24.0 deploying, `bash-cat-use-read` was auto-disabled
in production with `usefulCount=111` and `noiseCount=3` — a ratio of
37×, clearly working as intended. The auto-disable gate at
`session-learner.js:1315` only checked absolute thresholds
(`noiseCount >= 3 && fireCount >= 10`), ignoring the useful counter
entirely. Same structural conservatism we have been removing all day.

### Fixed

- **`hooks/session-learner.js:1313-1325`** — auto-disable now requires
  `usefulCount < noiseCount` (ratio < 1.0) in addition to the existing
  absolute thresholds. A reflex with 111 useful + 3 noise no longer
  gets disabled. Knowledge-log entry expanded with `usefulCount=...`
  and the resulting ratio so the disable history is auditable.

### Changed

- Re-enabled `bash-cat-use-read` in `~/.claude/cortex/reflexes.json`
  during this release (it had been auto-disabled by the old gate).
  Future Stop hooks under v3.24.1 will not re-disable it because the
  new gate correctly evaluates 111/3 as healthy.

### Notes

- `CORTEX_AGENT_DISABLE_REFLEXES=1` remains the opt-in env var that
  arms the auto-disable path. Without it, session-learner only tracks
  thresholds and never mutates `enabled`.
- Forward-only fix: existing `enabled: false` records were not
  auto-restored — only `bash-cat-use-read` was re-enabled manually
  because its ratio is provably healthy.

## [3.24.0] — 2026-05-05

### Stability release — 7 P0 + 4 P1 fixes for the structural biases that left cortex semi-broken for >1 week

The operator (Fer) reported cortex feeling broken for over a week despite
multiple patches. A 4-agent parallel audit (Opus 1M, areas: PreToolUse
pipeline / Stop pipeline / distill engine / corpus health) revealed
several **structural biases that silently silenced 98%+ of instincts and
mis-counted reflex outcomes**. This release bundles every actionable
finding into a single bump.

### Fixed (P0)

- **`hooks/lib/injector-engine.js:275` — domain filter taxonomy
  mismatch silenced 121/122 instincts.** `cx-analyze` writes `domain`
  field as a *category label* (`gotcha`, `pattern`, `tool-pref`,
  `tooling`, `testing`, `workflow`, `reliability`, `release`, ...)
  but `detectProjectDomains` returns *tech-stack labels* (`react`,
  `node`, `python`, `supabase`, ...). The two vocabularies are
  disjoint, so `!projectDomains.has(inst.domain)` rejected every
  instinct unless `domain: general`. **Fix:** introduced a
  `CATEGORY_DOMAINS` set; category domains always pass; tech-stack
  domains only filter when a real stack was detected
  (`projectDomains.size > 1` or non-`general` only). 121/122
  instincts now eligible for injection.

- **`hooks/session-learner.js:574` — `updateInstincts` matched
  trigger against bare tool name only.** The injector matches against
  `tool + " " + input`; the learner only used `tool`. Composite
  triggers like `'Bash.*\.py'` never matched (regex requires content
  after `Bash`); alternation triggers like `'Bash|grep'` matched
  *every* `Bash` call. Live data showed `gotcha-shellcheck-js-heredoc`
  ratcheting to occurrences=1924 (false positives) while
  `gotcha-bash-cat-instead-of-read` stayed at zero (false negatives).
  **Fix:** updated the loop to test `triggerRegex.test(toolName + " "
  + inputStr)` for parity with `injector-engine.js:110`.

- **`hooks/session-learner.js:176` — sid exact-match silently fell
  back to last 200 cross-project lines.** Pre-v3.19.3 observations
  carry `sid[:24]` while the harness Stop event sends the full 36-char
  UUID. `o.sid === sessionId` failed → `slice(-200)` mixed across
  projects. **Fix:** routed the filter through `buildCandidateSids`
  (already used by every correlation path) so truncated and full sids
  both match.

- **`hooks/session-learner.js:1213` — counter loss after `resetAt`.**
  When `usefulCount`/`noiseCount` were zeroed (manually or by the
  v3.20.0 auto-heal) but `impact.jsonl` retained its feedback history,
  the `alreadyRated` set blocked re-emission and the counters never
  recovered. `read-before-edit` for example lost a noise feedback
  permanently. **Fix:** added a rebuild pass that recounts
  post-`resetAt` feedback events directly from `impact.jsonl` and
  applies `max(current, rebuilt)` to each reflex's counters. Self-heals
  on every Stop hook run.

- **`hooks/lib/distill_engine.py:407` — confidence decay
  double-counted daily.** `periods = (now - last_seen).days // 30`
  re-yields ≥1 every day after day 30 because `last_seen` never
  advances. An instinct lost 0.05 *every day* instead of 0.05/30d.
  Armed for tomorrow on 4+ live instincts. **Fix:** anchor decay on
  `last_decay_at` (which IS updated on each decay) instead of
  `last_seen`. A decay only fires when 30 days have elapsed *since the
  previous decay*, not since last activity.

- **`hooks/lib/distill_engine.py:LAW_MIN_PROJECTS` — promotion gate
  was unreachable.** `LAW_MIN_PROJECTS=3` combined with how
  `_count_distinct_projects` aggregates evidence made auto-promotion
  to laws structurally impossible for solo-project knowledge. 11
  mature instincts at conf≥0.95 had been queued for weeks with zero
  promotions. **Fix:** lowered to `1`. The other gates
  (LAW_THRESHOLD_CONF=0.95, LAW_SUSTAINED_DAYS=14,
  LAW_MIN_USEFUL_14D=5, LAW_MAX_NOISE_14D=0,
  LAW_JACCARD_THRESHOLD=0.50) preserve quality.

### Fixed (P1)

- **`hooks/lib/distill_engine.py:_log_knowledge` — pipeline-stats
  counters lied.** `_log_knowledge` hardcoded the source field to
  `cx-auto-distill`; `compute_pipeline_stats` keyed accepted events
  on `cx-auto-validate` and evolve-draft events on `cx-auto-evolve`.
  `/cx-status --pipeline` always reported zero auto-pipeline activity
  even when it ran successfully. **Fix:** added a `source` parameter
  with default `cx-auto-distill`; auto-validate and auto-evolve call
  sites now pass the correct source.

- **`hooks/lib/distill_engine.py:_proposal_to_instinct_yaml` — YAML
  injection on apostrophe.** Trigger / action / project_name with
  internal `'` closed the YAML string, breaking the file. Resulting
  instincts were invisible to the runtime parser. **Fix:** new
  `_yaml_single_quote()` helper doubles `'` per YAML 1.2 §7.3.2;
  applied to every regex/free-text field in the template.

- **`hooks/session-learner.js:evalErrorMonitor` — window=1 reflexes
  scanned only the inject's own observation.** `read-large-md-limit`
  and `large-doc-edit-anchor` (both `window: 1`) could only detect
  errors on `obs[currentIdx]` itself; an error on the next call
  was missed and the reflex emitted `useful` instead of `noise`.
  **Fix:** noise slice now covers `[currentIdx, currentIdx+1+window)`
  — window=1 scans 2 cells, window=10 scans 11.

- **`hooks/lib/injector-engine.js` — silent staleness skip.** Mature
  high-confidence instincts that crossed `STALE_DAYS=60` disappeared
  from candidates without any signal. **Fix:** added a `CORTEX_DEBUG`
  stderr log line so dormant instincts are visible in the learner log.

- **`tests/test_impact.sh:Test 22` — assertion outdated by v3.23.7.**
  The test asserted `evalToolSubstitution` returned `ignore` when no
  pivot or reincidence happened; v3.23.7's `aligned-or-ignored`
  semantics correctly returns `useful`. **Fix:** updated assertion;
  added Test 22b for the `ignore` path (empty window).

### Notes

- This is a **forward-only** release: existing instincts/reflexes are
  not mutated by the upgrade. Counter rebuild for resetAt happens
  on the next Stop hook run.
- Domain filter fix is the single biggest win — the operator should
  see ~120 previously-silenced instincts start firing within hours.
- bash-find-use-glob and bash-grep-use-grep-tool will accumulate
  `usefulCount > 0` within 1–2 sessions of normal activity now that
  the v3.23.7 evaluator fix actually runs.

## [3.23.7] — 2026-05-05

### Hotfix — evalToolSubstitution structural bias toward 'ignore'

The `tool-substitution` evaluator in `hooks/session-learner.js` only
emitted `'useful'` on an immediate pivot to `expected_tool` within
`window=3` events after the fire. Real-world audit on fs-cortex (24h
post-v3.23.4) showed:

- `bash-cat-use-read`     : 44 fires, 19 pivots to Read    → 43% ✓
- `bash-find-use-glob`    : 11 fires,  1 pivot  to Glob   → **9%**
- `bash-grep-use-grep-tool`:  4 fires,  0 pivots to Grep   → **0%**

The asymmetry is structural, not accidental: when an agent has just run
`cat foo.py` and got the file content it needed, it does NOT re-execute
the same query with `Read`. Same for `find` and `grep -r`. The warning
was pedagogically useful (the agent learns to start with the right
tool next time), but the evaluator could not detect that utility from
the immediate window. `bash-grep-use-grep-tool` therefore stayed at
`usefulCount=0` for 700+ fires, indistinguishable from "nobody saw it"
even though the impact funnel kept injecting it.

This is the same structural bias that `evalErrorMonitor` had before
v3.19.4 (`condemning the 16/21 reflexes with this evaluator type to a
structural bias toward noise in the impact funnel`).

### Fixed

- **`hooks/session-learner.js:evalToolSubstitution`** — adopted the
  same `aligned-or-ignored` semantics that `evalErrorMonitor` got in
  v3.19.4. New rules:
  1. Pivot to `expected_tool` in window → `useful` (strong signal)
  2. Reincidence with `anti_pattern` in window → `noise` (warning ignored)
  3. No reincidence and the agent kept working (window non-empty) →
     `useful` (the warning either prevented the anti-behavior or was
     absorbed without harm)
  4. Empty window (last event of the session) → `ignore` (cannot judge)

  Reincidence wins over pivot if both happen in the same window —
  the agent partially listened but kept the bug.

### Added

- **`tests/test_session_learner.sh`** — 4 new tests for
  `evalToolSubstitution`: pivot-to-useful, reincidence-to-noise,
  aligned-no-reincidence-to-useful, empty-window-to-ignore. Suite
  count 8 → 12.

### Notes

- This is a forward-only fix: existing `usefulCount` / `noiseCount` on
  reflexes do NOT get recounted. Counters will catch up naturally as
  new fires happen in subsequent sessions.
- Sprint-5 Gate 2: `bash-cat-use-read` already PASSED (5.0× ratio with
  5 useful, 0 noise) under the OLD logic. `bash-find-use-glob` and
  `bash-grep-use-grep-tool` should accumulate `useful` events within
  1–2 sessions of post-v3.23.7 activity.

## [3.23.6] — 2026-05-04

### Documentation — Sprint-5 measurement window timeline

No code changes. Updates the operational documentation to reflect the
real cadence of the operator (Claude Code runs across many projects
in parallel daily), and to anchor the Sprint-5 measurement window on
the v3.23.4 deployment date instead of v3.23.3 (which still left
`bash-cat-use-read` blocked by the runtime guard).

### Changed

- **`docs/SPRINT-5-PENDING-GATES.md`** — measurement-window estimate
  shortened from "by 2026-05-09" (5–7 days) to "by 2026-05-05 /
  2026-05-06" (1–2 days). Header now references both v3.23.4 (guard
  fix) and v3.23.5 (Windows parity) as the basis for the honest
  fresh-data window starting 2026-05-04.
- Cleanup section now points at "post-v3.23.4 data" instead of
  "post-v3.23.3 data" — same logical meaning, but less ambiguous about
  which release actually unlocked the trio.

### Notes

- Code surface unchanged from v3.23.5. `tests/run_all.sh` skipped (no
  hooks, no library, no command, no installer logic touched).
- Bumped version solely to satisfy the pre-push CHANGELOG-discipline
  guard; otherwise this would have been a doc-only commit.

## [3.23.5] — 2026-05-04

### Hotfix — Windows installer parity for evaluator.* propagation

v3.23.3 added evaluator-field propagation to the bash installer
(`install.sh:209-219`) so the matcher fix on `bash-cat-use-read` /
`bash-grep-use-grep-tool` / `bash-find-use-glob` would also update
`evaluator.anti_pattern` on existing user installs. The PowerShell
installer was never patched in lockstep, so Windows users running
`bash install.ps1` after v3.23.3 (or v3.23.4) would receive the new
`condition` but keep the stale `evaluator.anti_pattern` — silent
matcher-evaluator drift, identical to the bug v3.23.3 was supposed to
close.

### Fixed

- **`install.ps1`** — reflex migration now propagates the same nine
  `evaluator.*` sub-fields that `install.sh` does (`type`,
  `anti_pattern`, `expected_tool`, `anti_tool`, `precondition_tool`,
  `match_field`, `lookback`, `window`, `error_pattern`). If the user
  reflex has no `evaluator` object at all, the whole one from the
  default is grafted in via `Add-Member`. Atomic on a per-field basis,
  preserves all runtime data (`fireCount`, `lastFired`, `usefulCount`,
  `noiseCount`, `enabled`).
- **`tests/test_install_ps1.ps1`** — new test 10 asserts that the nine
  evaluator sub-fields and the `PSObject.Properties['evaluator']` guard
  are all present in the source. Catches future regressions where the
  bash and PowerShell migrators drift apart silently.

### Notes

- bash `tests/run_all.sh` remains 16 suites green (no Python or Node
  changes; only Windows-only file edits + a Windows-only test).
- `test_install_ps1.ps1` only runs on `windows-latest` in CI — local
  validation on macOS / Linux is by static grep against `install.ps1`
  source. The CI workflow is unchanged.

## [3.23.4] — 2026-05-04

### Hotfix — third silent bug in the bash-cat-use-read regression

v3.23.3 fixed two regex bugs in three Sprint-5 matchers but only restored
two of them in production. Empirical verification (8 days post-fix, 97
matches in observations) confirmed `bash-cat-use-read` was still dead:
`fireCount` stuck at 696, `lastFired` frozen on 2026-04-26. Two of three
silent failure modes were in the runtime guard, not the regex.

### Root cause — over-aggressive ReDoS guard with false positives

`hooks/lib/injector-engine.js:33-45` and three duplicated copies in
`hooks/session-learner.js` rejected any regex that:

1. Had `length > 100` chars. The v3.23.3 fix legitimately grew the
   `bash-cat-use-read` condition to **136 chars** (compound-command
   prefix + 17 file extensions). Crossing 100 silenced it post-fix.
2. Matched `\([^)]*[+*]\)[+*?]`. The `?` in the outer quantifier was
   wrong — `(...+)?` is **safe** (zero-or-one cannot backtrack
   exponentially). Only `+` and `*` outer quantifiers are catastrophic.
3. (injector only) Had more than 5 `|` alternations. Real-world
   regexes legitimately list 17+ extensions or 6+ tool families.

`bash-cat-use-read` failed all three checks. `bash-find-use-glob` failed
only the pipe check, which silenced its **runtime injection** (the user
never saw the reminder) but not its `fireCount` counter — explaining why
its `usefulCount` was perpetually 0. Three global instincts
(`gotcha-bash-cat-instead-of-read`, `pattern-macos-path-prefix-npm-node`,
`pref-fix-all-lint-test-issues`) had also been silenced by the same
pipe>5 false positive without any operator-visible signal.

### Fixed

- **`hooks/lib/regex-guard.js` (NEW)** + **`hooks/lib/regex_guard.py` (NEW)** —
  single source of truth for the guard, used by injector-engine,
  session-learner, distill_engine and dream_cycle. Constants raised:
  `MAX_LEN` 100 → **200**, `MAX_PIPES` 5 → **25**, `REDOS_DETECTOR`
  `\([^)]*[+*]\)[+*?]` → **`\([^)]*[+*]\)[+*]`** (the `?` removed). The
  live timeout (50ms against `'a' × 100`) is the canonical safety net.
- **`hooks/lib/injector-engine.js`** — eliminated 23 LOC of inline
  `isSafeRegex` / `safeRegexTest`; imports from `./regex-guard`. Each
  call site (`reflex:<id>:matcher`, `reflex:<id>:condition`,
  `instinct:<id>:trigger`) now passes a `tag` so structured rejection
  logs carry the offending id.
- **`hooks/session-learner.js`** — replaced 3 inline copies of the guard
  with the shared module. Refactored the inner reflex-match loop so
  `condRe` is compiled once per reflex (not once per observation) — pure
  speed-up, no semantic change.
- **`hooks/lib/dream_cycle.py`** — `validate_trigger_regex()` now
  delegates to `regex_guard.validate_instinct_trigger()`. Limits stay in
  sync automatically.
- **3 silenced global instincts** unblocked: `gotcha-bash-cat-instead-of-read`,
  `pattern-macos-path-prefix-npm-node`, `pref-fix-all-lint-test-issues`.

### Changed

- **`hooks/lib/distill_engine.py:auto_validate_proposals`** —
  Sprint-7 auto-validate now runs each proposal's `trigger` through the
  guard before writing the YAML. Rejected proposals are persisted with
  `status="held"`, `hold_reason="unsafe-trigger:<reason>"`,
  `held_by="cx-auto-validate"`, `held_at=<today>` so the operator can
  review them via `/cx-validate` rather than them being silently dropped
  on disk and lost. `_save_proposals` now flushes when there are any
  holds (not only accepts).
- **`commands/cx-validate.md`** + **`README.md`** — document the new
  `held` status (informational section, not part of accept/reject
  shorthand).

### Added

- **`tests/test_guard_corpus.sh` (NEW, 9 PASS)** — closes the gap that
  let the v3.23.3 silent regression ship. The corpus passes every
  shipped reflex matcher/condition AND every `~/.claude/cortex/instincts/global/*.yaml`
  trigger through both Node and Python guards, asserts identical reasons
  in both languages, runs an adversarial corpus that must STILL be
  rejected (`(a+)+`, 201 chars, 27 pipes, invalid regex), a safe corpus
  that must STILL be accepted (`(a+)?b`, 200 chars, 25 pipes, the
  Sprint-5 conditions), and a "known gap" assertion for `(a|aa)+` (the
  static detector misses alternation overlap; the live timeout catches
  it dynamically — documented in `regex-guard.js` header).
- **Structured stderr logging on guard rejections**, deduped per
  `(tag, reason, pattern[:64])` to avoid spamming PreToolUse. A future
  silent-silencing event will leave a visible trace.

### Test summary

`bash tests/run_all.sh` → 16 suites, all green. New: `test_guard_corpus`
9/9. Updated: `test_injector` 16 → **18** (added `(a+)?` accepted +
real-world `bash-cat-use-read` accepted). Updated: `test_dream_cycle`
35 → **38** (boundary cases at MAX_LEN/MAX_PIPES + optional capture
accepted).

### Concerns / known gaps

- The static REDOS_DETECTOR does not catch alternation-overlap ReDoS
  like `(a|aa)+`. The live 50ms timeout is the only protection there.
  Tracked for v3.24.0+. Documented in `hooks/lib/regex-guard.js` header
  and verified by `tests/test_guard_corpus.sh` "known gaps" section.
- `Sprint 5` Gate 1+2 measurement window remains valid — 8 days post-
  v3.23.3, two of three reflexes accumulated honest fires. Post-
  v3.23.4, all three will. Estimate to gates: 5–7 more days.

## [3.23.3] — 2026-05-04

### Hotfix — fix 2 silent regex bugs in 3 reflex matchers (Sprint 5 regression)

Triggered by Fer questioning the "0 fires post-`resetAt`" interpretation
that v3.22.2 had used to claim Sprint 5 Gate 2 PASS. Forensic on
`observations.jsonl` revealed 306 real-world Bash commands across
6 days that the matchers should have caught but didn't.

### Root cause — Sprint 5 (v3.20.0) matchers were too aggressive

The "matcher refinement" introduced in Sprint 5 had two regex bugs:

1. **Anchor `^` rejected compound commands.** Real-world Bash usage is
   90%+ compound: `cmd1; cmd2`, `cmd1 && cmd2`, `cmd1 | cmd2`. The `^`
   only matches when the suspect command is at the very beginning of
   the entire Bash input string, missing all compound forms.

2. **`-[a-zA-Z]*[rR]` for grep flags required `r/R` as the LAST letter
   of the flag prefix.** Real-world Bash uses `-rn`, `-rE`, `-RE`,
   `-rni` (where `r/R` is first or middle, not last). The regex
   backtrack failed for all of these.

Effect across 6 days of intensive Bash use:
- 95 `cat/head/tail` on source files → 0 fires
- 133 `grep -r/-R/-rn/-rE` recursive → 0 fires
- 78 `find -name` → 0 fires
- **Total: 306 fires lost**, useful/noise stuck at 0/0

The previous "Gate 2 PASS" conclusion in v3.22.2 was an artifact of the
broken matchers, not real signal.

### Fixed

- **`core/reflexes.default.json`** — three matchers (and their
  `evaluator.anti_pattern` mirrors) updated:

  | Reflex | Old `condition` | New `condition` |
  |---|---|---|
  | `bash-cat-use-read` | `^(cat\|head\|tail)\s+...\.<ext>\b` | `(?:^\|[;&\|]\s*)(cat\|head\|tail)\s+(-[0-9]+\s+)?...\.<ext>\b` |
  | `bash-grep-use-grep-tool` | `^grep\s+(-[a-zA-Z]*[rR])` | `(?:^\|[;&\|]\s*)grep\s+(-[a-zA-Z]*[rR][a-zA-Z]*)` |
  | `bash-find-use-glob` | `^find\s+\S+\s+-name\s+...` | `(?:^\|[;&\|]\s*)find\s+\S+\s+-name\s+...` |

- **Bonus**: extension list of `bash-cat-use-read` extended with
  `jsonl` (JSON Lines, heavily used by Cortex itself for
  `observations.jsonl` and `impact.jsonl`). Optional numeric arg
  `(-[0-9]+\s+)?` accepts `head -50 file.md`, `tail -100 file.json`.

- **User-local `~/.claude/cortex/reflexes.json`** patched in-place
  during the install.sh run that ships this release. The fix is
  forward-looking: existing 0/0 counters from v3.20.0+ stay at 0/0
  (those events never registered); new fires from 2026-05-02 onward
  populate cleanly.

### Added

- **`tests/test_reflex_matchers.sh`** — 28 tests covering:
  - Compound commands with `;` / `&&` / `|`
  - `r/R` flag positions: `-r`, `-R`, `-rn`, `-rE`, `-nR`, `-rni`
  - Numeric args: `head -50 file.md`, `tail -100 file.json`
  - Edge cases: `find ... -delete`, `find ... -exec` (excluded),
    `cat /etc/hosts` (no recognized extension), etc.
  - Real-world examples from `observations.jsonl` (the cases the old
    matchers missed)

  All 28 PASS post-fix.

### Changed

- **`docs/SPRINT-5-PENDING-GATES.md`** — rewritten:
  - **Gate 2 reopened**. v3.22.2's "Gate 2 PASS" was based on
    `noiseCount < 3`, but with 0 fires that was trivially met for the
    wrong reason. New Gate 2 criterion: `enabled: true AND
    fireCount post-resetAt ≥ 30 AND usefulCount/max(noiseCount,1) ≥ 2.0`.
  - **Gate 1 still pending**, but the reason is now "fresh
    measurement window starts 2026-05-02 with fixed matcher" instead
    of "wait for fresh post-resetAt evidence" (the old framing
    assumed the matcher worked).
  - Estimate: enough data on both gates by 2026-05-09 (~7 days of
    fresh fires).
- **`CLAUDE.md`** — Pending validation block updated to reflect both
  gates reopened.

### Cleanup (side action)

Archived duplicate instinct `pattern-sandbox-installer-test-mktemp`
(added by `/cx-validate` earlier today) — Jaccard 0.36 with the
pre-existing `pattern-sandbox-installer-test`. Same concept,
duplicated. Source-of-truth retained on the older one.

### Tests at release

| Suite | Result |
|---|---|
| `test_reflex_matchers.sh` | **28/28 PASS** (new) |
| `test_security.sh` | 7/7 PASS |
| `test_dream_cycle.sh` | 35/35 PASS |
| `test_distill_engine.sh` | 27/27 PASS |
| `test_impact.sh` | 64/64 PASS |
| `test_yaml_normalize.sh` | 12/12 PASS |
| `test_yaml_utils.sh` | 13/13 PASS |

**Total: 186/186 PASS** (was 158 in v3.23.2 + 28 new).

### Migration from v3.23.2

Run `bash install.sh`. Existing user-local `reflexes.json` matchers
will be patched in-place by this release's installer. No data loss —
the existing 0/0 useful/noise counters stay (those events never
registered with the broken matcher); new fires from now on populate
correctly.

## [3.23.2] — 2026-05-01

### Restore zero-deps invariant — drop PyYAML from `yaml_normalize.py`

`hooks/lib/yaml_normalize.py` had imported `yaml` (PyYAML) since it was
introduced. PyYAML is the only third-party Python dependency the project
ever pulled in, and `install.sh` / `install.ps1` deliberately do not run
`pip install` — the project advertises **zero deps**. On any machine
without PyYAML pre-installed, the SessionStart normalization pass raised
`ModuleNotFoundError: No module named 'yaml'` (silently swallowed by the
`try/except` in `hooks/session-start.py:259`, but real and visible from
the SessionStart stderr stream).

This release restores the invariant.

### Changed

- **`hooks/lib/yaml_normalize.py`**: removed `import yaml`. Both PyYAML
  call sites replaced with a stdlib regex helper `_has_broken_dq_line(text)`:
  - **Pre-check** in `normalize_all()` (was `yaml.safe_load_all` line 113):
    skip files whose content has no `<key>: "<value with bad escape>"`
    line on any `REGEX_KEYS` field. Same skip logic as before, narrower
    in scope but identical for files this module was ever expected to
    touch.
  - **Post-rewrite safety** in `normalize_file()` (was `yaml.safe_load_all`
    line 82): refuse to persist if the rewritten content still has a
    broken double-quoted REGEX_KEYS line. After `_convert_line()` runs
    on every line this should never happen — kept as a sanity guard.
- The pre-compiled regex `_DQ_LINE_RE` is shared between `_convert_line()`
  and `_has_broken_dq_line()`.

### Added

- **`tests/test_yaml_normalize.sh`** (12 tests, all PASS):
  1. Module imports without PyYAML (we block `sys.modules['yaml'] = None`
     before the import to prove independence).
  2. `_has_broken_dq_line` detects `\.` and `\s` inside double quotes on
     `trigger`/`action`/`condition`/`matcher` keys.
  3. Ignores valid escapes (`\n`, `\t`).
  4. Ignores bad escapes on non-REGEX keys (`evidence`, `id`, etc.).
  5. `normalize_file()` rewrites bad → single-quoted.
  6. Idempotent: returns False on already-clean files, file unchanged
     on disk (sha verified).
  7. `normalize_all()` on a sandbox CORTEX_DIR: skips clean, fixes
     broken in both global and project subdirs.
  8. Skips `archive/` subdirectories.
  9. Missing CORTEX_DIR returns 0 cleanly.

### Cross-platform verification

`install.sh` (macOS / Linux) and `install.ps1` (Windows) **already**
respect zero-deps and do not run `pip install` anywhere — verified by
grep before this release. With the PyYAML import gone, fresh installs
on any platform with Python 3.6+ (stdlib only) will not hit the
`ModuleNotFoundError`.

### Tests at release

| Suite | Result |
|---|---|
| `test_yaml_normalize.sh` | **12/12 PASS** (new) |
| `test_security.sh` | 7/7 PASS |
| `test_dream_cycle.sh` | 35/35 PASS |
| `test_distill_engine.sh` | 27/27 PASS |
| `test_impact.sh` | 64/64 PASS |
| `test_yaml_utils.sh` | 13/13 PASS |

**Total: 158/158 PASS**, no regressions.

### Migration from v3.23.1

No user action required. `bash install.sh` syncs the new module. After
install, `python3 -c "import sys; sys.path.insert(0,'$HOME/.claude/hooks/cortex/lib'); from yaml_normalize import normalize_all; print(normalize_all())"`
runs cleanly and returns the count of repaired files (0 on a healthy
install).

## [3.23.1] — 2026-05-01

### `/cx-status --pipeline` — pipeline activity dashboard

Triggered by Fer asking "debería tener datos o un informe que poder
consultar". Sprint 7 (v3.23.0) writes pipeline activity across 5
dispersed sources — knowledge-log.md, proposals.json,
auto-distill-candidates.md, evolved/skills/, and last-run markers.
The new `--pipeline` flag aggregates them in a single read.

### Added

- **`compute_pipeline_stats(days=14)`** in `hooks/lib/distill_engine.py`
  (+276 LOC, 1252 → 1528). Pure function returning a dict with 5
  sections: `validate`, `promote`, `evolve`, `decay`, `last_runs`. All
  counts derived from existing data sources; no new state introduced.

- **`pipeline-stats` CLI subcommand** in `distill_engine.py` mirroring
  the `--impact` / `--reflexes` pattern:
  ```
  python3 hooks/lib/distill_engine.py pipeline-stats [--days N] [--json]
  ```

- **`/cx-status --pipeline` flag** in `commands/cx-status.md`. ASCII
  output sections:
  - **VALIDATE**: auto-accepted (cx-auto-validate), manual accepted/
    rejected (cx-validate), pending by domain with whitelist tag.
  - **PROMOTE**: auto-promoted (cx-auto-distill), manual promoted
    (cx-distill), candidates queued, active laws / cap.
  - **EVOLVE**: auto drafts (cx-auto-evolve), manual evolved
    (cx-evolve), drafts pending install, manual artifacts.
  - **MAINTENANCE**: decayed instincts, archived instincts.
  - **LAST RUNS**: marker mtimes for auto-distill / analyze /
    manual-distill / audit / eod.

- **4 new tests 24-27** in `tests/test_distill_engine.sh`:
  zero-state (empty CORTEX_DIR), source counters, pending-by-domain,
  evolve-drafts (cluster vs manual). 23 → **27/27 PASS**.

### Changed

- **`commands/cx-router.md`**: `/cx-status` row extended with the new
  `flags: --impact, --reflexes, --pipeline` line.
- **`docs/FEATURES.md`**: commands table `/cx-status` row mentions
  `--pipeline (v3.23.1)`.

### Bug fix as side-effect

Sprint 7 (v3.23.0) was pushed to GitHub but never installed locally on
Fer's machine. His `~/.claude/hooks/cortex/lib/distill_engine.py` was
still running v3.22.x code (0 occurrences of `auto_validate_proposals`,
MD5 mismatch with repo). The `bash install.sh` run during this release
synced it (now MD5 matches, 8 occurrences). Forced `run_auto_distill()`
confirmed:

```
{ "validated": 0, "skipped_validate": 33,
  "promoted": 0, "candidates": 12,
  "evolve_drafts": 0 }
```

Correct behavior — all 33 pending proposals are `workflow` /
`user-preference`, outside the auto-accept whitelist
(`gotcha`/`pattern`/`error-recovery`/`agent-evolution`). The system is
healthy; pending need human `/cx-validate` because their domain
explicitly requires judgment.

### Tests at release

| Suite | Result |
|---|---|
| `test_distill_engine.sh` | **27/27 PASS** (was 23/23 in v3.23.0) |
| `test_security.sh` | 7/7 PASS |
| `test_dream_cycle.sh` | 35/35 PASS |
| `test_impact.sh` | 64/64 PASS |

### Migration from v3.23.0

No code migration required. Run `bash install.sh` to sync the new flag
into your local `~/.claude/hooks/cortex/lib/`.

Use `/cx-status --pipeline` (or
`python3 ~/.claude/hooks/cortex/lib/distill_engine.py pipeline-stats`)
to see what auto-validate / auto-distill / auto-evolve have done in
the last 14 days, and what's queued for human review.

## [3.23.0] — 2026-04-30

### Sprint 7 · Pipeline automation

Closes the **two manual gates** that remained in the knowledge pipeline
after Sprint 6: `/cx-validate` (proposal → instinct) and `/cx-evolve`
(instinct → skill). The full pipeline is now self-driving end to end:

```
Observations → Proposals → Instincts → Laws / Skills
(automatic)   (auto-detect) (auto v3.23) (auto v3.22 / auto v3.23 drafts)
```

### Added

- **`auto_validate_proposals(dry_run)`** in `hooks/lib/distill_engine.py`.
  Auto-accepts proposals matching the whitelist:
  - `confidence ≥ 0.50`
  - `domain in {gotcha, pattern, error-recovery, agent-evolution}`
  - No existing instinct with same id
  
  Action: generates instinct YAML, updates `proposals.json` status,
  appends to knowledge-log under source `cx-auto-validate`. All atomic.
  
  Proposals with `domain in {correction, user-preference, decision,
  workflow}` stay pending — they need human judgment via manual
  `/cx-validate`.

- **`auto_evolve_detect(dry_run)`** in `hooks/lib/distill_engine.py`.
  Clusters mature instincts (`confidence ≥ 0.70`) by domain using
  pairwise Jaccard similarity (≥ 0.50 over `trigger + action` tokens,
  BFS connected components). For any cluster of 3+ instincts not
  already covered by an existing `~/.claude/skills/<id>/SKILL.md`,
  generates a draft at `~/.claude/cortex/evolved/skills/<cluster-id>.draft.md`.
  
  Cluster-id format: `cluster-<domain>-<sha1[:8]>` — stable across runs
  but rebuilds when the instinct set changes. The user reviews the
  draft and installs (`cp` to `~/.claude/skills/<id>/SKILL.md`) or
  discards (`rm`).

- **`tests/test_distill_engine.sh`** extended 15 → 23 tests:
  - 16: auto-validate accepts gotcha at conf 0.60
  - 17: auto-validate rejects correction (needs human judgment)
  - 18: auto-validate rejects low-confidence
  - 19: auto-validate idempotent (skips existing instinct)
  - 20: evolve detects cluster of 3 with Jaccard ≥ 0.50
  - 21: evolve rejects cluster of 2 (need ≥ 3)
  - 22: evolve rejects low-Jaccard cluster (similarity < 0.50)
  - 23: evolve skips when skill already exists

### Changed

- **`run_auto_distill()` pipeline order**: decay → archive →
  **auto-validate** → auto-promote-to-law → **auto-evolve**. Freshly
  validated instincts are eligible for promotion in the same 24h window.
  Updated summary shape:
  
  ```python
  {
    "decayed": int, "archived": int,             # existing
    "validated": int, "skipped_validate": int,   # NEW
    "promoted": int, "candidates": int,          # existing
    "evolve_drafts": int,                        # NEW
    "skipped_reason": str | None,
    "ran_at": iso8601,
  }
  ```

- **`hooks/session-start.py` step 3d**: replaced the 1-line summary
  with a multi-line `[CORTEX KNOWLEDGE PIPELINE]` block that shows ONLY
  non-zero lines. Example output:
  
  ```
  [CORTEX KNOWLEDGE PIPELINE]
    ✓ Validated: 4 proposals → instincts
    ✓ Promoted: 1 instinct → laws
    ✓ Evolve drafts: 1 skill at evolved/skills/
    ⚠ Pending review: 2 proposals need judgment — run /cx-validate
  ```

- **`commands/cx-validate.md`**: added "Auto mode (Sprint 7+)" section
  explaining that the manual command is now only needed for proposals
  requiring human judgment.

- **`commands/cx-evolve.md`**: added "Auto mode (Sprint 7+)" section
  explaining that drafts are auto-generated; the manual command remains
  for reviewing and installing them.

### Tests at release

| Suite | Result |
|---|---|
| `test_distill_engine.sh` | **23/23 PASS** (was 15/15 in v3.22.0) |
| `test_security.sh` | 7/7 PASS |
| `test_dream_cycle.sh` | 35/35 PASS |
| `test_impact.sh` | 64/64 PASS (unchanged from v3.22.1) |

### Migration from v3.22.x

No migration required. The engine creates its own state; new functions
are additive. On the first SessionStart after install:

- All `pending` proposals matching the whitelist will be auto-accepted
  (cap respected — only those not already in `instincts/`)
- Any cluster of 3+ mature instincts in the same domain will get a
  draft at `~/.claude/cortex/evolved/skills/`
- The new `[CORTEX KNOWLEDGE PIPELINE]` block will surface the first
  time anything moves through the pipeline

An opt-out env flag is **not** implemented in v3.23.0. If you want to
suppress auto-validate or auto-evolve, the cleanest path is to delete
the relevant function calls from `run_auto_distill()`. File an issue
if a proper flag would be useful.

## [3.22.2] — 2026-04-30

### Cleanup pass + Sprint 5 gates partial closure

Triggered by Fer's instinct that `noise_events: 1` post-v3.22.1 looked
too clean after several days of intensive work. Three parallel
sub-agents (haiku for the comparative report, 2× sonnet for forensics
and sprint inventory) confirmed the pipeline is healthy AND surfaced
accumulated cruft to clean.

### Findings (forense subagent)

- The `noise_events: 1` reading is **real, not broken pipeline**. 105
  of 106 historical noise events come from the three bash-* reflexes
  pre-`resetAt: 2026-04-26` and are correctly excluded by v3.22.1's
  reset-aware aggregation. The single survivor is a manual rating on
  `read-before-edit`. The current `impact.jsonl` only has ~5 days of
  fresh post-reset history — most of the file fits inside the 14-day
  window, so ratios are artifact-inflated.
- Verdict: re-measure `--impact` ratios from mid-May 2026 once 30+
  days of fresh data accumulate.

### Changed

- **`docs/SPRINT-5-PENDING-GATES.md`** rewritten with status updates:
  - **Gate 2 — three reactivated NOISY reflexes stay enabled**:
    ✅ **PASS** (closed). All three (`bash-cat-use-read`,
    `bash-grep-use-grep-tool`, `bash-find-use-glob`) remain
    `enabled: true` with `noiseCount: 0` after 5+ days of fresh data.
  - **Gate 3 — inject/session ≥ 40% lower than pre-Sprint-5**:
    ❌ **DROPPED**. The pre-v3.20.0 baseline is not reconstructible
    from the current `impact.jsonl` (earliest event is 2026-04-25).
    The intent — "Sprint 5 reduces noise injection" — is already
    covered by the aggregate `useful_ratio: 0.90` and `noise_ratio:
    0.0003` reported by `/cx-status --impact`. Specific ratio gate
    not needed.
  - **Gate 1 — `bash-grep-use-grep-tool` ratio ≥ 3×**: ⏳ PENDING
    until mid-May 2026. v3.22.1 made it honest by excluding
    pre-`resetAt` events; current post-reset window (5d) is too small.
    Pass criterion clarified: `useful / noise ≥ 3.0` AND
    `useful + noise ≥ 50`.

### Cleanup recommendations (NOT shipped — local-only changes)

This release does not modify any code or installed runtime. It
documents the audit conclusions and provides per-user migration
guidance:

#### Niche laws → skills (free 4 law slots)

The following 4 laws in `~/.claude/cortex/laws/` are project-specific
(NOT universal) and should live in skills, where they auto-load by
trigger only when the relevant stack is in use. Currently they burn
~135 tokens per session in projects that don't use that stack:

- `playwright-selector-priority.txt` → covered by skill `fs-e2e`
- `supabase-rls-verify.txt` → covered by skill `fs-supabase-gotchas`
- `three-layer-security.txt` → covered by skill `fs-supabase-gotchas`
- `touch-visible-buttons.txt` → covered by skill `fs-web-design`

Per-user archive:

```bash
cd ~/.claude/cortex/laws && mkdir -p archive
mv playwright-selector-priority.txt supabase-rls-verify.txt \
   three-layer-security.txt touch-visible-buttons.txt archive/
```

Active law count after archive: 11 → 7 universal-only. Plenty of
slots for organic growth.

#### Cap drift in manual `/cx-distill`

The auto-promote engine (`distill_engine.py auto_promote_to_law`)
correctly enforces `LAW_MAX_ACTIVE = 10` (line 626). The 11-active-laws
state happened because manual `/cx-distill` does not enforce the cap
when adding laws — its spec recommends "evaluate replacement vs new"
but the user can approve a candidate without performing the
replacement. Future tightening: enforce cap in the manual command too.

#### Dead reflex cleanup

Per-user audit candidates with sustained low utility:

| Reflex | Fires | Useful | Action |
|---|---|---|---|
| `html-twin-deliverables` | 35 | 0 | Delete (no signal in 6+ months) |
| `git-tag-after-amend` | 39 | 1 | Lower severity high → low (informational) |
| `docker-cross-network` | 682 | 3 | Lower severity medium → low (overgenerous matcher) |

Per-user pruning is reversible (the `core/reflexes.default.json` ships
the canonical set; user-local additions are purely opt-in).

### Tests

- `test_security.sh` 7/7 PASS (unchanged)
- `test_dream_cycle.sh` 35/35 PASS (unchanged)
- `test_impact.sh` 64/64 PASS (unchanged from v3.22.1)
- `test_distill_engine.sh` 15/15 PASS (unchanged)

No new tests — this release ships only docs.

### Migration from v3.22.1

No upgrade action required. Run the optional cleanup snippets above
if you want to apply the audit recommendations to your local config.

## [3.22.1] — 2026-04-27

### Fixed

- **Reset-aware impact stats** — `/cx-status --impact` was reporting a
  misleading `1.13×` useful/noise ratio for `bash-grep-use-grep-tool`
  (Sprint 5 Gate 1) because it aggregated events from BOTH eras of the
  matcher: pre-v3.20.0 (when the matcher was wider and produced 62 noise
  events) AND post-v3.20.0 (refined matcher, 0 fires in 50 h). The
  refined matcher inherited the old data, so the gate never read clean.

  New behavior: each reflex may carry an optional `resetAt` ISO-8601
  timestamp. `hooks/lib/impact_log.py` now reads `reflexes.json` once
  per `compute_metrics()` call via the new `_load_reflex_resets()`
  helper, and `_iter_events()` discards any `reflex:X` event whose
  `ts < resetAt[X]`. Other callers (`rotate()`, outcome-ranking,
  outcome-nudge) leave the boundary disabled by passing
  `reflex_resets=None`. Default behavior unchanged when no reflex has a
  `resetAt`. Schema bump `core/reflexes.default.json` 2.2.0 → 2.3.0
  (the field is optional, backward compatible — the shipped template
  does not declare any reset boundary).

  `hooks/session-learner.js` `correlateReflexFeedback` now auto-heals
  user-local `~/.claude/cortex/reflexes.json` runtimes: at the next
  Stop event, the three v3.20.0-reset reflexes (`bash-cat-use-read`,
  `bash-grep-use-grep-tool`, `bash-find-use-glob`) get their `resetAt`
  backfilled to `2026-04-26T13:31:57+02:00` (the v3.20.0 commit
  timestamp) — but only when they match the known-reset shape
  (`fireCount > 0 AND usefulCount === 0 AND noiseCount === 0`). The
  heal is idempotent: subsequent runs skip reflexes that already have
  a `resetAt`. New future-proof contract: code paths that reset reflex
  counters must ALSO set `resetAt` at the time of reset (otherwise
  `--impact` will keep aggregating pre-reset events).

  This unblocks `docs/SPRINT-5-PENDING-GATES.md` Gate 1: the
  `bash-grep-use-grep-tool` ratio will now reflect post-reset data
  only, not the polluted blend of pre- and post-refinement evidence.

- **`tests/test_impact.sh` 31-33 time-fragility** — these tests
  hardcoded the fixture timestamp `2026-04-26T10:00:00Z` with
  `--days 1`, so the window expired the moment the wall clock passed
  24 h after that date. CI went red on the v3.21.2 and v3.22.0
  releases purely because the date moved on. Fixed by computing
  `NOW_TS=$(python3 -c ...utcnow().strftime(...))` once before
  Test 31 and using `'$NOW_TS'` everywhere inside the fixture
  python heredocs (Tests 31, 32, 33, 34). Closes the "Known issues"
  block declared in v3.22.0.

### Added

- **`hooks/lib/impact_log.py`** — `_load_reflex_resets()` and
  `_is_pre_reset()` helpers, plus a new optional `reflex_resets`
  parameter on `_iter_events()`.
- **3 new tests in `tests/test_impact.sh`** (46-48):
  - Test 46: `compute_metrics` excludes pre-`resetAt` events for
    the configured reflex.
  - Test 47: `_load_reflex_resets()` returns `{}` when
    `reflexes.json` is missing.
  - Test 48: `resetAt` on one reflex does not affect events of
    other reflexes (no cross-contamination).

### Tests at release

| Suite | Result |
|---|---|
| `test_impact.sh` | **64/64 PASS** (was 58/61 with 3 fragility) |
| `test_security.sh` | 7/7 PASS |
| `test_dream_cycle.sh` | 35/35 PASS |
| `test_distill_engine.sh` | 15/15 PASS |

### Migration

No user action required. The auto-heal in `session-learner.js` runs at
the next Stop hook and backfills `resetAt` on the three known-reset
reflexes if (and only if) the local runtime matches the post-reset
shape. Users whose `reflexes.json` already has those three reflexes
with non-zero `usefulCount`/`noiseCount` are skipped — the heal only
applies to runtimes that genuinely had counters reset by v3.20.0.

## [3.22.0] — 2026-04-27

### Sprint 6 · Auto-distill engine

Closes the manual-loop gap left over from the original v4.0 plan: the
deterministic parts of `/cx-distill` (decay, archive, instinct → law
promotion) now run automatically at SessionStart, gated to once per 24h.
The judgment-heavy parts (project → global Jaccard promotion, law
replacement when 10/10 active, instinct merging, borderline universality
calls) stay manual under `/cx-distill` — unchanged behaviour.

### Added

- **`hooks/lib/distill_engine.py`** (827 LOC, pure stdlib) — the engine.
  Public API: `run_auto_distill()`, `apply_decay()`, `archive_decayed()`,
  `auto_promote_to_law()`. CLI:
  - `python3 distill_engine.py auto [--dry-run]` — full auto pass.
  - `python3 distill_engine.py decay [--dry-run]` — decay only.
  - `python3 distill_engine.py promote [--dry-run]` — promotion check only.
  - `python3 distill_engine.py status` — show current candidates.

  Concurrency safety via `fcntl.flock` on `.distill-engine.lock` (POSIX);
  silent no-op on Windows. Atomic writes via `os.replace`. Honors
  `CORTEX_DIR` env var for sandbox testing.

- **Auto-promote-to-law gate** — STRICT: an instinct only graduates
  automatically when ALL of:
  1. `confidence ≥ 0.95`
  2. Sustained ≥ 14 days at that confidence (new YAML field
     `at_law_threshold_since` tracks the first crossing; gets removed
     when the instinct drops below 0.95).
  3. Seen in ≥ 3 distinct projects (union of `project_id` field,
     `projects_seen[]` array, and filesystem locations).
  4. ≥ 5 useful events in last 14 days from `impact.jsonl`.
  5. 0 noise events in last 14 days.
  6. No existing law overlaps content (Jaccard < 0.50 of trigger+action
     tokens vs every active law file).
  7. Active law count < 10.

  Instincts at conf ≥ 0.95 that fail any of (2)-(7) get written as a
  1-line summary to `~/.claude/cortex/auto-distill-candidates.md` so
  the user can review them with `/cx-distill`.

- **`hooks/session-start.py`** — new step 3d invokes
  `run_auto_distill()`, prints a 1-line summary if anything changed
  (`[CORTEX] auto-distill: N decayed, N archived, N promoted, N candidates`).
  Errors are silently swallowed — auto-distill must never block a session.

- **`tests/test_distill_engine.sh`** (651 LOC, 15 tests, all PASS) —
  decay basic / stacking / fresh-noop, archive on low conf, threshold
  tracking field set/cleared, the 7 promotion-gate failure modes,
  promotion happy path, idempotency, rate-limit marker, parallel-lock.

- **Knowledge log entries** — every auto action appends one line to
  `~/.claude/cortex/knowledge-log.md` under source `cx-auto-distill`
  (vs `cx-distill` for manual runs). Format unchanged:
  `YYYY-MM-DD | <event> | <id> | <detail> | cx-auto-distill`.

### Changed

- **`hooks/session-start.py` `check_maintenance()`** — the legacy
  weekly `[MAINT] Run /cx-distill` nag now ONLY fires when
  `~/.claude/cortex/auto-distill-candidates.md` is non-empty. Users
  whose system has nothing pending no longer see the reminder.
- **`docs/FEATURES.md`** — header version, last-updated date, version
  history row for v3.22.0.
- **`docs/FEATURES-visual.html`** — footer bumped to v3.22.0.

### Known issues — deferred to v3.22.1

- `tests/test_impact.sh` tests 31-33 hardcode the timestamp
  `2026-04-26T10:00:00Z` with `stats --days 1`. The window expires when
  the wall clock advances past 24h after the fixture date, so these
  tests turn red on day-2 even with no code changes. Pre-existing
  fragility (not introduced by this release). Other tests in the same
  file using the same timestamp pass because they assert the
  empty/no-op state which coincides with the post-expiration result.
  Fix in v3.22.1: switch to dynamic `date -u`-derived timestamps.

### Tests at release

| Suite | Result |
|---|---|
| `test_distill_engine.sh` | **15/15 PASS** (new) |
| `test_security.sh` | 7/7 PASS |
| `test_dream_cycle.sh` | 35/35 PASS |
| `test_impact.sh` | 58/61 PASS (3 pre-existing time-fragility, see Known issues) |

### Migration

No migration required for users. The engine creates its own state files
on first run. Existing `~/.claude/cortex/` data is read but never
mutated outside the standard YAML/log/marker channels documented above.

The new YAML field `at_law_threshold_since` is added lazily by the
engine on the first auto-distill run that observes an instinct at
conf ≥ 0.95 — older YAMLs without it are interpreted as
"threshold-crossing happened today", so they need 14 more days before
becoming eligible for auto-promotion. Run `/cx-distill` manually if
you want to bypass the wait for an instinct that has been stable for
months already.

## [3.21.2] — 2026-04-27

### Cleanup — remove two reflexes whose matcher design never fired

`core/reflexes.default.json` shipped two reflexes since the early days
that targeted user-prompt patterns (`/cx-downvote`, `wrong instinct`,
`from now on`, `always use`, …) via the `Bash`/`Edit`/`Write` matcher.
Reflexes match against tool **input**, not against the user's chat
message — so the condition strings never appeared in tool input and
neither reflex ever fired:

- `instinct-downvote` — 0 fires across 14 days vs 2314 inject events.
- `capture-decision` — 0 fires across 14 days.

Both removed from `core/reflexes.default.json`. The default reflex
count drops from 13 to **11**.

### Diagnosis of three user-local reflexes (informational)

`/cx-status --reflexes` flagged three other reflexes worth tracking but
they live in user-local `~/.claude/cortex/reflexes.json`, not in the
shipped default, so this release does **not** modify them:

- `git-tag-after-amend` (severity `high`, 24 fires / 1 useful) — the
  matcher fires on every `git tag -a vX.Y.Z`, including normal release
  tags where no `--amend` is coming. Consider lowering severity to
  `medium` or narrowing the condition.
- `tavily-rate-limit` (0 fires / 3 useful events in `impact.jsonl`) —
  matcher `tavily` should still substring-match MCP-prefixed tool names;
  worth verifying the regex pipeline.
- `python3-bypass-write-tool` (0 fires) — kept; rare safety net for
  Read-first bypass via `python3 -c "...write_text..."`.

### Added

- `docs/SPRINT-5-PENDING-GATES.md` — tracks the three measurement gates
  from Sprint 5 that need fresh production data to validate:
  - Gate 1: `bash-grep-use-grep-tool` useful/noise ratio ≥ 3× (currently
    1.13× — fails).
  - Gate 2: the three reactivated NOISY reflexes stay enabled (currently
    pass).
  - Gate 3: 7-day rolling inject/session ≥ 40% lower than pre-Sprint-5
    baseline (unmeasured — needs reconstruction from history).
- `CLAUDE.md` — new "Pending validation" section that references
  `docs/SPRINT-5-PENDING-GATES.md` so the gates surface at SessionStart
  until they all pass and the file is deleted.

### Changed

- `README.md` — reflex count 10 → **11** in the parallel-systems
  paragraph, and 13 → **11** in the `~/.claude/cortex/` tree comment.
- `docs/FEATURES.md` — header version, last-updated date, reflex count
  (`Reflexes (11 default)`), and version-history row for v3.21.2.
- `docs/FEATURES-visual.html` — footer bumped to v3.21.2.

### Tests

- No new tests. The change is data-only: removing two JSON entries from
  a config file. `core/reflexes.default.json` is consumed by
  `install.sh` Step 6 (`cp -n reflexes.default.json reflexes.json`), so
  fresh installs will get 11 reflexes; existing installs are not
  touched and keep whatever the user has tuned locally.

### Migration

- Existing users with the two removed reflexes still in their
  `~/.claude/cortex/reflexes.json` can prune them safely:
  ```bash
  python3 -c "
  import json, pathlib
  p = pathlib.Path.home() / '.claude/cortex/reflexes.json'
  data = json.loads(p.read_text())
  reflexes = data.get('reflexes', data)
  if isinstance(reflexes, list):
      reflexes[:] = [r for r in reflexes if r.get('id') not in
                     ('instinct-downvote', 'capture-decision')]
  elif isinstance(reflexes, dict):
      for rid in ('instinct-downvote', 'capture-decision'):
          reflexes.pop(rid, None)
  p.write_text(json.dumps(data, indent=2))
  print('pruned')
  "
  ```
  Skipping this leaves them in place but harmless — they are
  `enabled: true` with 0 fire history, so they cost nothing.

## [3.21.1] — 2026-04-27

### Hotfix — `install.sh` aborted at Step 8b when invoked outside the repo

Latent regression introduced in v3.0.1 (2026-04-09) when the git pre-push
hook installation step was added. The line:

```bash
GIT_HOOKS_DIR=$(git -C "$SCRIPT_DIR" rev-parse --git-dir 2>/dev/null)/hooks
```

returns the **relative** path `.git` when the repo is not a worktree,
which is then concatenated to `/hooks` and passed to `cp`. The shell
resolves the resulting `.git/hooks/pre-push` against the **user's
working directory**, not against `SCRIPT_DIR`. Users who invoked the
installer with an absolute path (`bash /Users/me/github/fs-cortex/install.sh`)
from any directory other than the repo root saw:

```
cp: .git/hooks/pre-push: No such file or directory
```

`set -e` then aborted the script before Steps 10–14, leaving the
installation half-finished:

- Steps 5–8a (cortex/, memory.json, reflexes.json, skill, commands,
  hooks, lib modules) — completed normally.
- Step 8b (git pre-push hook) — **failed**.
- Step 10 (settings.json hooks merge) — skipped.
- Step 11 (CLAUDE.md Cortex section) — skipped.
- Step 14 (`~/.claude/cortex/version` marker) — skipped, so the file
  reported the previous version.

The runtime impact was small: the hooks Cortex needs were already in
place (Step 8a copies them) and `settings.json` from earlier installs
already pointed to `~/.claude/hooks/cortex/`. The user-visible damage
was a stale version marker and a confusing error.

### Fixed

- **`install.sh` Step 8b** — switched to
  `git rev-parse --absolute-git-dir` and added an extra
  `[ -d "$GIT_HOOKS_DIR" ]` guard so the cp only runs against an
  existing target directory. The block now silently skips on:
  - `SCRIPT_DIR` not in a git repo (e.g. user installed from a
    tarball)
  - Sibling worktrees with no `hooks/` directory
  - Anyone running the installer from outside the repo

### Unaffected

- **`install.ps1`** — does not install a git pre-push hook, so the
  same family of bugs cannot occur on Windows.

### Tests

- No code-path test was exercising Step 8b before this release
  (`test_install.sh` runs the installer in a sandbox where `SCRIPT_DIR`
  always equals `cwd`, masking the relative-path bug). This release
  does not add a regression test for it — the fix is a one-character
  flag change to a shell command, and the canonical way to test it
  would require running `install.sh` from a non-repo `cwd`, which
  conflicts with the test sandbox layout. Marked as a known
  test-coverage gap; will be addressed when `test_install.sh` gets
  its next overhaul.

### Recovery

If you hit the original bug, the fix re-runs cleanly:

```bash
bash /Users/<you>/github/fs-cortex/install.sh
```

The Y/N prompt confirms the v3.21.0 → v3.21.1 upgrade. Step 14 will
write `~/.claude/cortex/version = 3.21.1`, repairing the stale
marker that v3.21.0 left behind.

## [3.21.0] — 2026-04-27

### Cohort-based outcome nudging — the definitive fix

v3.20.2 closed the visible saturation symptom (`gotcha-agent-spawn-preflight`
racing `0.77 → 0.99` in five Stop hooks on identical evidence) by gating
on `outcome_total > prev_seen`. An internal Six-Hat review + independent
sub-agent audit on 2026-04-27 confirmed that this was a pragmatic
mitigation, not a definitive fix — four latent defects remained:

1. **Aggregate-ratio drift** — the 14-day window could stay >0.85 even
   when the recent cohort was 80% errors, so a degrading instinct kept
   gaining `+0.05` boosts.
2. **Archive decrement** — `rotate()` archives outcome events >30 days
   old, so `outcome_total` could fall below `prev_seen` and skip
   silently, blocking legitimate decay.
3. **Race condition** in parallel Stop hooks — two sessions reading the
   same `nudge-state.json` could both apply `+0.05`, last-writer-wins.
4. **No clawback** — confidence saturated by historic boosts could not
   be recovered when subsequent data turned sour.

v3.21.0 closes all four by reframing the apply path around the
**marginal cohort**: only outcomes with `ts > last_event_ts` count. The
ratio answers "did the evidence that arrived since the last decision
point up or down?" instead of "what does the rolling 14-day average
say?".

### Added

- **`hooks/lib/impact_log.py:compute_outcome_decisions(state)`** — new
  helper that returns the cohort-based decision per iid:
  `{cohort_total, cohort_clean, cohort_error, ratio, nudge, max_ts}`.
  Only counts outcomes strictly later than `state.iids[iid].last_event_ts`.
  The window-aggregate `compute_outcome_ranking()` is kept as-is for
  human-facing `/cx-status outcome-ranking` display.
- **`_nudge_lock_acquire()` / `_nudge_lock_release()`** — advisory
  exclusive lock on `~/.claude/cortex/nudge-state.json.lock` via
  `fcntl.flock` (POSIX). Falls back to no-op on platforms without
  `fcntl`; the race window is the subprocess runtime (<500 ms in
  practice) and YAML rewrites remain individually atomic via
  `tmp + replace`.

### Changed

- **`apply_outcome_nudges()` reframed** — the function now wraps the
  whole `load → decide → apply → save` sequence in the advisory lock,
  computes decisions cohort-based via `compute_outcome_decisions`,
  and advances `state.iids[iid].last_event_ts` to the cohort `max_ts`
  on every apply (or on saturated boundary detection). Legacy callers
  passing a v3.20.x rankings dict are accepted but the dict is
  ignored — decisions are always recomputed from cohort state.
- **`nudge-state.json` schema bump v1 → v2.** New canonical shape:
  ```json
  {"version": 2, "iids": {"<iid>": {
    "last_event_ts": "<ISO-8601 of last consumed outcome>",
    "last_nudge_ts": "<ISO-8601 of this apply>",
    "last_direction": "+0.05" | "-0.05" | "saturated",
    "conf_at_last_nudge": <float>
  }}}
  ```
  v1 state is discarded on first load. The YAML confidences that v1
  already applied are preserved (they live in the YAMLs, not in
  `nudge-state.json`); the only memory lost is "have I already nudged
  this exact `outcome_total`?", which is replaced by the stricter
  ts-based gate. The first v3.21.0 run after the migration may emit
  one extra nudge per iid as the cohort filter sees all current
  outcomes as "new"; this is by design and self-corrects on the
  next Stop hook.
- **`docs/OUTCOME-RANKING.md` safeguard #7 rewritten** to describe
  cohort-based gating and enumerate the four bugs it closes.

### Tests

- `test_impact.sh` adds **Tests 42–45** (4 new pass cases):
  - 42: marginal cohort decays when recent evidence sours (drift fix —
    phase 1 +0.05 on clean cohort, phase 2 −0.05 on sour cohort even
    though aggregate ratio over both phases is 0.467 / middling)
  - 43: 3 parallel `outcome-nudge --apply` processes serialize via
    flock — net effect is exactly one `+0.05` on the YAML, not three
  - 44: post-archive cohort still triggers decay (`outcome_total`
    decrement is irrelevant; ts-based gate stays open)
  - 45: v1 `nudge-state.json` migrates cleanly to v2 (load returns
    canonical v2 shape, no crash)
- Tests 38–41 (v3.20.2 idempotency) remain valid; Test 39 fixture
  updated to use a strictly-later timestamp for the second cohort
  (the v3.21.0 gate is `ts >` strict, not just `count >`).
- Suite: **61/61 PASS** (impact, was 56). Full repo holds
  **253 tests / 13 suites**.

### Operator note

Existing instincts whose YAML confidence was inflated by the
v3.20.0/.1 saturation bug are NOT auto-reverted by this release.
The v3.20.2 procedure (edit YAML manually + delete `nudge-state.json`)
is still the rollback path. After v3.21.0 is installed, the cohort
gate prevents a recurrence even if the YAML still holds inflated
values.

## [3.20.2] — 2026-04-26

### Hotfix — `apply_outcome_nudges` was double-counting evidence

Real-data inspection via `/cx-status --impact` after v3.20.1 surfaced
that `gotcha-agent-spawn-preflight` had been nudged five times in a
single day, racing from `confidence: 0.7700` to `0.9900` (the
`NUDGE_MAX_CONF` clamp) on **identical evidence** — 14 outcome events
that had not changed between Stop hooks. The Sprint 5 doc had promised
"confidence cannot move >3 points per hour" but the implementation
re-applied the same `+0.05` boost on every Stop because there was no
memory of prior applications.

The clamp at `0.99` prevented further damage but the rate-of-change
contract was violated, and any instinct with positive outcomes was on
the same trajectory.

### Fixed

- **`hooks/lib/impact_log.py:apply_outcome_nudges`** — gate every
  apply on `now_seen > prev_seen` per iid. State is persisted to
  `~/.claude/cortex/nudge-state.json` (`{version, last_seen: {iid:
  {outcome_total, last_nudge_ts}}}`) with atomic `tmp + replace`.
- **Saturated-iid handling** — when an iid is already at the
  `NUDGE_MAX_CONF` (or `MIN_CONF`) clamp boundary, the function records
  state but emits no apply entry, so subsequent re-runs stay no-op
  instead of re-evaluating clamp arithmetic on every Stop hook.

### Added

- **`hooks/lib/impact_log.py`** — new helpers `_load_nudge_state()` and
  `_save_nudge_state()`; new constant `NUDGE_STATE_FILE`.
- **`docs/OUTCOME-RANKING.md`** — safeguard #7 (idempotency) added
  with the v3.20.0/.1 saturation symptom documented as the motivating
  bug. New "Reset" section explains how to wipe `nudge-state.json` if
  it becomes inconsistent (manual confidence rewrites, recovery from
  this very bug, etc.).

### Tests

- `test_impact.sh` adds **Tests 38–41** (8 new pass cases):
  - 38: first apply nudges; second apply on same data is a no-op
  - 39: gate re-opens when new outcomes accumulate; confidence advances
  - 40: `nudge-state.json` shape (`outcome_total`, `last_nudge_ts`)
  - 41: saturated iid (already at clamp) emits no apply entry across
    re-runs
- Suite: **56/56 PASS** (impact, was 48), full repo **248/248 PASS**.

### Operator note

Existing instincts whose YAML confidence was already inflated by the
v3.20.0/.1 bug will NOT be reverted automatically by this hotfix. To
roll a specific instinct back to its pre-bug confidence, edit the YAML
frontmatter directly. To re-baseline the nudge memory after such an
edit, delete `~/.claude/cortex/nudge-state.json` — the next Stop hook
will recreate it from the current `impact.jsonl`.

## [3.20.1] — 2026-04-26

### Public-repo hygiene after v3.20.0 — CI gaps + README + SECURITY

A read-through of the public-facing surface uncovered three drift items
that v3.20.0 left behind: the CI workflow had four bash suites that were
present in `tests/` but never executed (a 87-test gap), the README still
documented "10 default reflexes" after v3.20.0 added 3, and SECURITY.md
listed only 8 suites with stale counts.

### Fixed

- **`.github/workflows/test.yml`** — added `test_impact.sh` (48),
  `test_migrate_legacy_iid.sh` (12), `test_integrity.sh` (14), and
  `test_uninstall.sh` (13) to the `test` job. Until this patch these
  four suites only ran via the `tests/run_all.sh` summary step, which
  is `tail -10` cosmetic — failures inside them did not fail the job.
  Now each is a separate step on the `ubuntu-latest`/`macos-latest`
  matrix and a regression in any of them turns CI red.

### Changed

- **`README.md`** —
  - Reflex count `10 default` → `13 default` in two places (data tree
    + reflexes section heading).
  - Reflex table extended with the three Sprint 5 tool-substitution
    reflexes (`bash-cat-use-read`, `bash-grep-use-grep-tool`,
    `bash-find-use-glob`) and the refined matcher patterns.
  - `session-learner.js` hook row now lists "outcome auto-ranking
    (v3.20.0+)" so the public arch diagram reflects Step 5e.
  - `~/.claude/cortex/` directory tree now shows `impact.jsonl` line.
- **`SECURITY.md`** —
  - "Security Measures (v3.6)" heading depinned from v3.6; baseline
    measures listed as preserved-and-extended in every release.
  - New Sprint 5 (v3.20.0) safeguards section: bounded nudges, reflex
    immunity, subprocess timeout, sample-size floor.
  - Test suite count corrected from "124 tests, 8 suites" to the
    actual **240 tests, 13 suites**, with the full breakdown grouped
    by safety / learning / installer.
  - Added one-line CI matrix description so vulnerability researchers
    know which platforms and runtimes are exercised.

### Tests

- No code paths touched. The four newly-CI-wired suites already pass
  locally (impact 48, migrate 12, integrity 14, uninstall 13).

## [3.20.0] — 2026-04-26

### Sprint 5 — Autonomy + intelligence

The impact funnel has been collecting `outcome` events with
`error_within_10` since v3.19.4 but never closed the loop on instinct
confidence. Sprint 5 wires that signal directly into the YAML
frontmatter at every Stop hook, refines the three auto-disabled
tool-substitution reflexes with narrower matchers, and audits the
NEVER-FIRED reflexes (all kept — matchers were correct, the corpus
just doesn't touch their domains).

### Added

- **`hooks/lib/impact_log.py`** —
  - `compute_outcome_ranking(days=14, min_outcomes=5)` returns per-iid
    `outcome_clean_ratio` and a confidence nudge in `{-0.05, 0, +0.05}`.
    Bands: ratio `>=0.85` boost, `<=0.30` decay, otherwise hold.
  - `apply_outcome_nudges(rankings, dry_run=False)` walks every
    instinct YAML and rewrites `confidence:` in the frontmatter. Reflex
    iids (`reflex:*`) are skipped — they have their own runtime
    accounting. Atomic `tmp + replace`. Clamped to `[0.10, 0.99]`.
  - `log_nudges_to_knowledge(applied)` appends one pipe-delimited line
    per applied nudge to `~/.claude/cortex/knowledge-log.md`.
  - Two new CLI subcommands: `outcome-ranking` (read-only) and
    `outcome-nudge` (defaults to dry-run, `--apply` to persist).
- **`hooks/session-learner.js` Step 5e** — spawns
  `python3 impact_log.py outcome-nudge --apply --json` after the reflex
  feedback step at every Stop hook. 5s subprocess timeout; failures
  are logged but never block the rest of the Stop pipeline.
- **`core/reflexes.default.json`** — three new reflexes
  (`bash-cat-use-read`, `bash-grep-use-grep-tool`, `bash-find-use-glob`)
  with refined matchers. They had existed only in user runtime files
  prior; new installs now get them with the v3.20.0 matchers from day
  one.
- **`docs/OUTCOME-RANKING.md`** — full architectural decision record
  including algorithm contract, safeguards (min sample size, bounded
  delta, hard clamp, reflex immunity, conservative middle band), Stop
  hook integration, failure modes, and CLI surface.

### Changed

- **`hooks/lib/impact_log.py` imports** — added `import re` for the
  YAML frontmatter regex used by `apply_outcome_nudges`.
- **Refined tool-substitution matchers** (Sprint 5 task 2c):
  - `bash-cat-use-read`: now fires only when cat/head/tail reads a
    source file by extension (py, js, ts, tsx, md, json, yaml, sh,
    html, css, toml, sql, env, etc.). Excludes pipes, heredocs, log
    tails, and operational concat.
  - `bash-grep-use-grep-tool`: now fires only on recursive grep
    (`grep -r/-R` flag present). Drops `-n` and `-l` which are common
    in legitimate pipe usage.
  - `bash-find-use-glob`: now fires only on plain `-name` searches
    without `-exec`/`-delete`/`-newer`/`-mtime`/`-print0`/`-prune`,
    since Glob can't replace those find features.
- **3 reflexes reactivated** in runtime `~/.claude/cortex/reflexes.json`
  with `usefulCount=0` / `noiseCount=0` after matcher refinement
  (Sprint 5 task 2d). The pre-refinement counters were accumulated
  under broken correlator logic (pre-v3.19.3) and over-broad matchers,
  so a clean slate is more honest than reusing them.

### Tests

- `test_impact.sh` adds **Tests 31–37** (8 new):
  - 31: clean ratio → `+0.05` nudge
  - 32: dirty ratio → `-0.05` nudge
  - 33: middling ratio → `0` nudge
  - 34: iids below `min_outcomes` excluded
  - 35: `apply_outcome_nudges` skips `reflex:*` iids
  - 36: nudge persisted to YAML + clamped to `[0.10, 0.99]`
  - 37: `knowledge-log.md` gets one line per applied nudge
- Suite: **48/48 PASS** (impact, was 40), **9/9** (observe),
  **8/8** (learner), **7/7** (security), **35/35** (dream),
  **12/12** (migrate).

### Audit (no code change)

- **9 NEVER-FIRED reflexes reviewed** (`git-merge-verify`,
  `security-headers`, `html-twin-deliverables`,
  `python3-bypass-write-tool`, `instinct-downvote`, `capture-decision`,
  `tavily-rate-limit`, `docker-cross-network`, `git-tag-after-amend`).
  All matchers are correct and domain-specific — the never-fired
  signal reflects which domains the user touched in the window, not a
  matcher problem. No changes were made. Documented in
  `docs/OUTCOME-RANKING.md`.

## [3.19.6] — 2026-04-26

### Cosmetic — visual explainer footer was three releases behind

`docs/FEATURES-visual.html` is the public visual explainer for the project
and the only HTML deliverable that mirrors the version. The footer was
last bumped to `v3.19.2` and then silently skipped by three consecutive
release cycles (v3.19.3, v3.19.4, v3.19.5), so anyone opening the live
explainer saw a stale version label even though the underlying code was
current. The omission is now explicitly called out in the release
checklist via `.claude/rules/release-workflow.md`.

### Fixed

- **`docs/FEATURES-visual.html`** — footer line `fs-cortex v3.19.2 &middot;
  Open source (MIT)` updated to `v3.19.6`. No content, layout, or asset
  change otherwise.

### Tests

- No code paths touched. Pre-push hook (`tests/test_security.sh` 7/7,
  `tests/test_dream_cycle.sh` 35/35) re-run as part of the release
  guardrails.

## [3.19.5] — 2026-04-26

### Data hygiene + docs sync after the v3.19.4 outcome/agent-feedback unblock

The v3.19.4 fix normalized new feedback events on write but left stale
legacy events in `~/.claude/cortex/impact.jsonl` untouched, so
`/cx-status --impact` still showed split phantom rows for any reflex that
had received feedback before v3.19.4. Two docs (`AUTO-EVALUATION.md`,
`IMPACT-METRICS.md`) also lagged the new evaluator semantics and the
fact that `outcome` events are no longer "Reserved for Sprint 5".

### Added

- **`scripts/migrate-legacy-reflex-iid.py`** — one-shot, idempotent
  migration that rewrites historical `iid: reflex-<id>` (hyphen) events
  to the canonical `reflex:<id>` (colon) form. Whitelisted against
  `reflexes.json` so unknown ids are passed through unchanged. Atomic
  rewrite (tmp + rename), backs up to `impact.jsonl.pre-v3.19.5.bak`
  on first run, no-op on subsequent runs. Supports `--apply` (default
  is dry-run), `--stats`, `--quiet`. Production run on
  `~/.claude/cortex/impact.jsonl` rewrote 5 events across 3 reflex ids
  (`reflex-bash-cat-use-read` ×2, `reflex-read-before-edit` ×2,
  `reflex-bash-find-use-glob` ×1), restoring single-row aggregation in
  TOP USEFUL / TOP NOISY rankings.
- **`tests/test_migrate_legacy_iid.sh`** — 12-test suite covering
  dry-run safety, apply correctness, backup creation, payload
  preservation, idempotency, missing-file handling, missing-whitelist
  safety, and `--stats` output. Sandbox-isolated via `CORTEX_DIR`.

### Changed

- **`docs/AUTO-EVALUATION.md` Type C semantics** — rewrote the
  `error-monitor` description to match the v3.19.4 `evalErrorMonitor`
  contract: `useful` when follow-up observations exist AND no matching
  error fires; `noise` when matching error fires; `ignore` only when
  there is no follow-up evidence. Pre-v3.19.4 the doc still claimed
  "useful if no error within next 10 events AND the reminded action
  visible in observations", which never matched the implementation.
- **`docs/IMPACT-METRICS.md` `outcome` event** — removed "Reserved for
  Sprint 5" placeholder. Documented the v3.19.4 emission path
  (`session-learner.js` writes one outcome event per inject alongside
  the follow event, carrying `error_within_10`) and forward-references
  Sprint 5 outcome auto-ranking. Field table updated to describe
  `error_within_10` as actually emitted, not "(future)".

### Known issues (deferred to Sprint 5)

- **`fireCount` under-count** observed for several reflexes in
  `reflexes.json` (e.g. `react-hydration-guard` at `fireCount: 1` /
  `usefulCount: 2`; `test-after-change` at `fireCount: 15` /
  `usefulCount: 32` against 52 inject events in `impact.jsonl`).
  `fireCount` is incremented only inside `session-learner.js`'s
  reflex correlator (line 669), so any inject whose sid was rejected
  by the correlator filter (the v3.19.3 sid-truncation bug) never
  bumped `fireCount` even though the reflex actually fired.
  `usefulCount` is correct from v3.19.3 forward; the historical
  `fireCount` gap will be reconciled by a Sprint 5
  `--reconcile-counters` extension to this migration script.

### Tests

- `test_migrate_legacy_iid.sh` — **12/12 PASS** (new suite).
- Suite (unchanged): **40/40** (impact), **9/9** (observe),
  **8/8** (learner), **7/7** (security), **35/35** (dream).

## [3.19.4] — 2026-04-26

### Three independent bugs left over after the v3.19.3 sid fix

The Sprint 0 impact funnel was reporting a clean GO at 29.5% useful_ratio,
but three subtle defects were polluting the dashboard and hiding agent
signal. Detected via real-data inspection of `/cx-status --impact`.

### Fixed

- **`hooks/lib/impact_log.py`** — new `_normalize_iid()` auto-corrects
  `reflex-<id>` (hyphen) to `reflex:<id>` (colon) in `log_feedback`.
  Pre-fix, ad-hoc invocations of `/cx-feedback-auto` and stray manual
  events were splitting the dashboard into two phantom rows per reflex
  (`reflex:bash-cat-use-read` vs `reflex-bash-cat-use-read`) so
  top-useful / top-noise rankings did not aggregate. Stderr warning
  emitted on every rewrite for visibility.
- **`commands/cx-feedback-auto.md`** — Step 1 rewritten to strip and
  normalize `<id>` against reflexes/instincts and explicitly add the
  `reflex:` prefix when the bare id matches a reflex. Step 3 now
  references the normalized id.
- **`hooks/session-learner.js` — outcome events implemented.** Pre-fix,
  the schema accepted `outcome` events but no code path emitted them, so
  `/cx-status --impact` always reported `outcome: 0`. Now
  `correlateImpactEvents` writes one outcome event per inject alongside
  the follow event, carrying `error_within_10` for the same 10-event
  window already used for follow.
- **`hooks/session-learner.js` — `evalErrorMonitor` no longer
  structurally biased to noise.** Pre-fix the function only emitted
  `noise` (when matching error fired in window) or `ignore` (any other
  case), which condemned 16 of 21 reflexes with this evaluator type to
  agent → useful: 0.0000. New semantics: if the inject was followed by
  any observation in the window AND no matching error fired, the
  reflex is `useful` (the reminder either prevented the error or was
  redundant-but-aligned). An empty follow-up window still emits
  `ignore` — we keep the conservative bias when there is no evidence.

### Tests

- `test_impact.sh` Test 19a — `_normalize_iid` rewrites hyphen to colon
- `test_impact.sh` Test 26 — `error-monitor` `ignore` when no follow-up
- `test_impact.sh` Test 26b — `error-monitor` `useful` when follow-up + clean
- Suite: **40/40 PASS** (impact), **9/9** (observe), **8/8** (learner),
  **7/7** (security), **35/35** (dream).

## [3.19.3] — 2026-04-26

### Critical bug — auto-evaluation pipeline silently broken since v3.18.0

`hooks/observe.py` truncated `session_id` to 24 chars (`[:24]`) before
writing observations. Claude Code session IDs are 36-char UUIDs, so every
observation carried the prefix while `impact.jsonl` (written by the
injector) carried the full UUID. Inside `session-learner.js`,
`correlateReflexFeedback` and `correlateImpactEvents` filter inject
events with `candidateSids.has(ev.sid)` — the prefix vs full-UUID
mismatch meant **0/24 reflexes ever updated `usefulCount` or
`noiseCount`**, the `feedback` event stream stayed empty, and the v3.19.0
`CORTEX_AGENT_DISABLE_REFLEXES` auto-disable threshold could not fire.
v3.18.0/v3.19.0/v3.19.1/v3.19.2 had been running in this broken state.

### Fixed

- **`hooks/observe.py`** — raise `session_id` cap from `[:24]` to `[:64]`
  so 36-char UUIDs round-trip intact. Truncation rationale was sandboxing
  hostile input; 64 keeps that intent and accommodates UUIDs with margin.
- **`hooks/session-learner.js`** — extract `buildCandidateSids(...)` and
  `sidMatches(eventSid, candidateSids)` helpers. Both correlators
  (`correlateImpactEvents`, `correlateReflexFeedback`) now match the full
  UUID, the truncated 24-char prefix, or both. This recovers feedback
  for observations stored under the legacy truncated form and continues
  to work after the observe.py fix.
- **`tests/test_observe.sh`** — replace `session_id[:24]` assertion with
  `session_id[:64]` plus a new "UUID round-trips at 36 chars" check.

### Verification

```
=== Observer Tests ===           9 passed, 0 failed
=== Session Learner Tests ===    8 passed, 0 failed
=== Impact Funnel Tests ===     38 passed, 0 failed
=== Security Regression Tests ===7 passed, 0 failed
=== Dream Cycle Tests ===       35 passed, 0 failed
```

Dry-run on real data: with the legacy truncated observations and the new
correlator, **566/1011 inject events match retroactively** (vs 0 before).
After this release, fresh observations carry full UUIDs and matching
will be 1:1.

## [3.19.2] — 2026-04-26

### Cleanup release — finishes the v3.19.1 hotfix coverage and surfaces auto-eval data

v3.19.1 fixed `correlateImpactEvents` and `correlateReflexFeedback` in
`session-learner.js` so the auto-eval pipeline finally emits feedback
events. v3.19.2 propagates the same `CORTEX_DIR` env-var support to the
remaining hooks/libs that hardcoded `~/.claude/cortex`, surfaces the
new `usefulCount` / `noiseCount` / health classification in the HTML
dashboard, and brings the docs (README, SKILL, claudemd-section,
AUTO-EVALUATION, IMPACT-METRICS) up to date with the current state.

### Changed

- **`hooks/observe.py`, `hooks/session-start.py`, `hooks/precompact.py`** —
  `CORTEX_DIR` now honors `os.environ.get("CORTEX_DIR")` (matches
  `session-learner.js`, `impact_log.{py,js}`).
- **`hooks/injector.sh`, `hooks/injector.js`, `hooks/lib/injector-engine.js`,
  `hooks/lib/dashboard_gen.py`, `hooks/lib/yaml_normalize.py`** — same
  env-var honor across the lib layer. `injector-engine.js` now accepts
  either `_CX_CORTEX_DIR` (legacy, set by injector.sh) or `CORTEX_DIR`.
- **`hooks/lib/dashboard_gen.py`** — reflex table renders 3 new columns:
  `Useful`, `Noise`, `Health`. Health is computed per-reflex via the
  v3.18.0 spec rules (`healthy`/`borderline`/`NOISY`/`unknown`/`no-data`).
  Summary row shows aggregate counts per health bucket.
- **`README.md`** — `Commands (17)` → `(20)`, `Hooks (4, …)` → `(5, …)`,
  test counts `161` → `211`, token-budget total `~1,750` → `~2,400`,
  added impact-funnel row.
- **`skills/cortex/SKILL.md`** — header bumped from `v3.10` → `v3.19.2`,
  description lists all 20 commands (was 16).
- **`core/claudemd-section.md`** — added `/cx-feedback-auto`.
- **`docs/AUTO-EVALUATION.md`** — header now warns that v3.18.0 → v3.19.0
  were silently broken (links to v3.19.1 hotfix in CHANGELOG).
- **`docs/IMPACT-METRICS.md`** — `(13 tests)` → `(38 tests)`.

### Why

The auditor pass on v3.19.1 (8 parallel Opus agents) flagged that the
fix was correct but had not been propagated across siblings — Python
hooks and several lib modules still hardcoded `~/.claude/cortex`,
making sandbox testing inconsistent and breaking any non-default
install. The dashboard, the user-visible surface for the v3.18.0
auto-eval feature, never showed the very counters it was tracking.

### Not changed

- No new commands, no new hooks, no schema changes. SemVer-patch.
- `install.ps1` git pre-push hook gap (auditor 3) — backlog for v3.20.x.
- Project registry duplicate-hash entries (auditor 7) — user-data, requires `/cx-` cleanup tooling, backlog.

## [3.19.1] — 2026-04-26

### Reflex auto-evaluation fix — was silently broken since v3.18.0

v3.18.0 shipped the reflex auto-rating pipeline (Stop event →
`session-learner.js` → `correlateReflexFeedback` → `usefulCount` /
`noiseCount` → auto-disable). In practice it never emitted a single
`feedback` event with `source:agent`, so v3.19.0's auto-disable
mechanism could never fire either.

Three compounding bugs in `hooks/session-learner.js`:

1. **Hardcoded path on line 23**: `CORTEX_DIR` did not honor the
   `CORTEX_DIR` env var (only `HOME`-derived). Made the function
   untestable against a sandbox and inconsistent with `impact_log.js`.
2. **Wrong field name in fallback (line ~1213)**: `observations[0]._sid`
   should be `observations[0].sid` (no underscore — `observe.py` writes
   the field without it). When `stdinData.session_id` was missing, the
   correlator received `null` and short-circuited.
3. **Orphan harness sid filter (lines 949 + 1078)**: when Claude Code
   emits a Stop with a session_id from a transient subagent /
   slash-command runner that recorded no observations, the correlator
   discarded all reflex injects from the *real* sessions whose
   observations had been loaded by the fallback "last 200 lines" path.

### Fixed

- **`hooks/session-learner.js:23`** — `CORTEX_DIR` now honors
  `process.env.CORTEX_DIR` (matches `impact_log.js` line 17).
- **`hooks/session-learner.js`** — both `correlateImpactEvents` and
  `correlateReflexFeedback` now accept either a single sid (legacy)
  or any iterable of candidate sids, AND union with `o.sid` from the
  loaded observations to rescue orphan-harness-sid runs. The emitted
  `follow` / `feedback` event now uses `inj.sid` (the real session
  that fired the reflex), not the harness sid passed in.
- **`hooks/session-learner.js`** — call sites at the auto-rating step
  use `observations[0].sid` (no underscore typo).

### Added

- **`tests/test_impact.sh`** — Test 29 covers the orphan-harness-sid
  rescue: seeds an inject with `sid:'real-session'`, calls the
  correlator with `'orphan-sid'` as the param, and asserts the
  feedback event is emitted with `sid:'real-session'`, `rating:useful`,
  `usefulCount` incremented to 1.

### Impact

Fresh installs (or reinstalls) will see `usefulCount` and `noiseCount`
populate as the agent self-rates injections at each Stop. After enough
data accumulates per reflex (`fireCount >= 10` AND `noiseCount >= 3`),
the v3.19.0 auto-disable mechanism kicks in and silently disables noisy
reflexes — the round trip the project was designed for since v3.18.0.

## [3.19.0] — 2026-04-25

### Auto-disable activation — installer-managed default

v3.18.0 shipped the auto-disable mechanism but kept it opt-in via
`CORTEX_AGENT_DISABLE_REFLEXES=1`. Users were expected to add it to
their shell rc file. **This is a known gotcha**: macOS and Windows
GUI apps (including Claude Code Desktop) do not source `~/.zshrc` /
`~/.bashrc`, so the variable was missing in GUI sessions and the
auto-disable never fired in practice.

v3.19.0 closes the gap. The installer writes the variable into
`~/.claude/settings.json`'s `env` block, which the harness injects
into every hook subprocess regardless of how Claude Code was
launched (Terminal / Desktop / IDE / Linux DE).

### Added

- **`install.sh`** · step 10 now sets
  `settings.env.CORTEX_AGENT_DISABLE_REFLEXES = "1"` if absent.
  Idempotent — re-running install does not duplicate or overwrite.
- **`install.ps1`** · same on Windows. Same Python merge logic.
- **`uninstall.sh`** · removes only the Cortex-managed env key. User-
  defined entries are preserved. If the `env` block becomes empty,
  the key is dropped entirely to keep settings.json clean.
- **`docs/AUTO-EVALUATION.md`** · new "Activation" section explains
  why `settings.json` `env` is the right place (vs. `.zshrc`),
  documents how to opt out, covers co-existence with shell rc files.

### Changed

- **Default behavior**: fresh installs of v3.19.0+ have auto-disable
  active out of the box. Existing v3.17.x / v3.18.x installs are
  unaffected until the user runs `bash install.sh` (the upgrade
  path).

### How to opt out

Edit `~/.claude/settings.json` and delete the
`env.CORTEX_AGENT_DISABLE_REFLEXES` key, or set it to `"0"` / `""`.
See `docs/AUTO-EVALUATION.md` "Activation".

### Smoke tests added

- Fresh install: env var present, user vars preserved
- Existing settings: env merged without touching user's other env vars
- Idempotency: second install does not duplicate or overwrite
- Uninstall preserves: only Cortex var removed, user env intact
- Empty env cleanup: empty `env` block dropped on uninstall

## [3.18.0] — 2026-04-25

### Sprint 1 · Auto-evaluation — close the agent feedback loop

v3.17.0 added `source: agent` to feedback events but agent-initiated
feedback was manual via `/cx-feedback-auto`. v3.18.0 closes the loop:
the injector emits inject events for every reflex fire, and
`session-learner.js` evaluates them at Stop, emitting `feedback`
events with `source: agent` automatically. This populates the
`useful_ratio_agent` ratio organically and feeds the (still opt-in)
auto-disable threshold introduced in v3.17.0.

Full design rationale in
[`docs/AUTO-EVALUATION.md`](docs/AUTO-EVALUATION.md).

### Added

- **`docs/AUTO-EVALUATION.md`** · architectural decision record. Defines
  the three evaluator types (`tool-substitution`, `precondition-check`,
  `error-monitor`), the `iid: reflex:*` convention, the Stop-time
  evaluation flow, and the privacy guarantees.
- **`hooks/lib/injector-engine.js:407`** · new step 3e emits
  `ev: inject` events for matched reflexes with `iid` prefixed
  `reflex:`. Same shape as instinct inject events (tool, pid, sid).
- **`hooks/session-learner.js:correlateReflexFeedback`** · new function
  reads reflex inject events for the current sid, runs each reflex's
  evaluator against observations.jsonl, emits `ev: feedback` events
  with `source: agent` and `inject_ts` for dedup. Updates
  `usefulCount` / `noiseCount` on the reflex entry.
- **`hooks/session-learner.js`** · three evaluator implementations:
  `evalToolSubstitution`, `evalPreconditionCheck`, `evalErrorMonitor`.
  Plus the dispatcher `evaluateReflex`. Conservative semantics —
  absence of error never claims `useful` for `error-monitor` reflexes.
- **`core/reflexes.default.json:v2.2.0`** · added `evaluator` field to
  8 of 10 default reflexes. The two meta-reflexes
  (`instinct-downvote`, `capture-decision`) remain unrated by design.
  Also seeded `usefulCount: 0` / `noiseCount: 0` on every reflex.
- **`commands/cx-status.md:--reflexes`** · new flag surfaces a per-reflex
  health table with status `healthy` / `borderline` / `NOISY` / `unknown`
  computed from `fireCount`, `usefulCount`, `noiseCount`.
- **`tests/test_impact.sh`** · 9 new tests (20-28) cover the three
  evaluators, the no-evaluator default, and the `reflex:` iid prefix.
  Total: 32 passing assertions.

### Changed

- **`reflexes.json` schema** · gains optional `evaluator`,
  `usefulCount`, `noiseCount` fields. Pre-v3.18 files are read with
  defaults — no migration script required.

### Privacy

- Reflex inject events log the same minimal payload as instinct inject
  events: `iid` (predefined, public), `tool` name, `pid`, `sid`.
  Bash command text, file paths, and tool inputs are NOT logged.
  Same guarantees as `IMPACT-METRICS.md`.

### Stability

- Schema `v:1` unchanged. The `iid: reflex:*` prefix is now a public
  convention; evaluator types are frozen for v:1 — adding new types
  does not require a schema bump as long as each returns
  `useful` | `noise` | `ignore`.
- Auto-disable still gated behind `CORTEX_AGENT_DISABLE_REFLEXES=1`.
  v3.18 ships the **mechanism** for organic noise accumulation; the
  decision to flip the default to "on" is deferred to v3.19+ after
  one cycle of validation on real data.

## [3.17.1] — 2026-04-25

### Fixed

- **Doc paths in 4 spec files** · `commands/cx-feedback.md`,
  `commands/cx-feedback-auto.md`, `commands/cx-status.md`,
  `docs/IMPACT-METRICS.md` referenced the impact_log.py writer at the
  doubled-`cortex/` path `~/.claude/cortex/hooks/cortex/lib/impact_log.py`.
  The actual install path is `~/.claude/hooks/cortex/lib/impact_log.py`.
  Pre-existing inconsistency since v3.14.0 — fixed in 5 occurrences.
  No runtime change; the agent always discovered the correct path
  via shell, but the spec was misleading.
- **`tests/test_install.sh`** · expected command count was hardcoded
  to 19 from v3.14.0. v3.17.0 added `cx-feedback-auto.md` (20th .md
  file) without updating the test, breaking CI on every matrix combo
  (macOS/Ubuntu × Python 3.11/3.13 × Node 22/24) with `FAIL: commands:
  20 (expected 19)`. Bumped to 20.

## [3.17.0] — 2026-04-25

### Sprint 0 · Instrumentation, follow-up — split user vs agent feedback

The Sprint 0 funnel (v3.14.0) introduced `/cx-feedback` with a single
positive channel for human feedback. A follow-up audit (this release)
showed that ~60% of injected items are tool-choice reflexes the user
cannot meaningfully evaluate (e.g. `bash-find-use-glob`,
`read-before-edit`). Forcing the user to rate them either inflates
`useful_ratio` (false positives) or leaves the bucket empty (signal
loss). Either way, the Sprint 0.5 Go/No-Go Gate stops measuring
human value. v3.17.0 fixes this by splitting feedback by `source`
(`user` vs `agent`) so the gate keeps measuring what it was designed
to measure. Full design rationale in
[`docs/AGENT-FEEDBACK.md`](docs/AGENT-FEEDBACK.md).

### Added

- **`docs/AGENT-FEEDBACK.md`** · architectural decision record. Defines
  the `source` field, the user/agent split, the new gate input, and the
  reflex auto-disable heuristic gated behind `CORTEX_AGENT_DISABLE_REFLEXES=1`.
- **`commands/cx-feedback-auto.md`** · new command, agent-only. Emits
  feedback events with `source: agent`. Applies confidence nudges to
  neither instincts nor reflexes (agent self-rating must not bootstrap
  confidence — that is reserved for human feedback or distillation).
  Tracks `noiseCount` on reflexes for future opt-in auto-disable.
- **`hooks/lib/impact_log.py:49`** · `VALID_SOURCES = {"user", "agent"}`
  and `DEFAULT_SOURCE = "user"`. New `--source` CLI argument on
  `log` subcommand. `log_feedback()` accepts `source` kwarg.
- **`hooks/lib/impact_log.py:compute_metrics`** · returns six new keys
  (`useful_ratio_user`, `noise_ratio_user`, `health_ratio_user`,
  `useful_ratio_agent`, `noise_ratio_agent`, `health_ratio_agent`)
  alongside the legacy aggregates (`useful_ratio`, etc.) for backward
  compatibility with v3.14.x–v3.16.x readers.
- **`tests/test_impact.sh`** · 6 new tests (14–19) cover source field
  persistence, legacy-event default, split ratios, gate input,
  invalid source rejection. Total now: 19 tests / 23 assertions, all green.

### Changed

- **`hooks/lib/impact_log.py:gate_recommendation`** · now reads
  `useful_ratio_user` and `health_ratio_user`. The gate decision no
  longer mixes agent and user signal. Backward compatible: falls back
  to legacy keys when split keys are absent.
- **`commands/cx-feedback.md`** · spec updated. Always writes
  `source: user`. Accepts reflex ids explicitly with a warning, but no
  confidence nudge (reflexes have no confidence).
- **`hooks/lib/impact_log.py:_print_stats`** · `/cx-status --impact`
  now prints two extra lines showing user vs agent ratios separately,
  and labels the gate as "uses _user ratios only".

### Schema

- Schema stays at `v:1`. The new `source` field is optional with
  default `"user"` on read. Pre-v3.17.0 events parse unchanged. No
  migration script needed.

### Documentation

- `docs/IMPACT-METRICS.md` retains its formulas; `docs/AGENT-FEEDBACK.md`
  layers the source split on top and is the new reference for any
  consumer that needs the user/agent breakdown.

## [3.16.0] — 2026-04-25

### Sprint 1.X · session-learner threshold tuning

Closes the last open item from the Sprint 1 plan (`docs/IMPACT-RETROSPECTIVE-2026-04-25.html` action #3): the session-learner was producing
51 duplicate `repeat-*` and `workflow-*` proposals over the past 12 days
(same patterns rejected by `cx-validate` again and again). Empirical
sweet-spot threshold raised so normal exploration no longer trips the
detectors.

### Changed

- **`hooks/session-learner.js:309`** · `detectRepetitions` threshold
  raised from `count >= 5` to `count >= 8`. Real exploration of the same
  file/tool 5-7 times no longer files a noise proposal; only sustained
  repetition (8+) does.
- **`hooks/session-learner.js:397`** · `detectWorkflowChains` default
  `minCount` raised from `5` to `8`. Test fixtures pass `minCount`
  explicitly, so they are unaffected.

### Why

The 2026-04-25 retrospective gate report measured the 3-week corpus and
found that the learner's proposal stream was the second largest source
of noise after the 3 OR-soup triggers (now fixed). Of the 51 historic
rejections in `knowledge-log.md`, 100% had `count` between 5 and 7 —
these are typical exploration patterns, not workflows worth memorising.
At 8+ the noise drops drastically while the genuine "you keep doing
this" signal survives.

### Verification

Local test run after the change:
- `test_session_learner.sh` — 8/8 green (tests pass `minCount` directly,
  not the default).
- All other suites unaffected (security, dream, injector, observe,
  yaml-utils, integrity, install, hooks_e2e, uninstall, impact).

This release does not touch any data in `~/.claude/cortex/`.

## [3.15.0] — 2026-04-24

### Sprint 1 · P1 bugfixes (v4.0 plan)

This release attacks every P1 bug diagnosed by the multi-agent Opus 1M
audit (2026-04-24): the observer with mutilated signal, the injector that
ignored monorepos, desynchronised tracking, learner cross-detector noise,
fake-green tests, install.ps1 silent-fail, and the missing PreCompact hook.
No aspirational features — only sanitation.

### Added

- **`hooks/precompact.py`** (Sprint 1.9) — new `PreCompact` hook that
  fires `session-learner.js` fire-and-forget before Claude Code compacts
  the conversation. Timeout 8 s. Marker `.fire-once/precompact-flush-<sid>`
  prevents double-flush. Registered in `install.sh` and `install.ps1`
  as the fifth hook event.
- **`hooks/lib/fire_once.py`** (Sprint 1.11) — reusable "execute once
  per session_id with optional TTL + stale cleanup" primitive. API:
  `not_fired()`, `mark()`, `unmark()`, `once()` (context manager),
  `cleanup_stale()`. Adopted by `precompact.py`; available to other
  hooks when they are next touched.
- **`scripts/check-version-consistency.py`** (Sprint 1.6) — validates
  that `install.sh`, `install.ps1`, `CHANGELOG.md` and
  `docs/FEATURES.md` carry the same version. Blocks push if drift is
  detected. Wired into the `pre-push` hook.
- **`scripts/migrate-tracking-v4.py`** (Sprint 1.3) — idempotent
  one-shot migration that merges every YAML's `occurrences:` +
  `last_seen:` into `instinct-tracking.json`. Automatic backup to
  `tracking.json.pre-v4.0`. **Result on the live corpus**:
  tracking.json went from 1 entry to 110 entries — the root fix for
  the inline-staleness filter (60 d) never firing on 98% of the corpus.

### Fixed

- **Observer PostToolUse parser broken** (Sprint 1.1) — `hooks/observe.py`
  now unwraps `tool_response.content[type=text][text]` (Anthropic v1 API
  shape) and prefers `tool_response.is_error` over the regex heuristic.
  Materially shifts the live corpus's ts:tc ratio (diagnosed at 66:1)
  and ensures `err_msg` actually persists when the data is present.
- **Monorepo domain detection** (Sprint 1.2) — `hooks/lib/injector-engine.js`
  now scans recursively up to depth 3 plus reads `pnpm-workspace.yaml`,
  `turbo.json`, `nx.json`, `lerna.json`, `rush.json`, and the typical
  monorepo folders (`apps/`, `packages/`, `libs/`, `services/`).
  Detects more stacks (remix, gatsby, koa, hono, elysia, nestjs,
  stripe, playwright, fastapi, django, flask). 5-min cache in
  `.project-domains-cache`. Before: monorepos lost ALL their stack
  instincts silently.
- **Cross-detector dedup by incident** (Sprint 1.4) —
  `hooks/session-learner.js` adds `dedupProposalsByIncident()` between
  proposal collection and `writeProposals`. Groups proposals by
  `(sid, file, 5-min window)`. The highest-confidence one survives;
  the rest are recorded as `merged_from` + `sub_detectors`. Expected
  noise reduction 4-5× when one incident triggered multiple detectors.
- **Time-based sliding windows** (Sprint 1.7) — `detectErrorResolutions`
  now also breaks the loop when `ts(candidate) - ts(error) > 300 s`,
  not only by index. Before, a fix 10 events later but 20 min later
  would slip through.
- **Fake-green tests** (Sprint 1.5) — `tests/test_install.sh:215`
  rewritten: it now verifies the malicious tar actually contains `..`
  before running install, and FAILS if `install.sh` does not emit
  "unsafe"/"abort". The old `|| pass "path traversal protection (tar
  creation may differ)"` was an institutionalised false positive.
- **`install.ps1` silent-fail** (Sprint 1.5) — `catch` at line 355
  (settings.json merge) now terminates with `exit 1`. Previously the
  installer reported success even when settings.json was left corrupt.
  Also `catch {}` at line 166 (memory.json migration) now emits
  `Write-Warning` instead of swallowing silently.
- **`session-learner` mirrors to tracking.json** (Sprint 1.3) — after
  updating a YAML's `last_seen`/`occurrences`, the learner now also
  writes to `instinct-tracking.json` via the new `_mirrorToTracking()`
  helper. The JSON becomes the operational source of truth; the YAML
  remains for human readability. The injector (which already reads
  JSON only) finally sees the complete corpus.

### Changed

- **`githooks/pre-push`** now runs `check-version-consistency.py`
  before the test suite. Push is blocked if versions disagree.
- **`scripts/`** is a new tracked folder containing the version
  consistency and migration scripts.

### Security

- settings.json injection: `install.ps1` no longer continues when the
  merge fails. Prevents silent corrupt states.

### Testing

- 11 suites, 97 tests green locally (security 7 + dream 35 + injector
  16 + session-learner 8 + observe 8 + yaml-utils 13 + impact 17 +
  install 38 + hooks_e2e 14 + uninstall 11 + integrity 14).
- Explicit hardening: `tests/test_install.sh` path traversal no longer
  accepts "pass either way" — it asserts the rejection produced
  "unsafe" / "abort" in the installer output.

### Notes on the impact funnel (Sprint 0)

This release does NOT trigger the Sprint 0.5 Go/No-Go Gate — that
still waits for 14 days of `impact.jsonl` data before deciding whether
to continue with Sprints 2-7 of the v4.0 plan. However, the fixes
shipped here (specifically 1.1 parser PostToolUse, 1.2 monorepo
domain, 1.3 unified tracking) are exactly what improves the signal
the gate will read. Without Sprint 1 applied, the gate would read
biased data.

## [3.14.1] — 2026-04-24

### Fixed
- **`tests/test_install.sh` command count**: test 1e was still hard-coded
  to 18 commands (`CMD_COUNT -eq 18`) after the v3.14.0 bump that added
  `/cx-feedback`. The 8 Linux+macOS CI jobs went red on v3.14.0 even
  though the release itself was functional. Fix: bump to 19. Historical
  irony: v3.14.0 only broke the tests that were _not_ Windows (v3.13.3
  had broken only Windows for 4 releases).

## [3.14.0] — 2026-04-24

### Added — Sprint 0 · Instrumentation (v4.0 plan)

This release introduces the **impact funnel** that measures whether
Cortex actually helps the developer, not just how much it observes.
Origin: multi-agent Opus 1M audit (2026-04-24, score 5.8/10) +
Devil's Advocate Opus 1M Max. The audit concluded that Cortex was
measuring use, not impact — and that without that signal no sprint
of the v4.0 refactor was empirically justified.

- **`hooks/lib/impact_log.py`** · writer + compute_metrics + CLI.
  Schema `v:1` JSONL with five event types (`inject` / `follow` /
  `reject` / `feedback` / `outcome`) in `~/.claude/cortex/impact.jsonl`.
  CLI: `python3 impact_log.py stats [--days N] [--json]`, `tail`,
  `rotate`, `log`. Automatic 30-day rotation to `impact.archive/`.
- **`hooks/lib/impact_log.js`** · JS writer mirroring the Python one.
  Used by `injector-engine.js` (fast path: direct `fs.appendFileSync`
  without spawning Python on every tool use).
- **`hooks/lib/injector-engine.js`** · emits an `inject` event for
  every instinct that survives the filters (domain, dedup, token
  budget). `impact_log.js` is loaded with try/catch — if missing
  (older install or partial migration), the injector keeps working.
- **`hooks/session-learner.js`** · new `correlateImpactEvents`
  function that, at session end, reads `impact.jsonl`, finds `inject`
  events for the current sid without a correlated `follow`, and emits
  one per inject by locating the next observation of the same sid.
  Conservative v1 heuristic: `followed=true` if the next obs is not
  an error; `err_after=true` if any of the next 10 has `is_error`.
- **`/cx-feedback`** (new command) · closes the human loop. Modes
  `useful | noise | ignore`, explicit instinct-id target or implicit
  via `.last-instinct`. Applies soft confidence nudge (+0.02 / -0.05),
  writes a `feedback.jsonl` mirror, and logs to `knowledge-log.md`.
  Consistent shorthand (`u/n/i`, `+/-`, `ok/bad`).
- **`/cx-status --impact`** · new flag that calls
  `impact_log.py stats --days 14` and shows the aggregated funnel
  plus the Go/No-Go Gate recommendation (`GO` / `PARTIAL` / `NO-GO`).
- **`docs/IMPACT-METRICS.md`** · canonical formulas, event schema v1,
  Sprint 0.5 Go/No-Go Gate thresholds, privacy notes, testing contract.
- **`tests/test_impact.sh`** · 17 tests: schema v1, JS↔Python
  compatibility, concurrent writes (10 parallel → 10 lines, 0 loss),
  rotation, gate GO/NO-GO, formulas against fixtures, input
  validation.

### Changed

- **`tests/test_integrity.sh`** · now validates 19 commands (was 18)
  including `cx-feedback`. `EXPECTED_COMMANDS` updated.
- **`core/claudemd-section.md`** · adds `/cx-feedback` to the command
  listing injected into the user's CLAUDE.md Cortex section.

### Canonical formulas (summary — detail in `docs/IMPACT-METRICS.md`)

```
useful_event = feedback.rating == "useful"
             OR (follow.followed == true AND NOT follow.err_after)
noise_event  = feedback.rating == "noise"
             OR follow.followed == false
useful_ratio = count(useful) / count(inject)
noise_ratio  = count(noise)  / count(inject)
health_ratio = useful_ratio / max(noise_ratio, 0.01)
```

Sprint 0.5 Go/No-Go Gate (moderate thresholds confirmed by the user):
- `useful_ratio ≥ 0.25 AND health_ratio ≥ 1.5` → **GO** (continue v4.0 plan)
- `0.10 ≤ useful_ratio < 0.25` or `1.0 ≤ health_ratio < 1.5` → **PARTIAL** (sprints 2-4 only)
- `< 0.10` or `< 1.0` → **NO-GO** (bugfixes + docs only; consider trimming)

### Privacy

`impact.jsonl` does NOT store code, file paths, tool inputs or outputs.
Only instinct ids, tool names, session ids, project id prefixes
(sha256), domain, confidence. Free-text `note` from feedback is
sanitised with the same rules as the injector (10 blocked keywords +
strip control chars, 500-char cap).

### Why now

The v4.0 plan starts here. Next step: let `impact.jsonl` accumulate
14 days of data, run `/cx-status --impact`, and decide at the
Sprint 0.5 gate whether to continue with Sprint 1 (P1 bugfixes), 2
(commands consolidation), 3 (docs auto-gen), 4 (Python installer),
5 (autonomy), 6 (privacy), 7 (release v4.0) — or scope down to a
v3.14.x consolidation.

## [3.13.3] — 2026-04-24

### Fixed
- **CI `test-windows` red since v3.12.4 (4 consecutive releases)**:
  `.github/workflows/test.yml:159` was throwing
  `throw "injector.js exited with $exit: $result"`, which PowerShell 7
  interprets as a drive-provider reference (`$drive:path` syntax)
  because `:` immediately follows the variable name. Result:
  `ParserError: Variable reference is not valid. ':' was not followed
  by a valid variable name character` and the job failed before the
  real test ran. `injector.js` itself was correct; the bug lived only
  in the workflow YAML. Fix: wrap `$exit` in braces → `${exit}`
  (PowerShell best practice for disambiguating a variable adjacent
  to `:`).

### Context
- Blocking release for the entire v4.0 refactor plan: without green
  CI you cannot start Sprint 0 (instrumentation) with confidence.
  This hotfix unblocks `main`.
- Detected during the multi-agent Opus 1M audit
  (`docs/DEEP-AUDIT-2026-04-24.html`) — CI had been red for 4
  releases (v3.12.4, v3.13.0, v3.13.1, v3.13.2) with no release
  diagnosing it. The fix is a single character and touches no hooks
  or logic.

## [3.13.2] — 2026-04-24

### Fixed
- **Dream Cycle contradiction detector produced 97% false positives**: `detect_contradictions()` flagged every instinct pair in the same domain whose action text happened to contain an antonym keyword (always/never, enable/disable, etc), regardless of whether the two instincts were about the same subject. On a 128-instinct corpus this surfaced 38 "contradictions" — all unrelated (e.g. "always include `-i ~/.ssh/hetzner-fersora`" vs "NEVER `--no-verify` on git push", flagged together because both live in the `gotcha` domain and contain the `always`/`never` keywords). The noise made `/cx-dream` output unusable for actual contradiction review.

### Changed
- **Added topic-overlap gate to `detect_contradictions()`**: after keyword antonym match, the function now computes Jaccard similarity of non-stopword, non-antonym tokens between the two action texts. Pairs with overlap below `min_action_overlap` (default `0.30`) are rejected as false positives. Live corpus result: 38 → 1 contradictions, the one survivor being a legitimate human-review case (two Stripe-related instincts sharing real vocabulary).
- `detect_contradictions(instincts, min_action_overlap=0.30)` — threshold is parameterizable. Set to `0` to restore pre-3.13.2 keyword-only behavior (all existing tests continue to pass at default threshold because the shared subject/verb tokens in the test actions already clear 0.30).
- New stopword and antonym-word lists exposed as `_STOPWORDS` and `_ANTONYM_WORDS` module constants (EN + ES).

### Added
- 3 new contradiction detection tests in `tests/test_dream_cycle.sh`:
  - **12b**: topic-overlap gate rejects unrelated always/never pairs in the same domain
  - **12c**: real contradiction with shared subject is still detected
  - **12d**: `min_action_overlap=0` restores legacy keyword-only behavior (back-compat opt-out)

## [3.13.1] — 2026-04-24

### Fixed
- **Silent YAML parse failures across instinct files**: Claude (via `/cx-gotcha`, `/cx-analyze --accept`, `/cx-validate`, `/cx-promote`) was writing regex triggers in YAML double-quoted strings like `trigger: "Bash.*\.env"`. YAML double-quoted strings reject `\s`, `\.`, `\(` as invalid escape sequences, so strict `yaml.safe_load_all` crashed on 18 of 128 instinct files — which meant reflexes and instincts were silently missing from injection without any error surfaced.
- **Repaired 18 existing broken instinct YAMLs** by converting invalid double-quoted regex fields to single-quoted literals.

### Added
- **`hooks/lib/yaml_normalize.py`** — silent auto-repair module. Scans `~/.claude/cortex/instincts/global/` and all `projects/*/instincts/` directories on every SessionStart. Only touches files that currently fail strict parse; converts offending `"..."` fields (`trigger`, `condition`, `matcher`, `action`) to `'...'` or a block scalar if the value contains a `'`. Idempotent, safety-checked (won't write unless the rewrite re-parses cleanly). Callable as a Python module (`normalize_all()`) or standalone script.
- **SessionStart hook integration** — `session-start.py` now calls `normalize_all()` silently on every session start. If it repairs anything, emits `[cortex:yaml-normalize] repaired N file(s)` to stderr; never blocks session start on failure.

### Changed
- **`/cx-validate` template**: explicit single-quote rule for regex-carrying fields (`trigger`, `condition`, `matcher`, `action`) when Claude writes accepted proposals to disk. Prevents re-introduction of the bug.
- **`/cx-gotcha` template**: same single-quote rule added to the gotcha instinct generator.
- **`/cx-analyze` template**: single-quote rule added to the agent output contract + corrected the worked example.

## [3.13.0] — 2026-04-23

### Added
- **`/cx-dashboard` command**: generates a self-contained visual HTML dashboard of the complete Cortex state at `~/.claude/cortex/dashboard.html` and opens it in the browser. Styled with the Fersora brand (Merriweather + Open Sans + JetBrains Mono, Fersora Green / Lavender / Orange palette, sticky nav with scroll-spy, footer with contact signature). Shows laws, instincts (grouped by confidence tier), reflexes (with fire stats and `[never fired]` flags), projects, top activations, recent events from `knowledge-log.md`, and a computed system health score (0-100) with semantic coloring. Complements `/cx-status` (ASCII terminal dashboard) for shareable reports and at-a-glance overviews. Brings parity with Sinapsis's visual reports.
- **`hooks/lib/dashboard_gen.py`**: the dashboard generator (~370 lines, zero external deps, Python 3.8+, cross-platform). Read-only — never modifies Cortex data. Atomic write via `os.replace()`.

### Fixed
- **Dashboard project deduplication**: `read_projects()` now groups registry entries by normalized root path and sums obs/instinct counts. Prevents the same physical project appearing twice when Cortex assigned different hashes before and after `git remote` was added (since `detectProject()` uses `hashInput = url || root` — no remote falls back to path, producing a different hash than the remote-URL hash). Canonical entry is the one with a remote (or most recent activity). A warning banner + `+N dup` badge appears when duplicates are detected, suggesting `/cx-dream` for permanent consolidation.

## [3.12.4] — 2026-04-22

### Fixed
- **Windows PreToolUse hook broken — all Claude Code tools blocked**: `install.ps1` registered `bash ~/.claude/hooks/cortex/injector.sh` on Windows, but `bash` is not in PATH by default (only with Git Bash/WSL). Every tool call triggered a broken hook, effectively blocking Claude Code. Reported by Adams Ayón after v3.12.3 installs still failed.

### Added
- **`hooks/injector.js`** — cross-platform Node.js wrapper equivalent to `injector.sh`. Reads stdin, writes payload to a 0600-mode tmp file, sets engine env vars (`_CX_INPUT_FILE`, `_CX_CORTEX_DIR`, `_CX_REFLEXES_FILE`, `_CX_GLOBAL_INSTINCTS_DIR`), and delegates to the existing `lib/injector-engine.js`. Same security model as the bash wrapper (tmp file avoids payload exposure via `/proc` or env). Safety timeout on stdin read, signal cleanup handlers.

### Changed
- **`install.ps1` PreToolUse hook**: registers `node ~/.claude/hooks/cortex/injector.js` instead of `bash ~/.claude/hooks/cortex/injector.sh`. Existing installs upgrade cleanly — the hook-merge Python block strips any prior `hooks/cortex/` entry before writing the new one.
- **`install.ps1` Node.js check**: upgraded from warning to hard requirement (exit 1) on Windows, since the injector hook now requires it.
- **`install.sh`**: unchanged behavior — Linux/Mac continue using `bash injector.sh`. The new `injector.js` file is copied by the existing `*.js` glob but not registered as a hook. Zero regression risk for existing Unix installs.
- **`tests/test_install_ps1.ps1`**: expects `injector.js` in the hook file list and `node injector.js` in the PreToolUse config.

## [3.12.3] — 2026-04-21

### Fixed
- **install.ps1 — 19 additional `Join-Path` 3+ arg calls**: v3.12.2 only fixed line 20; the same PowerShell 7.6 crash (`No positional parameter found for argument 'X'`) recurred on line 87 and throughout the installer. All remaining `Join-Path $a $b $c [$d...]` calls replaced with `[System.IO.Path]::Combine($a, $b, $c, [$d...])` — a .NET method that works identically across PS 5.1–7.x and accepts any number of path segments. Affected lines: 87 (laws glob), 141/170/179 (core templates), 215/216 (skill + agents), 224 (commands), 246 (hooks glob), 253 (lib dir), 267/268 (seed instinct + rule), 360 (CLAUDE.md section), 417/426 (backup laws/instincts import), 444/456 (projects registry + project-scoped instincts), 503/513/516 (seed laws/instincts), 545 (summary). Same fix applied to `tests/test_install_ps1.ps1:159`. Reported by AR8-Git (#16 continuation).

## [3.12.2] — 2026-04-20

### Fixed
- **install.ps1 line 20**: `Join-Path $ClaudeDir "hooks" "cortex"` crashed on PowerShell 7.6 with "No positional parameter found for argument 'cortex'". Fixed by chaining calls: `Join-Path (Join-Path $ClaudeDir "hooks") "cortex"`, which is compatible with all PowerShell versions (5.1+). Reported by AR8-Git (#16).

## [3.12.1] — 2026-04-14

### Fixed
- **dream_cycle.py `staleness_score()`**: Fixed TypeError crash when `last_seen` is a date-only string ("2026-04-14"). `fromisoformat()` produced a naive datetime, but `datetime.now(utc)` is timezone-aware — subtraction raised TypeError, caught by except, returned max staleness (100), causing ALL instincts to be marked for archival. Fix: use `datetime.date.fromisoformat()` + `datetime.date.today()` which are both naive and handle both date-only and datetime strings via `str(last_seen)[:10]`.

## [3.12.0] — 2026-04-14

### Security
- **Symlink protection in cleanup functions**: All 3 new `dream_cycle.py` cleanup functions skip symlinks (`os.path.islink()` guard) to prevent information disclosure or deletion of files outside the cortex tree.
- **Version comparison fix**: Migration in `install.sh`/`install.ps1` now uses tuple comparison `(3, 12, 0)` instead of string comparison, which failed for versions v3.2.0–v3.9.x.

### Added
- **Dream Cycle Module 6 — Cleanup**: 3 new functions in `dream_cycle.py`: `detect_orphan_projects()` (dead registry entries, orphan dirs, stale projects >90d), `cleanup_expired_context()` (context.md older than 14d TTL), `consolidate_old_archives()` (observation archives older than 90d). Integrated into `/cx-dream` as Step 3c with confirmation UX and knowledge-log.md events (`orphan-removed`, `context-cleaned`, `archive-purged`).
- **Configurable injection limits**: `max_instincts_per_injection` and `max_reflexes_per_injection` from `memory.json` now read at runtime by `injector-engine.js`. Previously hardcoded as 3 and 2 respectively.
- **Reflex stats in /cx-status**: Step 4 now shows `enabled`, `fireCount`, `lastFired` per reflex. Highlights reflexes that have never fired with `[NEVER FIRED]` tag. Summary line with active/total/never-fired counts.
- **6 new tests** in `test_dream_cycle.sh`: orphan detection (dead entry, orphan dir, stale project), expired context.md, fresh context.md negative, old archive detection. Total: 32 tests in suite.

### Changed
- **cx-dream.md**: Updated from 5 modules to 6. Added Step 3c (Cleanup) with output format, confirmation flow, and knowledge-log event formats.
- **cx-status.md**: Reflex table expanded with `ENABLED` column, `[NEVER FIRED]` highlights, and summary line.

### Fixed
- **injector-engine.js**: `MAX_INSTINCTS` and `MAX_REFLEXES` now read from `memory.json` config instead of being hardcoded. Loads `memory.json` once at engine start.

### Removed
- **memory.json `identity` block**: Removed dormant `identity.name`, `identity.role`, `identity.language` fields from template. No hook ever read these fields. Migration in `install.sh` and `install.ps1` removes the block from existing installations.

## [3.11.1] — 2026-04-12

### Fixed
- **test_install.sh**: Updated expected command count from 16 to 17 (cx-timeline added).
- **test_integrity.sh**: Updated expected command list and count to include cx-timeline.

## [3.11.0] — 2026-04-12

### Added
- **cx-timeline**: New command — semantic knowledge event log. Shows chronological record of all instinct creations, promotions, decays, archives, downvotes, and evolutions. Supports `--last N`, `--event TYPE`, `--since DATE`, `--stats` filters. Summary statistics for last 7 days.
- **knowledge-log.md**: Append-only event log at `~/.claude/cortex/knowledge-log.md`. Every knowledge-changing event appends one line with date, event type, instinct ID, confidence info, and source command. 11 event types tracked.
- **cx-status domain grouping**: New "Knowledge by Domain" section (Step 2b) groups instincts by `domain` field with per-domain counts and law-tier entries.
- **install.sh/ps1**: Create empty `knowledge-log.md` on install/upgrade (preserved on reinstall).
- **injector-engine.js**: Draft auto-promote events now logged to knowledge-log.md.

### Changed
- **cx-validate.md**: Appends created/rejected/promoted/archived events to knowledge-log.md.
- **cx-distill.md**: Appends decayed/archived/law/global events to knowledge-log.md.
- **cx-dream.md**: Appends deduped/decayed/archived events to knowledge-log.md.
- **cx-downvote.md**: Appends downvoted/archived events to knowledge-log.md.
- **cx-evolve.md**: Appends evolved events to knowledge-log.md.
- **cx-promote.md**: Appends global promotion events to knowledge-log.md.

## [3.10.7] — 2026-04-12

### Added
- **CLAUDE.md**: Project-level context file for Claude Code — references `docs/FEATURES.md` as source of truth, summarizes release workflow and key directory structure.

## [3.10.6] — 2026-04-12

### Fixed
- **install.sh/ps1**: Reflex migration now updates existing reflexes (matcher, condition, action, severity) from defaults — not just adds new ones. Preserves user runtime data (fireCount, lastFired, enabled). Previously a reflex bug fix required manual editing of `~/.claude/cortex/reflexes.json`.

## [3.10.5] — 2026-04-12

### Fixed
- **reflexes.default.json**: `instinct-downvote` reflex narrowed to `Bash` matcher only (was `Bash|Edit|Write`). Prevents false positives when editing files that legitimately contain the word "instinct".

## [3.10.4] — 2026-04-12

### Fixed
- **CI**: ShellCheck step referenced deleted `observe.sh` and `session-start.sh` — updated to `injector.sh` only. Added `hooks/lib/*.py` to flake8 lint scope.
- **FEATURES-visual.html**: Added cx-downvote + cx-retro cards, updated session-start.sh→.py, "14→16 comandos", inline staleness mention, footer version.

### Changed
- **README.md**: Added [gstack](https://github.com/garrytan/gstack) by Garry Tan to Credits — confidence calibration concepts, command usage timeline, inline staleness approach.

## [3.10.3] — 2026-04-12

### Added
- **injector-engine.js**: Inline read-only staleness filter — instincts not seen in 60+ days are skipped during injection without writing to disk. Stale instincts stop being injected immediately instead of waiting for a manual `/cx-dream`. Dream Cycle still handles permanent archival.

## [3.10.2] — 2026-04-12

### Fixed
- **FEATURES.md**: Added cx-downvote and cx-retro to commands table (14→16). Updated hook references session-start.sh→.py, observe.sh→.py. Updated test counts (8/8/16 for observe/learner/injector).
- **README.md**: Updated commands table (14→16, added cx-downvote, cx-retro). Updated reflexes table (8→10, added instinct-downvote, capture-decision).
- **SKILL.md**: Updated version v3.6→v3.10. Added cx-downvote, cx-retro to commands table and frontmatter description.
- **FEATURES-visual.html**: Updated footer version to v3.10.2.

## [3.10.1] — 2026-04-12

### Fixed
- **observe.py**: Removed `Skill` from skip list — was preventing timeline.jsonl from ever having data (cx-retro and cx-audit command usage would always be empty).
- **cortex_utils.py**: Fixed `atomic_write()` double-close risk on fd in error path. Added `os.makedirs()` for parent directory creation.
- **session-start.py**: Commands hint now lists all 16 commands (was missing 5: export, backup, restore, router, promote).
- **README.md**: Updated `session-start.sh` → `session-start.py` in 3 locations. Updated reflex count 8 → 10.
- **SECURITY.md**: Updated hook file references (observe.sh/session-start.sh → observe.py/session-start.py).
- **FEATURES.md**: Updated reflex count 8 → 10.
- **cx-audit.md**: Updated reflex count in token analysis example.
- **test_install_ps1.ps1**: Updated hook filenames and mock settings for v3.10 (session-start.py, observe.py).
- **test_install.sh**: Added cortex_utils.py and injector-engine.js to lib installation check.

## [3.10.0] — 2026-04-12

### Changed
- **session-start.sh → session-start.py**: Complete rewrite from Bash/Python hybrid to pure Python. Eliminates BSD/GNU `date` fallbacks, 4 inline `python3 -c` snippets, and `sed`/`tr`/`grep` subprocess chains. Uses `datetime`, `pathlib`, and `re` stdlib modules.
- **observe.sh**: Deleted. Observer now invoked directly as `python3 observe.py` from settings.json hooks. The 12-line wrapper added zero value.
- **injector.sh**: Reduced from 367 lines to 42-line thin wrapper. All Node.js logic extracted to `hooks/lib/injector-engine.js` for testability and linting.
- **hooks/lib/cortex_utils.py**: New shared Python module — `sanitize_injection()`, `detect_project()`, `read_json_safe()`, `atomic_write()`. Used by both `observe.py` and `session-start.py`.
- **hooks/lib/injector-engine.js**: New standalone Node.js module extracted from inline heredoc in injector.sh. Can be tested, linted, and imported independently.
- **install.sh/ps1**: Legacy file cleanup on upgrade — removes `session-start.sh` and `observe.sh` before installing new Python hooks. Settings.json hook commands updated to `python3` invocations.

## [3.9.0] — 2026-04-12

### Added
- **cx-downvote**: New command to downvote incorrect instinct injections. Records negative feedback in instinct-tracking.json and reduces confidence when rejection rate exceeds thresholds (20%→-0.05, 30%→-0.10, 50%→-0.15). Auto-archives instincts below 0.10 confidence.
- **cx-retro**: Weekly retrospective command — aggregates command usage (from timeline.jsonl), instinct activations, downvotes, and maintenance status over configurable date range. Pure read-only reporting with actionable recommendations.
- **injector.sh**: Writes `.last-instinct` file on every injection with instinct IDs and timestamp, enabling `/cx-downvote` to identify targets.
- **reflexes**: New `instinct-downvote` reflex — detects phrases like "wrong instinct", "ignore instinct" and reminds user about `/cx-downvote`.

### Changed
- **cx-router.md**: Updated command table with cx-downvote (~100 tok) and cx-retro (~200 tok). Total commands: 16.
- **claudemd-section.md**: Updated command list to include cx-downvote and cx-retro.

## [3.8.0] — 2026-04-12

### Added
- **observe.py**: Subagent tool use now captured (was silently skipped). New `aid` field in observation JSONL for agent ID.
- **session-learner.js**: Command usage timeline — detects `/cx-*` Skill invocations and logs to `~/.claude/cortex/log/timeline.jsonl`. Enables usage reporting in cx-audit and cx-dream.
- **reflexes**: New `capture-decision` reflex — detects strategic decisions ("from now on", "always use", "never use") and reminds to persist them. Bilingual EN+ES.
- **install.sh/ps1**: Automatic reflex migration — new reflexes from defaults are appended to existing installations without overwriting user data.
- **cx-audit.md**: Command usage analysis from timeline data (unused commands in last 30 days).
- **cx-dream.md**: Maintenance bonus/penalty in health score based on recent command usage.

## [3.7.4] — 2026-04-12

### Fixed
- **cx-status.md**: Step 3 (Projects) now explicitly counts observations and instincts per project hash via bash loop instead of relying on LLM inference. Previously showed "—" for all projects except the current one.

## [3.7.3] — 2026-04-10

### Changed
- **CI matrix**: Drop EOL runtimes. Node 18→22/24, Python 3.9→3.11/3.13
- **Badges**: Updated to reflect minimum supported versions (Node 22+, Python 3.11+)

## [3.7.2] — 2026-04-10

### Fixed
- **session-learner.js**: Workflow chain detector now requires 5+ repetitions (was 3) and skips same-tool trigrams (Bash→Bash→Bash). Eliminates ~90% of noise proposals.
- **session-learner.js**: Auto-updates memory.json stats (observations, instincts, laws) at end of each session. Stats were permanently stuck at 0.

## [3.7.1] — 2026-04-10

### Fixed
- **session-learner.js**: Proposals now include `project_id` and `project_name` (were missing, breaking cx-distill universality filter)
- **session-learner.js**: Fix `projectId is not defined` error — moved project resolution to main scope before proposal generation

### Changed
- **injector.sh**: Instinct tracking now records `projects_seen` array — tracks which projects each instinct activates in (zero token impact, disk-only)
- **cx-distill.md**: Rewritten universality filter with explicit decision table (projects × stack matrix). New cost/benefit test: if instinct already has a good trigger, keep as instinct instead of promoting to law (saves ~40 tok/session). Clear guidance on when to reject candidates.

## [3.7.0] — 2026-04-10

### Added
- **Agent evolution**: `/cx-evolve` now generates reusable agents from recurring Agent tool patterns
- **Agent pattern detector**: `session-learner.js` detects recurring Agent tool usage (3+ similar descriptions, Jaccard >= 0.40) and proposes `agent-evolution` instincts
- **`evolved/agents/`** directory in installer (install.sh + install.ps1) for evolved agent definitions

### Changed
- **cx-evolve.md**: Updated artifact types table to include Agent (.md), added agent generation section with system prompt synthesis, tool access, and dual-write to `evolved/agents/` + `~/.claude/agents/`
- **Knowledge pipeline**: `SKILLS/COMMANDS/RULES` → `SKILLS/COMMANDS/RULES/AGENTS` in all docs and diagrams (README, FEATURES.md, FEATURES-visual.html)
- **session-learner.js**: 5 pattern detectors (was 4) — added `detectAgentPatterns()`

## [3.6.6] — 2026-04-10

### Added
- **README.md**: Usage Guide section — hooks table, periodic commands, daily workflow, weekly maintenance, knowledge evolution diagram
- **docs/FEATURES-visual.html**: Standalone visual explainer page (fs-brand styled) — the problem, 4-step pipeline, before/after comparison, confidence lifecycle, daily workflow, 14 command cards, install guide. Designed for non-technical readers.

### Changed
- **docs/FEATURES.md**: Updated test counts to 159 (11 suites), version to 3.6.6
- **.gitignore**: Added `!docs/FEATURES-visual.html` exception (public doc tracked in git)

## [3.6.5] — 2026-04-10

### Added
- **`tests/test_install_ps1.ps1`**: 9 PowerShell tests — syntax validation, version consistency, security features (path traversal, chmod 600, atomic writes), backup categories, hook events, hook files, settings.json merge simulation
- **CI `test-windows` job**: Runs on `windows-latest` with `pwsh` — first Windows coverage for install.ps1

## [3.6.4] — 2026-04-10

### Added
- **docs/FEATURES.md**: Now tracked in git as the public feature inventory (only docs/ file in repo)
- **release-workflow**: Mandatory step 4b — update FEATURES.md on every feature/fix

### Changed
- **docs/FEATURES.md**: Updated to v3.6.3 with all recent changes (150 tests, uninstall safety, decay formula, error patterns, YAML multiline, etc.)
- **.gitignore**: `docs/` still ignored but `!docs/FEATURES.md` exception added
- Internal docs (AUDIT.md, audit HTMLs, reports) removed from git tracking (kept local)

## [3.6.3] — 2026-04-10

### Added
- **`tests/test_uninstall.sh`**: 11 tests — uninstall cleanup (hooks, skill, commands removed), data preservation, settings.json cleanup, CLAUDE.md section removal, backup creation with laws, data deletion with backup, safety guard (requires typing DELETE to delete without backup), user CLAUDE.md content preserved after uninstall
- **`tests/test_integrity.sh`**: 14 tests — observe.sh wrapper delegation, all 14 commands exist, command file references valid, claudemd-section lists all commands, memory.template.json schema validation, reflexes.default.json schema validation, version consistency (install.sh = install.ps1 = CHANGELOG), core files exist, CI includes uninstall.sh

### Security
- **uninstall.sh**: Safety guard requires typing 'DELETE' to confirm data deletion when no backup exists (prevents accidental data loss)

### Fixed
- **hooks/session-start.sh**: Fix `ls *.md` glob failure under `set -eo pipefail` when no EOD files exist (added `|| true`)
- **uninstall.sh**: Remove empty CLAUDE.md when only Cortex section existed (was leaving 1-byte file)
- **uninstall.sh**: Preserve user CLAUDE.md content — only remove ## Cortex section, not entire file
- **.github/workflows/test.yml**: Added `uninstall.sh` to ShellCheck coverage

### Changed
- Test coverage: **125 → 150 tests** across **8 → 10 suites** (added uninstall + integrity)

## [3.6.2] — 2026-04-10

### Security
- **install.ps1**: Path traversal validation on backup import (tar -tzf pre-check, matching install.sh)
- **install.ps1**: chmod 600 on settings.json before os.replace
- **hooks/injector.sh**: Trap quoting fix for TMPDIR with spaces
- **hooks/injector.sh**: Validate CORTEX_DIR against real home (prevents $HOME spoofing)
- **hooks/session-start.sh**: CWD validation — absolute path check, path traversal guard, symlink resolution via pwd -P
- **hooks/lib/validate_instinct.py**: Handle YAML multiline action values (| and >) to prevent validation bypass
- **uninstall.sh**: Atomic write for settings.json via tempfile + os.replace + chmod 600

### Fixed
- **hooks/session-start.sh**: Reset .session-token-budget at session start (prevents silent instinct suppression after 40-100 sessions)
- **hooks/lib/dream_cycle.py**: Unified decay formula to linear -0.05/30d (was multiplicative, diverged from cx-distill docs by up to 0.14)
- **hooks/lib/dream_cycle.py**: Full pairwise dedup comparison (was break-on-first-match, missed transitive duplicates)
- **hooks/session-learner.js**: Require 3+ overlapping edits for correction detection (was 2+, caused false positives on normal editing)
- **hooks/observe.py**: Error pattern context anchors to avoid false positives on filenames (ErrorBoundary) and zero-failure test output (failed: 0)
- **docs, SKILL.md, README.md, memory.template.json, injector.sh**: MAX_INSTINCTS updated from 2 to 3 in all 6 locations
- **install.ps1**: Backup import now copies all 8 data categories (was 2: laws + instincts only)
- **install.ps1**: Atomic write for memory.json onboarding via tempfile + os.replace

### Changed
- **hooks/injector.sh**: Import yaml-utils.js instead of 35-line inline parseInstinctYaml (eliminates drift risk)
- **hooks/session-learner.js**: 512KB log rotation (was unbounded growth)
- **hooks/observe.py + session-learner.js**: Error patterns aligned between observer (9 patterns) and learner (now 9+3)
- **hooks/session-start.sh**: Upgraded to `set -euo pipefail` (was `set -e` only)
- **.github/workflows/test.yml**: Lint steps now blocking (`|| true` removed); shellcheck --severity=error, flake8 --select critical
- **.github/workflows/test.yml**: Added run_all.sh summary step

### Added
- **tests/test_hooks_e2e.sh**: Token budget reset test (validates FIX-001)
- **tests/test_dream_cycle.sh**: Decay formula consistency tests — decay(0.80, 60d)=0.70, decay(0.80, 30d)=0.75, decay(0.80, 0d)=0.80
- **tests/test_install.sh**: Trap cleanup via SANDBOXES array + EXIT handler
- **docs/AUDIT.md**: Checklist updated — 25/26 items completed, ARCH-002 deferred to v3.7
- **docs/fs-cortex-v2-verificacion.html**: Post-correction verification report (96% resolved, score 69→81)

## [3.6.1] — 2026-04-09

### Fixed
- **SECURITY.md**: Supported versions updated to `3.x.x` (was `3.0.x`), contact email corrected to `info@fersora.com`

## [3.6.0] — 2026-04-09

### Added
- **`tests/test_install.sh`**: 37 tests — fresh install (20 checks: version, hooks, lib, commands, SKILL, CLAUDE.md, settings.json, core files, seeds, dirs), upgrade (15 checks: version, laws, instincts, memory, reflexes, observations, proposals, CLAUDE.md sections, settings hooks, new files), idempotency (3 runs), path traversal protection
- **`tests/test_hooks_e2e.sh`**: 13 end-to-end tests — observe.py (JSONL format, is_error, secret scrubbing), session-start.sh (JSON output, laws, skills hint), injector.sh (instinct injection, prompt injection blocked), session-learner.js (proposals, context.md), dream_cycle.py (5 modules), validate_instinct.py (accept/reject), yaml-utils.js (integration)

### Fixed
- **`install.sh`**: lib copy now includes `*.js` files (yaml-utils.js was not installed)
- **`install.ps1`**: Same fix — lib copy includes `*.js` alongside `*.py`

## [3.5.0] — 2026-04-09

### Added
- **Draft auto-promote**: Injector now tracks ALL instinct matches including drafts (confidence < 0.30). Drafts auto-promote to 0.35 after 5+ activations across 3+ sessions
- **Token budget cap**: Per-session token budget (8000 tokens). Instinct injection skipped when budget exceeded; reflexes always pass (safety exempt)
- **`tests/test_yaml_utils.sh`**: 13 tests for shared YAML parser — float/int parsing, quoted/bare strings, colon in values, field updates, file listing, edge cases

### Fixed
- **`install.sh`**: Backup archive validated against path traversal (`../` and absolute paths) before extraction

## [3.4.0] — 2026-04-09

### Added
- **`hooks/lib/yaml-utils.js`**: Shared YAML frontmatter parser — unified `parseFloat` for confidence, eliminates duplicated logic between injector.sh and session-learner.js
- **`/cx-router`**: Command catalog with token costs per command, session budget estimate, and next-action suggestion
- **`/cx-promote`**: Cross-project instinct promotion — finds instincts in 2+ projects via Jaccard similarity (>=0.70) and promotes to global scope
- **`/cx-status` tracking section**: Shows top 10 most activated instincts from `instinct-tracking.json` with count, sessions, first/last seen
- **`tests/test_injector.sh`**: 14 tests — sanitization, ReDoS, injection limits, CORTEX-MANAGED markers, yaml-utils module
- **CORTEX-MANAGED marker**: All 5 hook files now have `# CORTEX-MANAGED` on line 2 for reliable detection during upgrades
- **Skills hint**: Lightweight ~50-token hint injected at SessionStart listing all available `/cx-*` commands

### Changed
- **session-learner.js**: Imports YAML parsing from shared `hooks/lib/yaml-utils.js` instead of inline implementation; exports functions for testability via `require.main` guard
- **SKILL.md**: Updated to 14 commands (was 12)
- **claudemd-section.md**: Added `/cx-router` and `/cx-promote` to command list

## [3.3.0] — 2026-04-09

### Security
- **session-learner.js**: ReDoS guard on instinct triggers and reflex matchers (matching injector.sh's `isSafeRegex`)
- **session-learner.js**: Sanitize proposal action text against prompt injection (4 detectors)
- **session-start.sh**: Normalize whitespace before sanitization (blocks double-spaced bypass)
- **session-start.sh**: Pass CONTEXT via env var instead of shell argument (prevents backslash corruption)
- **injector.sh**: Pass hook payload via temp file instead of env var (no longer visible in /proc)

### Fixed
- **install.sh/ps1**: Include `*.py` in hook copy loop — fixes observe.py not being installed on fresh installs (CRITICAL)
- **install.sh/ps1**: Narrow CLAUDE.md regex to exact `## Cortex (Learning System)` heading — no longer deletes user sections like `## CortexDB`
- **session-learner.js**: Fix readStdin Promise double-resolve (clear timeout on end event)
- **session-learner.js**: Replace static `NOW` with dynamic `now()` for accurate timestamps
- **session-learner.js**: Preserve user validation status (approved/rejected) on proposal dedup
- **session-learner.js**: Add missing `status: 'pending'` to repetition proposals
- **injector.sh**: Fall back to project root hash when no `origin` remote exists
- **injector.sh**: Use project root (not cwd) for domain detection in subdirectories
- **observe.py**: Windows file locking via `msvcrt` (was plain append)
- **observe.py**: Windows UID fallback uses `USERNAME` env var (was shared uid `0`)
- **install.ps1**: PS 5.1 compatible ternary syntax (was PS 7+ only)
- **install.ps1**: Direct temp directory creation (fixes TOCTOU race)
- **install.sh**: Trap cleanup for backup temp directory on script failure
- **install.sh**: Atomic write for onboarding `memory.json` via tmp+rename

### Changed
- **observe.py**: File-based project ID cache (5min TTL) — eliminates git subprocess per tool use
- **observe.py**: Conditional registry.json write — skips when project metadata unchanged
- **observe.py**: Fixed docstring placement in `archive_if_needed` and `auto_purge`
- **memory.template.json**: Version updated to 3.2.0
- **CI**: Added `fail-fast: false`, shellcheck + flake8 linting step, portable `$TMPDIR` in tests

## [3.2.0] — 2026-04-09

### Added
- **`hooks/observe.py`**: Complete Python rewrite of observe.sh — single process replaces 11 Python spawns, ~70ms avg (was ~800ms). Adds `is_error` detection with 9 patterns, session_id[:24] (was [:16]), configurable via memory.json
- **Session learner detectors**: 3 new pattern detectors in `session-learner.js`:
  - Error-to-fix pair detection using `is_error` flag (confidence 0.40)
  - User correction detection — same file edited 2+ times (confidence 0.50)
  - Workflow chain trigrams — repeated 3-tool sequences (confidence 0.30-0.60)
- **Auto-proposal generation**: All 4 detectors (error-fix, repetitions, corrections, workflows) generate proposals automatically at session end with `session_date` field for cross-day tracking
- **Injector domain pre-filter**: Detects project stack (React, Node, Supabase, Python, Rust, Go) from `package.json`/config files, skips irrelevant instincts
- **Injector occurrence tracking**: Tracks instinct activation count and sessions in `instinct-tracking.json`
- **GitHub Actions CI**: `.github/workflows/test.yml` — runs all 4 test suites on push/PR across macOS + Linux, Python 3.9/3.12, Node 18/22
- **`tests/run_all.sh`**: Unified test runner for all suites
- **`tests/test_observe.sh`**: 7 tests — scrubbing, is_error, dedup, atomic write, e2e, performance
- **`tests/test_session_learner.sh`**: 7 tests — error-fix pairs, corrections, workflow chains, proposal structure

### Changed
- **`hooks/observe.sh`**: Reduced to thin wrapper that delegates to `observe.py`
- **`hooks/injector.sh`**: Max instincts increased from 2 to 3, with 500 char/instinct and 1500 char total limit
- **`hooks/observe.py`**: Config values (`max_observations_mb`, `archive_days`, `learn_threshold`) now read from `memory.json` instead of hardcoded
- **`hooks/session-start.sh`**: Replaced emojis with `[MAINT]`/`[ACTION]` text prefixes

### Fixed
- **`agents/cortex-observer.md`**: Model reference corrected from `haiku` to `opus`
- **`skills/cortex/SKILL.md`**: Model references corrected from `Haiku` to `Opus 1M`
- **`README.md`**: Updated max instincts (2→3), clarified regex triggers in reflexes table
- **`hooks/observe.py`**: OpenAI token pattern now matches `sk-proj-*` format

## [3.1.0] — 2026-04-09

### Added
- **`install.ps1`**: Windows PowerShell installer — full feature parity with install.sh (prerequisites, upgrade detection, version tracking, settings.json merge, CLAUDE.md update, backup import, onboarding)
- **Version tracking**: `~/.claude/cortex/version` file written on every install/upgrade — enables version-aware upgrades
- **hooks/lib/ installation**: `install.sh` and `install.ps1` now install Python modules (`dream_cycle.py`, `validate_instinct.py`) to `~/.claude/hooks/cortex/lib/`
- **CLAUDE.md upgrade**: Installer now replaces the Cortex section on upgrade instead of skipping it, ensuring commands and docs stay current without touching other sections

### Fixed
- **`hooks/session-start.sh`**: Replaced `paste -sd ';'` with `tr '\n' ';'` for Windows Git Bash compatibility
- **`core/claudemd-section.md`**: Added missing `/cx-dream` to commands list (was 11, now 12)
- **`core/memory.template.json`**: Updated version from "2.1.0" to "3.0.0"
- **`install.sh`**: Upgrade now shows version transition (e.g., "v3.0.2 → v3.1.0") instead of generic message

### Changed
- **README.md**: Added Windows install instructions (PowerShell), updated install/update sections with dual-platform commands, removed `--update` flag references (installer is now always smart)
- **`.claude/rules/release-workflow.md`**: Added `install.sh` and `install.ps1` version variables to mandatory release checklist

## [3.0.2] — 2026-04-09

### Changed
- **README.md**: Full update — added version badge from git tags, 12 commands table (added `/cx-dream`), updated learning pipeline diagram, security section, tests section, fixed manual update paths (`hooks/*.sh` instead of `hooks/cortex/*.sh`)
- **`.claude/rules/release-workflow.md`**: Extended checklist — now requires README review, git tag creation, and `git push --tags`

### Added
- **Git tags**: Retroactive annotated tags for all releases (v1.0.0 through v3.0.1)

## [3.0.1] — 2026-04-09

### Added
- **SECURITY.md**: Security policy with vulnerability reporting process, scope definition, and v3.0 security measures summary
- **`.claude/rules/release-workflow.md`**: Claude Code rule enforcing version bump + changelog update before every push to main
- **`githooks/pre-push`**: Git hook that blocks pushes to main without CHANGELOG.md changes and runs all tests automatically
- **`.gitignore`**: Project-level gitignore (`.DS_Store`, `__pycache__/`, `node_modules/`, `*.tmp`, `*.lock`)
- **`install.sh`**: Auto-installs git pre-push hook from `githooks/` directory

## [3.0.0] — 2026-04-09

### Security (CRITICAL)
- **injector.sh**: Sanitize instinct action field against prompt injection — blocks instruction overrides (`ignore`, `forget`, `override`, `system:`, etc.) and strips control chars
- **injector.sh**: Replace `execSync` with `execFileSync` to prevent command injection via malicious `cwd`
- **session-start.sh**: Sanitize `context.md` and EOD resume before injection into context
- **session-start.sh**: Add `umask 077` for consistent file permissions
- **observe.sh**: Expand secret scrubbing from 5 to 12 patterns (GitHub tokens, Stripe keys, Slack, Anthropic, OpenAI, Google API keys, connection strings)
- **observe.sh**: Add perl-based `flock` fallback for macOS (replaces unsafe non-locked append)
- **restore**: Add `validate_instinct.py` — validates imported instincts against prompt injection patterns and universal wildcard triggers

### Security (Hardening)
- **injector.sh**: Add ReDoS protection for instinct trigger patterns — bans nested quantifiers, excessive alternations, enforces length limit
- **observe.sh**: Atomic archive-then-write under single flock guard (fixes race condition)
- **observe.sh**: Per-user dedup directory with auto-cleanup (fixes predictable `/tmp` paths)
- **observe.sh**: Atomic obs-count writes via tmp+rename
- **session-start.sh**: Pass `CORTEX_DIR` via environment variable to avoid path injection in Python heredoc
- **install.sh**: Atomic write for `settings.json` via `tempfile.mkstemp` + `os.replace`
- **injector.sh, session-learner.js**: Add error logging to silent catch blocks (enabled via `CORTEX_DEBUG=1`)

### Added
- **Dream Cycle** (`hooks/lib/dream_cycle.py`): 5-module knowledge maintenance system:
  - Jaccard dedup with Unicode-safe tokenization (fixes Sinapsis CJK bug)
  - Contradiction detection with safe word-boundary pairs EN+ES (fixes Sinapsis `do/don't` false positives)
  - Staleness scoring (0-100) with confidence decay and auto-archive
  - Regex validation for instinct triggers (ReDoS, length, syntax)
  - Health score calculation (0-100) with penalties and bonuses
- **`/cx-dream` command**: Orchestrates all 5 Dream Cycle modules with dry-run support and confirmation gates
- **`tests/test_security.sh`**: 7 security regression tests covering injection, command injection, secret scrubbing, instinct validation
- **`tests/test_dream_cycle.sh`**: 26 Dream Cycle tests (ported from Sinapsis) covering Jaccard, contradictions, staleness, regex, health score

## [2.3.0] — 2026-04-08

### Changed
- **cx-analyze**: Replaced Haiku-per-project with single Opus 1M agent for cross-project analysis:
  - Pre-processes observations: truncates `result` to 200 chars, omits `args.content`/`new_string`/`old_string`
  - Handles up to ~10MB raw observations (compressed to ~3MB for Opus context)
  - Samples 250 most recent per project if compressed exceeds 3MB
  - Agent receives full knowledge summary (laws + instincts + reflexes) to avoid duplicates
  - Single agent sees ALL projects at once for cross-project pattern detection

### Fixed
- Credits: restored correct Everything Claude Code attribution to Affaan Mustafa (affaan-m)

### Added
- README: Update instructions for existing installations (`install.sh --update` or manual copy)

## [2.2.0] — 2026-04-07

### Changed
- **cx-analyze**: Summary now shows a short description (~60 chars) per proposal for instant context
- **cx-validate**: Complete interaction redesign:
  - Claude emits a verdict (RECOMIENDO ACEPTAR/RECHAZAR) with reasoning per proposal
  - Shorthand input system (A/X/S) replaces AskUserQuestion windows
  - Mandatory confirmation gate before writing any files
  - Dynamic scope handling (global vs project paths)
  - Graceful handling of missing proposals.json and invalid shorthand
- **cx-distill**: Stricter law promotion criteria:
  - Universality filter: laws must apply to 3+ projects or be fundamentally universal
  - Compares candidates against existing laws before proposing (max 10 slots)
  - Shorthand input (A/X/M/S) with Claude recommendations
  - Jaccard promotions now have their own shorthand (A=Promote/X=No promote)
  - Confirmation gate before executing any changes
- **cx-evolve**: Skills-aware evolution:
  - Scans existing skills before proposing — detects already/partially covered clusters
  - Manages pending evolved skills from previous runs (I=Install/S=Skip)
  - Shorthand input (A/X/M/O/S) with coverage-aware recommendations
  - Preview/diff required before merging into existing skills
  - Confirmation gate before executing any changes

### Added
- Consistent shorthand system across all interactive commands (base: A/X/S)
- "Confirm before executing" principle enforced in all 4 commands
- Explicit AskUserQuestion prohibition in validate, distill, evolve
- Invalid shorthand handling in all interactive commands

## [2.1.1] — 2026-04-06

### Added
- Semi-automatic maintenance reminders in `session-start.sh`:
  - `/cx-distill` reminder after 7+ days without running
  - `/cx-audit` reminder after 30+ days without running
  - `/cx-validate` reminder when pending proposals exist
- Marker files (`.last-distill`, `.last-audit`) touched by commands after execution

### Changed
- `session-start.sh` v2.2 — added maintenance reminder injection
- `cx-distill.md` — Step 6: touch `.last-distill` marker after completion
- `cx-audit.md` — Step 9: touch `.last-audit` marker after completion

## [2.1.0] — 2026-04-04

### Fixed
- EOD resume no longer repeats in every session. Uses `.eod-last-read` marker so the summary is injected only once per EOD, then skipped in subsequent sessions.

### Changed
- `session-start.sh` v2.1 — added read-once guard for EOD injection.
- Updated README to reflect EOD read-once behavior.

## [2.0.0] — 2026-03-28

Complete rewrite of the Cortex architecture.

### Added
- 4-hook system: `session-start.sh`, `observe.sh`, `injector.sh`, `session-learner.js`
- Dual injection: Laws at SessionStart, instincts+reflexes at PreToolUse
- Continuous confidence scale (0.0–0.95) with decay and Jaccard promotion
- 11 commands: `/cx-status`, `/cx-analyze`, `/cx-distill`, `/cx-validate`, `/cx-evolve`, `/cx-audit`, `/cx-eod`, `/cx-gotcha`, `/cx-export`, `/cx-backup`, `/cx-restore`
- 8 default reflexes (deterministic rules via hooks)
- 3 agents: `cortex-observer` (Opus 1M since v2.3, was Haiku), `cortex-reviewer` (Sonnet x3), `cortex-planner` (Sonnet)
- Project scoping via git remote hash
- Context bridge: `context.md` per project with 14-day TTL
- EOD summaries with Quick Resume injection at session start
- Seed instincts and laws for bootstrapping
- Backup/restore with portable `.tar.gz` archives
- `--git` flag for `/cx-analyze` to mine git history

### Changed
- Observations are now async (0 tokens overhead)
- Instinct injection is confidence-gated (threshold 0.30)
- Laws capped at max 10, one-liners only
- Token budget: ~1,750 tokens/session estimated

## [1.0.0] — 2026-03-25

### Added
- Initial release of fs-cortex
- Basic observation capture and session learning
- EOD resume injection at session start
- Install/uninstall scripts
- Backup and restore functionality
- Parallel 3-agent code review (`cortex-reviewer`)
- Auto-present EOD at session start

### Fixed
- Session-start EOD and law injection
- Memory stats update after learning
- Observe hook timeout handling
- Install script Python heredoc with `set -e`
- Security: injection, path traversal, portability fixes
- Critical backup bug in uninstall
