# fs-cortex — Claude Code Project Context

> `AGENTS.md` is a symlink to this file so non-Claude runtimes (opencode,
> Codex, etc.) read the same rules. fs-cortex is a continuous-learning layer
> for Claude Code — hooks observe sessions, distill patterns into instincts,
> and crystallize proven ones into laws — but the conventions below are
> tool-agnostic.

## Orientation

- **`docs/FEATURES.md`** — single source of truth for every feature, command,
  hook, and module. Read it before exploring source.
- **`CHANGELOG.md`** — what shipped and when. This file never tracks per-sprint
  status or version numbers; the changelog owns that history.

## Docs policy

Only `docs/FEATURES.md` is versioned. Everything else under `docs/` (sprint
plans, design notes, audits, métricas, HTML reports) is local/internal scratch
the operator keeps for development and is gitignored — not part of the public
repo. See `.claude/rules/release-workflow.md` §4b.

## Architecture

Pipeline: **observe** (PostToolUse) → **learn** (Stop) → **inject** (laws at
SessionStart + instincts/reflexes at PreToolUse). Engine is Python + Node;
data lives under `~/.claude/cortex/` as JSON/JSONL, `.txt` laws, `.yaml`
instincts.

| Path | Purpose |
|---|---|
| `hooks/` | Hooks: SessionStart, PreToolUse, PostToolUse, Stop |
| `hooks/lib/` | Shared Python/JS engine (distill, inject, dream) |
| `commands/` | `/cx-*` slash command definitions |
| `core/` | Templates copied into `~/.claude/cortex/` at install |
| `skills/cortex/` | Installable skill bundle |
| `tests/` | Suites; run one with `bash tests/<name>.sh` |
| `.claude/rules/` | Project rules injected by Claude Code |

## Working rules

- **Edit the repo, never the live install.** All code changes go to the repo
  first; only YAML/data files under `~/.claude/cortex/` are edited in place.
- **Deploy after merging:** run `bash install.sh` so the live system at
  `~/.claude/hooks/cortex` matches the repo. SessionStart's drift guard warns
  when the deployed version falls behind — never let a fix sit undeployed.
- **Releases** follow `.claude/rules/release-workflow.md`: bump version
  (`install.sh`, `install.ps1`, `CHANGELOG.md`, `docs/FEATURES.md`), add a
  CHANGELOG entry, update `README.md` if surface changed, run the suite (the
  pre-push hook gates integrity + security), tag annotated, push with `--tags`.
