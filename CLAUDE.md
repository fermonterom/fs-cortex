# fs-cortex — Claude Code Project Context

## Feature reference

**`docs/FEATURES.md`** is the single source of truth for all features, commands,
hooks, modules, and capabilities of this project. Read it before exploring source
files — it provides a complete inventory and is kept up-to-date with every release.

## Pending validation

**`docs/SPRINT-5-PENDING-GATES.md`** — Gate 2 was prematurely closed in
v3.22.2 and reopened in v3.23.3 alongside Gate 1. Both depend on a fresh
measurement window starting **2026-05-02** (v3.23.3 fixed two regex bugs
in the bash-cat/bash-grep/bash-find matchers that caused 306 lost fires
across 6 days). Estimate: enough data by 2026-05-09. Gate 3 remains
dropped (no reconstructible baseline). Delete this file when Gate 1+2
both PASS with fresh post-v3.23.3 data.

**`docs/V3.27-DETECTOR-GATES.md`** — 5 gates (A-E) measuring whether the 3
new v3.27.0 detectors (`detectAgentSubtypes`, `detectFileCoupling`,
`detectTimeOfDayPatterns`) and v3.26.0's `applyCrossDayBoost` produce
useful signal vs noise with the chosen thresholds (3 uses + 30% errors,
5 sessions, etc.). Measurement window starts 2026-05-09 (v3.27.0
install). Re-check **2026-05-11 (Monday)**: run the bash one-liners in
each gate to see PASS/FAIL/PENDING. Adjust thresholds if FAIL, delete
the file when all gates PASS.

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
