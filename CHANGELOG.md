# Changelog

All notable changes to fs-cortex will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
