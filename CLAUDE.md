# fs-cortex — Claude Code Project Context

## Feature reference

**`docs/FEATURES.md`** is the single source of truth for all features, commands,
hooks, modules, and capabilities of this project. Read it before exploring source
files — it provides a complete inventory and is kept up-to-date with every release.

## Pending review

**Read `docs/REVIEW-QUEUE.md` at the start of every session.** It tracks
time-bound items, process improvements, and ideas that should not depend
on operator memory. Update or remove entries as they are resolved.

Currently load-bearing:

- **`docs/SPRINT-5-PENDING-GATES.md`** — Gates 1+2 already pass on data
  (2026-05-06) but formal close is held to **2026-05-09** to honour the
  agreed 7-day clean window. After 2026-05-09: re-run the evaluators
  inside the file, then delete it and remove this bullet.

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
