# fs-cortex — Claude Code Project Context

## Feature reference

**`docs/FEATURES.md`** is the single source of truth for all features, commands,
hooks, modules, and capabilities of this project. Read it before exploring source
files — it provides a complete inventory and is kept up-to-date with every release.

## Active sprint

**Sprint 9 SHIPPED in v3.32.0 (PR1 v3.31.2 + PR2 v3.32.0).** Next:
7 days of silent observation before planning v3.33+.
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

Tests baseline: 456 (v3.31.2) → 471 PASS, 28 suites.

**Deferred to v3.33+ (AD P0-2/P0-3 absorbed):** §4.2 `analyze_engine.py`
+ §4.3 auto-analyze trigger in SessionStart. The queue-only design
contradicted the "autopilot real" promise and Opus 1M detection from a
hook is not testable. Redesign post-7d-data of `auto-validate-skips.jsonl`
with explicit `CORTEX_OPUS_1M=1` env var, not hook inference. Also
deferred: deletion of `docs/SPRINT-8-*.md` / `GHOST-*.md` /
`SINAPSIS-*.md` per Sprint 9 Q5 (mantener until v3.33+).

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
