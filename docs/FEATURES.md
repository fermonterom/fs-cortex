# fs-cortex v3.11.1 — Feature Reference

> Complete inventory of all features, commands, hooks, modules, and capabilities.
> Last updated: 2026-04-12

---

## Architecture Overview

fs-cortex is a continuous learning system for Claude Code that observes sessions, detects patterns, and crystallizes them into reusable knowledge — automatically.

### Knowledge Pipeline

```
OBSERVATIONS  →  PROPOSALS  →  INSTINCTS  →  LAWS
(JSONL, async)   (pending)     (YAML, 0.30+)  (TXT, 0.90+)
  observe.py      cx-analyze    cx-validate     cx-distill
                                      ↓
                               SKILLS / COMMANDS / RULES / AGENTS
                                         (evolved/)
                                          cx-evolve
```

Parallel systems (not part of the confidence pipeline):
- **Reflexes** (10 default) — deterministic rules, always fire on matcher
- **Agents** (3) — specialized for pattern analysis, code review, and task planning

### Dual Injection Architecture

| Injection Point | What | When | Tokens |
|---|---|---|---|
| **SessionStart** | Laws + EOD resume + context bridge + skills hint + reminders | Once per session (+ on /compact) | ~550 |
| **PreToolUse** | Instincts (max 3) + Reflexes (max 2) | Every tool use (if trigger matches) | ~200 max |

### 4-Hook Pipeline

| Hook | File | Event | Mode | Timeout |
|---|---|---|---|---|
| Observer | `observe.py` | Pre/PostToolUse | Async (0 tokens) | 10s |
| Injector | `injector.sh` | PreToolUse | Sync | 3s |
| Session Start | `session-start.py` | SessionStart + /compact | Sync | 5s |
| Session Learner | `session-learner.js` | Stop | Sync | 15s |

---

## Hooks (5 files)

### observe.py — Observation Capture
- **Single Python process** replacing 11 shell spawns (~70ms vs ~800ms)
- Captures ALL tool uses as JSONL with short field names (ts, ev, tool, err, sid, pid, pname)
- **12 secret scrubbing patterns**: API keys, JWT, PEM, SSH, AWS, GitHub, Stripe, connection strings, Google, Slack, Anthropic, OpenAI
- **9 error detection patterns** with context anchors: `error[:\s]` (not `ErrorBoundary`), `failed(?!\s*:\s*0)` (not `failed: 0`), exception, traceback, fatal, `panic[:(]` (not Go `panic()`), segfault, OOM, command not found
- **is_error flag** on each observation for downstream pattern detection
- Session ID truncated to 24 chars (not 16) for collision avoidance
- File-based project ID cache (5min TTL) — avoids git subprocess per tool use
- Conditional registry.json write — skips when project metadata unchanged
- Per-user dedup directory with auto-cleanup (24h)
- Auto-archive at configurable MB threshold (default 10MB)
- Auto-purge archived observations older than N days (default 30)
- Watchdog: alerts on FATAL/OOM/segfault in output
- Observation count trigger: marks `.learn-pending` at 50 observations
- Config read from `memory.json` (max_observations_mb, archive_days, learn_threshold)
- Cross-platform file locking (fcntl on Unix, msvcrt on Windows)
- `CORTEX-MANAGED` marker for reliable detection during upgrades

### injector.sh — Real-time Instinct Injection
- **Imports shared `yaml-utils.js`** for YAML parsing (eliminates inline parser drift risk)
- **Domain pre-filter**: detects project stack (React, Node, Supabase, Python, Rust, Go) from package.json/config files, skips irrelevant instincts
- **Occurrence tracking**: writes `instinct-tracking.json` with activation count, session list, first/last seen
- **Draft auto-promote**: tracks ALL instinct matches (including confidence < 0.30); auto-promotes drafts to 0.35 after 5+ activations across 3+ sessions
- **Token budget cap**: per-session budget (8000 tokens); skips instinct injection when exceeded; reflexes always pass (safety exempt)
- **Max 3 instincts** per injection, 500 chars each, 1500 chars total
- **sanitizeInjection()**: blocks 10 prompt injection keywords, strips control chars, enforces length limit
- **isSafeRegex()**: ReDoS protection — bans nested quantifiers, >5 alternations, >100 chars, timing test
- Uses `execFileSync` (not `execSync`) for command injection prevention
- Hook payload via temp file (not env var) for security
- Project root detection with fallback to cwd hash when no `origin` remote

### session-start.sh — Session Initialization
- Injects Laws (max 10) from `~/.claude/cortex/laws/*.txt`
- Lightweight skills hint (~50 tokens) listing all `/cx-*` commands
- EOD resume injection (read-once via `.eod-last-read` marker)
- Context bridge from project `context.md` (14-day TTL)
- Maintenance reminders: /cx-distill (7d), /cx-audit (30d), /cx-validate (pending proposals)
- **Token budget reset** at session start (prevents silent accumulation across sessions)
- Cross-platform date handling (macOS BSD + GNU Linux)
- CWD validation: absolute path check, path traversal guard (`..`), symlink resolution via `pwd -P`
- Sanitization of all injected text (whitespace normalization, blocked phrases)
- CONTEXT passed via env var (not shell argument) to prevent backslash corruption
- `set -euo pipefail` strict mode (with safe fallbacks for optional variables)
- `umask 077` for consistent file permissions
- `CORTEX-MANAGED` marker

### session-learner.js — Pattern Detection at Session End
- **5 pattern detectors**:
  1. Error-fix pairs (is_error flag → Edit/Write within 10-event window)
  2. Repetitions (same tool+input 5+ times)
  3. User corrections (same file edited 3+ times with overlapping regions — reduces false positives)
  4. Workflow chains (3-tool trigrams repeated 3+ times)
  5. Agent patterns (recurring Agent tool usage with similar descriptions, Jaccard >= 0.40, 3+ uses → agent-evolution proposals)
- **sanitizeProposalAction()**: sanitizes all proposal text against prompt injection
- Auto-generates proposals with `session_date` for cross-day tracking
- Preserves user validation status (approved/rejected) on proposal dedup
- Updates instinct `last_seen` and `occurrences` in YAML files
- Updates reflex `fireCount` and `lastFired`
- Writes `context.md` per project for session bridge
- Dynamic `now()` timestamps (not stale static NOW)
- readStdin with proper timeout cleanup
- ReDoS guard on instinct/reflex regex compilation
- **512KB log rotation** (renames to `.1` when threshold exceeded)
- Imports shared YAML parser from `hooks/lib/yaml-utils.js`
- Exports functions for testability via `require.main` guard
- **Error patterns aligned** with observe.py (9 + ENOENT/EACCES/EPERM)

### observe.py — Observer (direct invocation, no wrapper)
- 12-line bash wrapper that delegates to `observe.py`
- Detects python3/python automatically
- Supports `CORTEX_PYTHON` env var override

---

## Library Modules (3 files)

### hooks/lib/dream_cycle.py — Knowledge Maintenance
5 modules for knowledge hygiene:
1. **Jaccard dedup**: Unicode-safe tokenization (word boundaries + CJK characters), configurable threshold (default 0.80), **full pairwise comparison** (checks against ALL kept items, not just first match)
2. **Contradiction detection**: 7 antonym pairs (EN: must/must not, always/never, enable/disable, allow/block, require/forbid; ES: siempre/nunca, permitir/prohibir). Same-domain only. No false positives on "document"/"domain"
3. **Staleness scoring**: 0-100 based on age since last_seen (7d=0, 30d=30, 60d=60, 90d+=90+). Auto-archive at threshold (default 90). **Linear confidence decay**: -0.05 per 30 days (matches cx-distill and documented config)
4. **Regex validation**: length limit (100), nested quantifier ban (ReDoS), alternation limit (5), compile test
5. **Health score**: 0-100 with penalties (staleness -2/instinct, contradictions -10/pair, duplicates -3) and bonuses (laws +2, confidence +5)

### hooks/lib/validate_instinct.py — Import Security
- Validates instinct YAML files against 3 blocked injection patterns
- **Handles YAML multiline values** (`|` and `>`) — validates the full reconstructed action, not just the `action:` line
- Checks action field length (max 500 chars)
- Rejects universal wildcard triggers (`.*`, `.+`, etc.)

### hooks/lib/yaml-utils.js — Shared YAML Parser
- Unified `parseYamlFrontmatter()` with correct `parseFloat` for confidence values
- `updateYamlField()` for atomic YAML field updates
- `listYamlFiles()` for directory scanning
- Shared between injector.sh and session-learner.js (eliminates duplication)

---

## Commands (17)

| Command | Purpose | Token Cost |
|---|---|---|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, tracking, health, domain grouping | ~200 |
| `/cx-analyze` | Detect patterns in observations → proposals (Opus 1M agent) | ~5K |
| `/cx-distill` | Promote instincts to laws (0.90+), apply decay, Jaccard promotions | ~800 |
| `/cx-validate` | Review and accept/reject proposals interactively (shorthand UX) | ~500 |
| `/cx-evolve` | Cluster mature instincts → skills/commands/rules/agents | ~1K |
| `/cx-dream` | Dream Cycle: dedup, contradictions, staleness, regex, health score | ~600 |
| `/cx-router` | Command catalog with token costs, session budget estimate, next action | ~50 |
| `/cx-promote` | Cross-project instinct promotion (Jaccard ≥0.70, 2+ projects) | ~300 |
| `/cx-audit` | Token overhead, duplicates, conflicts, cleanup | ~400 |
| `/cx-eod` | End-of-day summary for next session | ~300 |
| `/cx-gotcha` | Capture error→fix as high-priority instinct | ~200 |
| `/cx-downvote` | Negative feedback on incorrect instinct injection (reduces confidence) | ~100 |
| `/cx-retro` | Weekly retrospective: command usage, instinct activations, health trend | ~200 |
| `/cx-timeline` | Knowledge event log: creations, promotions, decays, archives, evolutions | ~100 |
| `/cx-export` | Generate portable skill for Claude.ai or sharing | ~500 |
| `/cx-backup` | Create portable .tar.gz backup for machine transfer | ~100 |
| `/cx-restore` | Import knowledge from backup archive | ~200 |

### Interactive Shorthand System
All interactive commands use consistent shorthand (no modal dialogs):
- **A** = Accept/Promote
- **X** = Reject
- **S** = Skip (review later)
- **M** = Merge
- **O** = Omit (already covered)
- **I** = Install (pending skill)

### Learning Pipeline
```
/cx-analyze → /cx-validate → /cx-distill → /cx-evolve → /cx-dream → /cx-audit
 detect        confirm        laws+decay     skills        dedup       cleanup
 patterns      or reject      +promotions    commands      contradictions
                                             rules         staleness
```

---

## Agents (3)

| Agent | Model | Purpose |
|---|---|---|
| `cortex-observer` | Opus 1M | Detect patterns in observations (cross-project, full context) |
| `cortex-reviewer` | Sonnet x3 parallel | Code review: security + quality + correctness |
| `cortex-planner` | Sonnet | Decompose complex tasks into steps |

---

## Confidence Lifecycle

| Range | Label | Injection | Behavior |
|---|---|---|---|
| 0.00–0.29 | Draft | Not injected | Tracked for auto-promote (5+ activations → 0.35) |
| 0.30–0.49 | Hypothesis | On trigger match | Requires strong trigger match |
| 0.50–0.69 | Pattern | On trigger match | Regular injection |
| 0.70–0.89 | Instinct | Automatic | Promotion candidate |
| 0.90–0.95 | Law | Always (SessionStart) | Auto-distilled one-liner, capped at 0.95 |

**Inline staleness**: instincts not seen in 60+ days are skipped at injection time (read-only, no file writes). Immediate effect without manual `/cx-dream`.
**Decay**: linear -0.05 per 30 days via Dream Cycle (e.g., 0.80 confidence after 60 days → 0.70). 90-day stale instincts auto-archive.
**Promotion**: Jaccard similarity ≥0.70 + 2 projects + avg confidence ≥0.60 → global via `/cx-promote`.
**Draft auto-promote**: 5+ trigger matches across 3+ sessions → confidence bumped to 0.35.
**Downvote**: `/cx-downvote` records negative feedback. 30%+ rejection rate → confidence reduced. Below 0.10 → auto-archive.

---

## Reflexes (10 default)

Deterministic rules via hooks — not probabilistic instructions. Triggers are regex patterns.

| Reflex | Trigger | Action |
|---|---|---|
| `read-before-edit` | Edit/Write | Verify file was Read first |
| `env-never-commit` | git add/commit | Check .env in .gitignore |
| `test-after-change` | Edit route.ts/component | Suggest running tests |
| `git-commit-quality` | git commit | Verify tests, lint, conventional format |
| `git-push-safety` | git push / gh pr create | Fetch+rebase, --force-with-lease |
| `git-merge-verify` | gh pr merge | Verify checks, clean up branch |
| `api-auth-check` | Edit route.ts/api/ | Validate authentication |
| `security-headers` | Edit vercel.json/next.config | Verify security headers |

---

## Security Features

- **Prompt injection sanitization** on all injected text (10 blocked keywords + control char stripping)
- **Command injection prevention** (`execFileSync` instead of `execSync`)
- **12-pattern secret scrubbing** on all observations
- **ReDoS protection** on all regex compilation (isSafeRegex)
- **Instinct validation** on import (blocked patterns, action length, wildcard rejection)
- **Atomic file writes** everywhere (tmp+rename pattern)
- **File locking** (fcntl/perl/msvcrt cross-platform)
- **Per-user isolation** (dedup dirs with 0o700, umask 077)
- **Path traversal protection** on backup archive extraction (install.sh + install.ps1)
- **Token budget cap** (8000/session, reflexes exempt, **reset at session start**)
- **HOME validation** in injector (refuses to run with spoofed $HOME)
- **CWD validation** in session-start (absolute path, no `..`, symlink resolution)
- **Hook payload via temp file** (not env var, not visible in /proc)
- **CORTEX-MANAGED markers** on all hooks for reliable detection
- **CLAUDE.md backup** before modification during upgrades

---

## Installer (install.sh + install.ps1)

### Cross-Platform
- **Bash** (macOS/Linux): `bash install.sh`
- **PowerShell** (Windows): `powershell -ExecutionPolicy Bypass -File install.ps1`

### Smart Upgrade
- Version detection via `~/.claude/cortex/version`
- Shows upgrade path (e.g., "v3.0.0 → v3.6.0")
- Preserves ALL user data: laws, instincts, memory.json, reflexes.json, proposals, observations, projects
- CLAUDE.md section replacement (exact heading match, backup before edit)
- settings.json hook merge (removes old cortex hooks, preserves others)
- Path traversal validation on backup archive import (both bash and PowerShell)
- **install.ps1**: All 8 backup categories imported (laws, instincts, memory, reflexes, registry, project instincts, evolved, daily-summaries)
- **install.ps1**: chmod 600 on settings.json, atomic memory.json write

### Uninstaller (uninstall.sh)
- Portable backup creation (`.tar.gz`) before uninstall (default: yes)
- **Safety guard**: requires typing `DELETE` to confirm data deletion without backup
- Removes hooks, skill, commands, settings.json hooks, and CLAUDE.md Cortex section
- **Preserves user CLAUDE.md content** — only removes `## Cortex` section
- Removes empty CLAUDE.md if it was Cortex-only (clean uninstall)
- Atomic write for settings.json cleanup
- Data directory preserved by default (opt-in deletion)

### What Gets Updated
- Hooks (5 files + lib/ directory)
- Commands (17 .md files)
- SKILL.md + agents
- Cortex section in CLAUDE.md
- Version marker
- Git pre-push hook (in repo context)

---

## Tests (11 suites, 155 tests)

| Suite | Tests | Coverage |
|---|---|---|
| `test_security.sh` | 7 | Injection, command injection, scrubbing, validation |
| `test_dream_cycle.sh` | 26 | Jaccard, contradictions, staleness, regex, health, **decay formula consistency** |
| `test_observe.sh` | 8 | Scrubbing, is_error, dedup, atomic write, e2e, perf, subagent capture |
| `test_session_learner.sh` | 8 | Error-fix pairs, corrections, chains, proposals, command timeline |
| `test_injector.sh` | 16 | Sanitization, ReDoS, limits, markers, yaml-utils, .last-instinct, engine |
| `test_yaml_utils.sh` | 13 | Floats, ints, strings, colon values, update, list |
| `test_install.sh` | 38 | Fresh install, upgrade, idempotency, path traversal |
| `test_hooks_e2e.sh` | 14 | Full pipeline: observe→inject→learn, **token budget reset** |
| `test_uninstall.sh` | 11 | Cleanup, backup creation, data preservation, **safety guard**, CLAUDE.md preservation |
| `test_integrity.sh` | 14 | observe.py direct, 17 commands validated, core file schemas, **version consistency** |
| `test_install_ps1.ps1` | 9 | PowerShell syntax, version consistency, security features, backup categories, hook config, **CI on windows-latest** |

### CI
- GitHub Actions: macOS + Linux × Python 3.11/3.13 × Node 22/24
- ShellCheck (--severity=error, includes uninstall.sh) + flake8 (critical errors only)
- `fail-fast: false` for full matrix coverage
- Test summary step via `run_all.sh`
- Pre-push hook runs security + dream tests locally

---

## Data Directory Structure

```
~/.claude/cortex/
├── version                    # Installed version (e.g., "3.6.0")
├── memory.json                # Identity + config + stats
├── reflexes.json              # 8 deterministic rules
├── proposals.json             # Pending proposals from learner + cx-analyze
├── instinct-tracking.json     # Activation stats per instinct
├── .session-token-budget      # Per-session token counter
├── .obs-count                 # Observation counter (triggers at 50)
├── .learn-pending             # Marker: run /cx-analyze
├── .last-distill              # Timestamp of last cx-distill
├── .last-audit                # Timestamp of last cx-audit
├── .last-session-date         # Last session date
├── .eod-last-read             # EOD read-once guard
├── laws/                      # One-liners (max 10 active)
│   ├── *.txt
│   └── archive/
├── instincts/
│   ├── global/                # Cross-project instincts
│   └── archive/               # Decayed/archived instincts
├── projects/
│   ├── registry.json          # All known projects
│   └── {sha256hash}/
│       ├── observations.jsonl
│       ├── observations.archive/
│       ├── context.md          # Session bridge (14d TTL)
│       └── instincts/          # Project-scoped instincts
├── evolved/
│   ├── skills/
│   ├── commands/
│   ├── rules/
│   └── agents/
├── knowledge-log.md             # Append-only knowledge event timeline
├── daily-summaries/            # EOD summaries (*.md)
├── exports/                    # Portable skills
└── log/                        # Session learner logs
```

---

## Token Budget

| Component | Tokens | When |
|---|---|---|
| Laws (max 10) | ~400 | SessionStart (1x) |
| Skills hint | ~50 | SessionStart (1x) |
| EOD resume | ~150 | SessionStart (1x, read-once) |
| Context bridge | ~100 | SessionStart (1x) |
| Instincts (max 3) | ~120 | PreToolUse (if match) |
| Reflexes (max 2) | ~40 | PreToolUse (if match) |
| **Session total** | **~2,400** | **Estimated for 50 tool uses** |
| **Budget cap** | **8,000** | **Instincts skipped when exceeded** |

---

## Version History

| Version | Date | Highlights |
|---|---|---|
| v1.0.0 | 2026-03-25 | Initial release |
| v2.0.0 | 2026-03-28 | Complete rewrite: 4-hook system, 11 commands |
| v3.0.0 | 2026-04-09 | Security fixes (6 vulns), Dream Cycle, 33 tests |
| v3.1.0 | 2026-04-09 | Cross-platform installer, smart upgrade, version tracking |
| v3.2.0 | 2026-04-09 | Observer Python rewrite, smart learner, CI |
| v3.3.0 | 2026-04-09 | Security hardening, logic fixes, perf cache |
| v3.4.0 | 2026-04-09 | yaml-utils, cx-router, cx-promote, tracking UX |
| v3.5.0 | 2026-04-09 | Draft auto-promote, token budget, path traversal |
| v3.6.0 | 2026-04-09 | Full test coverage (124 tests, 8 suites), lib/*.js fix |
| v3.6.1 | 2026-04-09 | SECURITY.md update |
| v3.6.2 | 2026-04-10 | 25 audit fixes: security hardening, logic bugs, Windows parity, architecture sync |
| v3.6.3 | 2026-04-10 | 150 tests (10 suites), uninstall safety guard, integrity tests |
| v3.6.4 | 2026-04-10 | FEATURES.md public in git, internal docs untracked |
| v3.6.5 | 2026-04-10 | PowerShell test suite (9 tests), CI windows-latest job |
| v3.6.6 | 2026-04-10 | Usage Guide in README, visual HTML explainer, docs cleanup |
| v3.7.0 | 2026-04-10 | Agent evolution: cx-evolve generates agents, session-learner detects Agent patterns |
| v3.10.7 | 2026-04-12 | CLAUDE.md added — project context, FEATURES.md reference, release workflow summary |
| v3.11.0 | 2026-04-12 | cx-timeline command, knowledge-log.md event log, cx-status domain grouping |
