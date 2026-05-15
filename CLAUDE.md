# fs-cortex — Claude Code Project Context

## Feature reference

**`docs/FEATURES.md`** is the single source of truth for all features, commands,
hooks, modules, and capabilities of this project. Read it before exploring source
files — it provides a complete inventory and is kept up-to-date with every release.

## Active sprint

**Sprint 8 shipped in v3.29.0.** `docs/SPRINT-8-DETECTOR-OVERHAUL.md`
(plan v7 final, kept until v3.30 ships) tracks the next phase:

- 7 days of silent observation post-v3.29.0 before planning v3.30.0
- v3.30.0 candidates: `analyze_engine.py` (Option C — no-op without Opus
  1M), auto-analyze trigger in SessionStart, statistical promotion gate
  `HUMAN → AUTO` (n ≥ 20 reviewed + accept_rate ≥ 70% + distinct_sessions
  ≥ 3 + 0 critical rejections)
- All 5 detectors live by default, 3 of them HUMAN-gated through
  `VALIDATE_HUMAN_DOMAINS`; ghost guard preventive; 3 kill switches
  scoped by state-file (`CORTEX_OBSERVE_OFF`, `CORTEX_DETECTORS_OFF`,
  `CORTEX_AUTODISTILL_OFF`); multi-session promotion gate (≥ 3 distinct
  sessions) with grandfather clause; pre-ship acceptance gate wired into
  `.githooks/pre-push`.

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
