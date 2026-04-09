# Changelog

All notable changes to fs-cortex will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
