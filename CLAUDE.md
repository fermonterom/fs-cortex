# fs-cortex — Claude Code Project Context

## Feature reference

**`docs/FEATURES.md`** is the single source of truth for all features, commands,
hooks, modules, and capabilities of this project. Read it before exploring source
files — it provides a complete inventory and is kept up-to-date with every release.

## Active sprint

**`docs/SPRINT-8-DETECTOR-OVERHAUL.md`** — full overhaul of the
session-learner detector pipeline. v3.28.9 (this release) gates the 5
noisy detectors behind `CORTEX_LEGACY_DETECTORS=1` (default OFF), fixes
the Gate 1 metric in `impact_log.py`, and closes Sprint 5 + the v3.27
gates. Sprint 8 (v3.29.x) will rewrite the disabled detectors with valid
triggers / actions / domains and wire end-to-end automation so the
operator never has to run `/cx-analyze` `/cx-validate` `/cx-distill`
`/cx-evolve` manually again.

**`docs/V3.27-GATES-CLOSED.md`** — closure record. Kept for history,
delete at end of Sprint 8.

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
