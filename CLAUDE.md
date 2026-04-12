# fs-cortex — Claude Code Project Context

## Feature reference

**`docs/FEATURES.md`** is the single source of truth for all features, commands,
hooks, modules, and capabilities of this project. Read it before exploring source
files — it provides a complete inventory and is kept up-to-date with every release.

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
