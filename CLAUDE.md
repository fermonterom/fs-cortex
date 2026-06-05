# fs-cortex — Claude Code Project Context

> `AGENTS.md` is a symlink to this file, so non-Claude agent runtimes
> (opencode, Codex, etc.) read the same project rules. fs-cortex itself is a
> continuous-learning layer **for Claude Code**, but the conventions below are
> tool-agnostic.

## Feature reference

**`docs/FEATURES.md`** is the single source of truth for all features, commands,
hooks, modules, and capabilities of this project. Read it before exploring source
files — it provides a complete inventory and is kept up-to-date with every release.

## Current state

Per-sprint status is **not** tracked in this file. `CHANGELOG.md` is the
authoritative history of what shipped; `docs/FEATURES.md` is the live feature
inventory. This file holds only durable project rules.

## Docs policy

Only `docs/FEATURES.md` is versioned. Everything else under `docs/` (sprint
plans, design notes, audits, métricas, HTML reports) is **local/internal
scratch** the operator keeps for development and is intentionally gitignored —
not part of the public repo. See `.claude/rules/release-workflow.md` §4b.

## Release workflow

All pushes to `main` must follow `.claude/rules/release-workflow.md`:
- Bump version in `install.sh`, `install.ps1`, `CHANGELOG.md`, and `docs/FEATURES.md`
- Write a `CHANGELOG.md` entry (Added / Changed / Fixed / Removed)
- Update `README.md` if commands, hooks, or architecture changed
- Run tests before pushing: `bash tests/test_security.sh && bash tests/test_dream_cycle.sh`
- Create an annotated git tag and push with `--tags`
- **Deploy after merging:** run `bash install.sh` so the live system at
  `~/.claude/hooks/cortex` matches the repo. SessionStart's drift guard warns
  when the deployed version falls behind the source — never let a fix sit
  undeployed.

## Key directories

| Path | Purpose |
|---|---|
| `hooks/` | Claude Code hooks (SessionStart, PreToolUse, Stop) |
| `hooks/lib/` | Shared Python/JS engine libraries |
| `commands/` | Slash command skill files (`/cx-*`) |
| `core/` | Template files copied during install |
| `skills/cortex/` | Installable skill bundle |
| `docs/` | `FEATURES.md` only is tracked; the rest is local/internal scratch |
| `tests/` | Test suites (security, dream cycle, integrity, etc.) |
| `.claude/rules/` | Project-scoped rules injected by Claude Code |
