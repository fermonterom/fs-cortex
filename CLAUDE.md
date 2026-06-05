# fs-cortex — Claude Code Project Context

## Feature reference

**`docs/FEATURES.md`** is the single source of truth for all features, commands,
hooks, modules, and capabilities of this project. Read it before exploring source
files — it provides a complete inventory and is kept up-to-date with every release.

## Active sprint

**v3.34.2 SHIPPED — Cortex deep-fix session (2026-06-05).** A live deep
audit exposed the root cause of months of "Cortex a medias": repo edits
were never deployed (`install.sh` not run), so the live system ran stale
code — which silently re-promoted demoted laws. Fixed end-to-end across
5 PRs (#51–55):
- **v3.33.1**: `max_laws` config desync (10→15) + Core/Domain law-split design.
- **v3.34.0**: `demote_law_to_domain` + `/cx-distill --demote` (split Phase 2).
- **v3.34.1**: **anti-drift guard** (`session-start.py:check_deploy_drift` warns
  when deployed < repo via `~/.claude/cortex/.repo-path`) — the root-cause fix —
  plus noise pruning (`noisy_detectors_off` gates correction/coupling detectors).
- **v3.34.2**: **universality opt-in** (Criteria 8): `auto_promote_to_law` only
  auto-promotes instincts with `law_eligible: true`; everything else routes to
  candidates for human review (`/cx-distill`), stopping silent Core inflation.
Live system curated (reversible, backup in `/tmp/cortex-pre-deploy-*`): 15→12
Core laws, 25→15 reflexes, 363→84 proposals, 171→116 instincts, 329→228
tracking. Deployed + in sync. Residual hygiene (low, criteria-gated) tracked
in issue #56. Design: `docs/DESIGN-LAW-INJECTION-V2.md`. Tests: all suites
green (incl. `test_deploy_drift` 6, `test_distill_engine` 49, `test_kill_switches` 12).

**Prior: Sprint 9 SHIPPED in v3.32.0 (PR1 v3.31.2 + PR2 v3.32.0).**
`docs/SPRINT-9-AUTOPILOT.md` v3 FINAL (AD Codex GPT-5.5 round 1
absorbed: 4 P0 + 7 P1 + 3 P2 findings) tracks both PRs.

PR1 — v3.31.2 (shipped 2026-05-26): three cleanup bug fixes, no
detector signal changes. §4.1.A grandfather narrow to `sessions == []`
explicit (AD P1-1), §4.1.B `auto_validate_proposals` skip_breakdown
logging to `~/.claude/cortex/log/auto-validate-skips.jsonl` (AD P1-4),
§4.1.C weekly `proposals.json.bak*` archive wired into `/cx-dream`
via `dream_cycle.archive_proposals_backups_if_due` (B4). Tests delta:
+9 (7 distill + 2 dream).

PR2 — v3.32.0 (shipped 2026-05-27):
- §4.4 promotion gate `HUMAN → AUTO`: `can_promote_to_auto(source)`
  with 4 statistical gates (n ≥ 20 reviewed + accept_rate ≥ 70 % +
  distinct_sessions ≥ 3 + critical_count == 0) reading
  `proposals-history.jsonl` (AD P0-1). n=10 visibility tier (AD P1-2).
  Fail-closed `.promoted-detectors.json` written ONLY via
  `manual_promote_detector` (AD P0-4). `rejection_category` enum +
  ES/EN fallback (AD P1-6).
- §4.5 `LAW_MAX_ACTIVE` 12 → 15 (token cost ~480 → ~600). Deprecation
  policy via `_find_least_impactful_law` with age guard
  `LAW_DEPRECATE_MIN_AGE_DAYS=7` (AD P1-3) and `/cx-distill --swap
  <old> <new> --confirm` with `manual_swap_promote` in-memory
  rollback (AD P1-7).
- §4.7 / AD P1-5: `git mv test_v329_acceptance.sh → test_v332_acceptance.sh`
  + 2 new e2e asserts (marker fail-closed + full promotion cycle).
  Assert 10 surfaced + fixed a second-skip bug in `auto_validate_proposals`
  that the per-function unit tests had missed — concrete validation
  of instinct gotcha-ad-por-fase-no-sustituye-e2e.

**PR #44 review quick wins (e292568 + ae1d9fd, on the same release
branch before merge):** preserve corrupted `.promoted-detectors.json`
via rename-archive (new `_archive_corrupted_marker` helper);
README.md commands table mentions the new `--auto` / `--swap`
sub-modes; +4 tests covering the new paths.

Tests baseline: 456 (v3.31.2) → 472 (v3.32.0 release) → **476 PASS,
28 suites** (incl. PR #44 quick wins).

**Next: v3.33+ planning.** See `docs/SPRINT-V3.33-PLAN.md` DRAFT for
the full backlog. 7-day silent observation window 2026-05-27 →
2026-06-03 to answer Q1-Q6 from real data before re-planning.

**Follow-up issues opened post-review (v3.33+):**
[#45](https://github.com/fermonterom/fs-cortex/issues/45) LOCK_FILE
concurrency wrap for `manual_promote_detector` + `manual_swap_promote`;
[#46](https://github.com/fermonterom/fs-cortex/issues/46) regression
test for future schema v2;
[#47](https://github.com/fermonterom/fs-cortex/issues/47) chmod 0o600
on `~/.claude/cortex/log/*.jsonl`;
[#48](https://github.com/fermonterom/fs-cortex/issues/48) trust-boundary
doc in cx-promote / cx-distill.

**Deferred to v3.33+ (AD P0-2/P0-3 absorbed):** §4.2 `analyze_engine.py`
+ §4.3 auto-analyze trigger in SessionStart. The queue-only design
contradicted the "autopilot real" promise and Opus 1M detection from a
hook is not testable. Redesign post-7d-data of `auto-validate-skips.jsonl`
with explicit `CORTEX_OPUS_1M=1` env var, not hook inference. Also
deferred: deletion of `docs/SPRINT-8-*.md` / `GHOST-*.md` /
`SINAPSIS-*.md` / `SPRINT-9-AUTOPILOT.md` / `SPRINT-V3.33-PLAN.md` per
Sprint 9 Q5 (mantener until v3.33+ retro closes).

Sprint 8 invariants protected since v3.29.0: 5 detectors live by
default, 3 HUMAN-gated via `VALIDATE_HUMAN_DOMAINS` (and now
optionally upgradeable to AUTO via the v3.32.0 promotion gate);
ghost guard preventive; 3 kill switches scoped by state-file
(`CORTEX_OBSERVE_OFF`, `CORTEX_DETECTORS_OFF`, `CORTEX_AUTODISTILL_OFF`);
multi-session promotion gate (≥ 3 distinct sessions) with the
v3.31.2-narrowed grandfather clause; pre-ship acceptance gate
(`test_v332_acceptance.sh`) wired into `.githooks/pre-push`.

## Release workflow

All pushes to `main` must follow `.claude/rules/release-workflow.md`:
- Bump version in `install.sh`, `install.ps1`, `CHANGELOG.md`, and `docs/FEATURES.md`
- Write a `CHANGELOG.md` entry (Added / Changed / Fixed / Removed)
- Update `README.md` if commands, hooks, or architecture changed
- Run tests before pushing: `bash tests/test_security.sh && bash tests/test_dream_cycle.sh`
- Create an annotated git tag and push with `--tags`

## Key directories

| Path | Purpose |
|---|---|
| `hooks/` | Claude Code hooks (SessionStart, PreToolUse, Stop) |
| `hooks/lib/` | Shared Python/JS engine libraries |
| `commands/` | Slash command skill files (`/cx-*`) |
| `skills/cortex/` | Installable skill bundle |
| `core/` | Template files copied during install |
| `docs/` | Feature inventory and visual explainer |
| `tests/` | Test suites (security, dream cycle) |
| `.claude/rules/` | Project-scoped rules injected by Claude Code |
