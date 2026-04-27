# Changelog

All notable changes to fs-cortex will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
