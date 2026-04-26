# fs-cortex v3.20.0 — Feature Reference

> Complete inventory of all features, commands, hooks, modules, and capabilities.
> Last updated: 2026-04-26

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

### 5-Hook Pipeline (PreCompact added in v3.15.0)

| Hook | File | Event | Mode | Timeout |
|---|---|---|---|---|
| Observer | `observe.py` | Pre/PostToolUse | Async (0 tokens) | 10s |
| Injector | `injector.sh` / `injector.js` | PreToolUse | Sync | 3s |
| Session Start | `session-start.py` | SessionStart + /compact | Sync | 5s |
| Session Learner | `session-learner.js` | Stop | Sync | 15s |
| **PreCompact** | `precompact.py` | PreCompact (before /compact) | Sync, fire-and-forget | 8s |

### Impact Funnel (v3.14.0+, source-split v3.17.0, auto-eval v3.18.0, default-on v3.19.0)

A separate, append-only event stream measures whether Cortex actually helps —
not just how much it observes. See [`docs/IMPACT-METRICS.md`](IMPACT-METRICS.md)
for the canonical formulas, [`docs/AGENT-FEEDBACK.md`](AGENT-FEEDBACK.md) for
the user/agent feedback split (v3.17.0), and
[`docs/AUTO-EVALUATION.md`](AUTO-EVALUATION.md) for Stop-time auto-rating of
reflex injections (v3.18.0).

| Event | Emitted by | Meaning |
|-------|------------|---------|
| `inject` | `injector-engine.js` | An instinct was sent into PreToolUse context |
| `follow` | `session-learner.js` | Next tool call respected (or not) the instinct |
| `reject` | reserved (future) | Explicit non-match detector |
| `feedback` | `/cx-feedback` (`source: user`) or `/cx-feedback-auto` (`source: agent`) | Rated the injection useful / noise / ignore |
| `outcome` | reserved (Sprint 5) | Apply-rate of laws |

The Sprint 0.5 Go/No-Go Gate reads `useful_ratio_user` and
`health_ratio_user` exclusively. Agent self-ratings (`source: agent`)
are diagnostic and surfaced separately in `/cx-status --impact` but do
not flip the gate.

Read with `/cx-status --impact` (calls `python3 impact_log.py stats --days 14`)
or `python3 impact_log.py stats --json`.

---

## Hooks (6 files)

### observe.py — Observation Capture
- **Single Python process** replacing 11 shell spawns (~70ms vs ~800ms)
- Captures ALL tool uses as JSONL with short field names (ts, ev, tool, err, sid, pid, pname)
- **12 secret scrubbing patterns**: API keys, JWT, PEM, SSH, AWS, GitHub, Stripe, connection strings, Google, Slack, Anthropic, OpenAI
- **9 error detection patterns** with context anchors: `error[:\s]` (not `ErrorBoundary`), `failed(?!\s*:\s*0)` (not `failed: 0`), exception, traceback, fatal, `panic[:(]` (not Go `panic()`), segfault, OOM, command not found
- **Robust PostToolUse parser** (v3.15.0): unwraps `tool_response.content[type=text][text]` (Anthropic v1 API shape) and prefers `tool_response.is_error` over the regex heuristic. Fixes the live-corpus bug where `err_msg` never persisted (3 errors / 0 messages on 3 730 obs)
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
- **Monorepo-aware domain pre-filter** (v3.15.0): scans recursively up to depth 3, reads `pnpm-workspace.yaml`, `turbo.json`, `nx.json`, `lerna.json`, `rush.json`, plus typical folders (`apps/`, `packages/`, `libs/`, `services/`). Detects more stacks (remix, gatsby, koa, hono, elysia, nestjs, stripe, playwright, fastapi, django, flask). Cached 5 min in `.project-domains-cache`. Before v3.15.0 only depth-0 — Turborepo/pnpm-workspace silently lost ALL stack instincts
- **Impact funnel emit** (v3.14.0): for every instinct that survives all filters, appends an `inject` event to `~/.claude/cortex/impact.jsonl` via the `impact_log.js` fast path (no Python spawn). Try/catch wrapper — never blocks injection if the writer fails
- **Domain dedup**: 1 instinct per domain per injection — higher confidence wins within the same domain. Prevents redundant advice from the same area saturating context
- **Occurrence tracking**: writes `instinct-tracking.json` with per-instinct schema: `{ count, sessions[], projects_seen[], first_seen, last_seen }`. Tracks ALL matches including drafts (confidence < 0.30), not just injected instincts
- **Session tracking**: stores last 20 session IDs per instinct (capped to prevent unbounded growth). Used for multi-session auto-promote gating
- **Cross-project tracking**: `projects_seen[]` per instinct — records which projects triggered each instinct. Used by `/cx-promote` for cross-project analysis
- **Draft auto-promote**: drafts with 5+ activations across 3+ distinct sessions → confidence bumped to 0.35. Events logged to `knowledge-log.md`
- **Token budget cap**: per-session budget (8000 tokens); skips instinct injection when exceeded; reflexes always pass (safety exempt)
- **Max 3 instincts** per injection, 500 chars each, 1500 chars total
- **Inline staleness**: instincts not seen in 60+ days are skipped at injection time (read-only check against tracking data, no file writes to instinct YAML)
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
- **Silent YAML normalization pass** (v3.13.1): invokes `yaml_normalize.normalize_all()` on every session start to auto-repair instinct files with invalid double-quoted regex escapes. Emits `[cortex:yaml-normalize] repaired N file(s)` only when repairs occurred; never blocks session start on failure

### session-learner.js — Pattern Detection at Session End
- **5 pattern detectors**:
  1. Error-fix pairs (is_error flag → Edit/Write within 10-event AND ≤300 s window — v3.15.0 added the temporal guard)
  2. Repetitions (same tool+input 5+ times)
  3. User corrections (same file edited 3+ times with overlapping regions — reduces false positives)
  4. Workflow chains (3-tool trigrams repeated 3+ times)
  5. Agent patterns (recurring Agent tool usage with similar descriptions, Jaccard >= 0.40, 3+ uses → agent-evolution proposals)
- **Cross-detector dedup by incident** (v3.15.0): `dedupProposalsByIncident()` groups proposals by `(sid, file, ±5 min)` between collection and write. Highest-confidence one survives; the rest become `merged_from` + `sub_detectors`. Reduces noise 4-5× when one incident triggered multiple detectors
- **Impact correlation** (v3.14.0): `correlateImpactEvents()` reads `impact.jsonl`, finds `inject` events for the current sid without a `follow`, and emits one per inject by inspecting the next observation. Conservative v1 heuristic — `followed=true` if next obs is not an error; `err_after=true` if any of the next 10 has `is_error`
- **Reflex auto-evaluation** (v3.18.0): `correlateReflexFeedback()` reads reflex inject events (`iid: reflex:*`), runs each reflex's evaluator (`tool-substitution` / `precondition-check` / `error-monitor`) against observations, and emits `feedback` events with `source: agent`. Updates `usefulCount` / `noiseCount` on the reflex entry. Auto-disable when `noiseCount >= 3 AND fireCount >= 10` requires `CORTEX_AGENT_DISABLE_REFLEXES=1` — **now wired by the installer in v3.19.0** (added to `~/.claude/settings.json` `env` block, idempotent, removable via uninstall). Conservative semantics — `error-monitor` reflexes only emit `noise` (when failure observed) or `ignore` (no signal). See `docs/AUTO-EVALUATION.md`
- **Tracking mirror to JSON** (v3.15.0): `_mirrorToTracking()` writes the same `last_seen`/`count` to `instinct-tracking.json` after updating any YAML. JSON becomes the operational source of truth (so the injector's inline staleness filter works); YAML stays for human readability. Resolves the legacy bug where tracking.json had 1 entry vs 61 YAMLs
- **sanitizeProposalAction()**: sanitizes all proposal text against prompt injection
- Auto-generates proposals with `session_date` for cross-day tracking
- Preserves user validation status (approved/rejected) on proposal dedup
- Updates instinct `last_seen` and `occurrences` in YAML files (and now also in `instinct-tracking.json`, see above)
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

### precompact.py — PreCompact Flush (v3.15.0)
- Fires before Claude Code compacts the conversation (`/compact`)
- Spawns `node session-learner.js` as a detached subprocess (`start_new_session=True`) and exits immediately so the 8 s wrapper timeout never blocks compaction
- Forwards the original stdin payload (session id, etc.) to the learner
- Double-flush guard via `fire_once`: marker `precompact-flush-<sid>` (1-h TTL) prevents two consecutive `/compact` calls from running the learner twice
- Best-effort throughout — every failure path returns `exit 0` so compaction is never blocked
- Registered in `install.sh` and `install.ps1` as the fifth hook event

---

## Library Modules (6 files)

### hooks/lib/dream_cycle.py — Knowledge Maintenance
6 modules for knowledge hygiene:
1. **Jaccard dedup**: Unicode-safe tokenization (word boundaries + CJK characters), configurable threshold (default 0.80), **full pairwise comparison** (checks against ALL kept items, not just first match)
2. **Contradiction detection**: 7 antonym pairs (EN: must/must not, always/never, enable/disable, allow/block, require/forbid; ES: siempre/nunca, permitir/prohibir). Same-domain + **topic-overlap gate** (v3.13.2): two actions must share Jaccard ≥ 0.30 of non-stopword, non-antonym tokens to be flagged. Without the gate, 38/38 contradictions on a real 128-instinct corpus were false positives (antonym keywords appearing in unrelated actions). With the gate: 1/38 survives — the legitimate human-review case. `min_action_overlap=0` restores legacy keyword-only detection. No false positives on "document"/"domain"
3. **Staleness scoring**: 0-100 based on age since last_seen (7d=0, 30d=30, 60d=60, 90d+=90+). Auto-archive at threshold (default 90). **Linear confidence decay**: -0.05 per 30 days (matches cx-distill and documented config)
4. **Regex validation**: length limit (100), nested quantifier ban (ReDoS), alternation limit (5), compile test
5. **Health score**: 0-100 with penalties (staleness -2/instinct, contradictions -10/pair, duplicates -3) and bonuses (laws +2, confidence +5)
6. **Cleanup**: `detect_orphan_projects()` (dead registry entries, orphan dirs, stale >90d), `cleanup_expired_context()` (context.md beyond 14d TTL), `consolidate_old_archives()` (observation archives >90d). All return lists for reporting; destructive actions require confirmation

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

### hooks/lib/yaml_normalize.py — Instinct YAML Auto-Repair (v3.13.1)
- Runs silently on every SessionStart via `session-start.py`
- Scans `~/.claude/cortex/instincts/global/` and all `projects/*/instincts/` directories
- Detects double-quoted regex fields (`trigger`, `condition`, `matcher`, `action`) with invalid YAML escape sequences (`\s`, `\.`, `\(`, `\d`, etc.) that strict `yaml.safe_load_all` rejects
- Converts offending values to single-quoted literals (or block scalar `|-` if the value itself contains a `'`)
- Idempotent — only touches files that currently fail strict parse; already-valid files untouched
- Safety-checked — only writes when the rewrite re-parses cleanly
- Callable as a Python module (`normalize_all(root)`) or standalone script
- Emits `[cortex:yaml-normalize] repaired N file(s)` to stderr only when repairs occurred; never blocks session start on failure

### hooks/lib/impact_log.py — Impact Funnel Writer + Metrics (v3.14.0, source-split v3.17.0)
- Canonical writer + reader for `~/.claude/cortex/impact.jsonl` (schema v:1)
- API: `log_event(event, **fields)`, `log_feedback(iid, rating, sid, note, source)`, `compute_metrics(days)`, `gate_recommendation(metrics)`, `rotate(days)`
- CLI: `python3 impact_log.py stats [--days N] [--json]`, `tail [-n N]`, `rotate`, `log --event ... --iid ... [--source user|agent]`
- Five event types: `inject` / `follow` / `reject` / `feedback` / `outcome`
- v3.17.0 · feedback events carry `source: "user" | "agent"` (default `user`, optional, schema v:1 unchanged). `compute_metrics()` returns split ratios (`useful_ratio_user`, `useful_ratio_agent`, `noise_ratio_user`, `noise_ratio_agent`, `health_ratio_user`, `health_ratio_agent`) plus the legacy aggregates for back-compat
- `gate_recommendation()` reads `useful_ratio_user` and `health_ratio_user` exclusively — agent self-ratings never flip the gate. See `docs/AGENT-FEEDBACK.md`
- Canonical formulas (see `docs/IMPACT-METRICS.md`):
  - `useful_event = feedback.useful OR (follow.followed AND NOT err_after)`
  - `noise_event  = feedback.noise  OR follow.followed == false`
  - `useful_ratio = useful / inject`,  `health_ratio = useful_ratio / max(noise_ratio, 0.01)`
- Sprint 0.5 Go/No-Go Gate: GO ≥ 0.25 / 1.5  ·  PARTIAL ≥ 0.10 / 1.0  ·  NO-GO < 0.10 / 1.0
- Auto rotation at 30 days to `~/.claude/cortex/impact.archive/impact-<ts>.jsonl`
- Writes never block calling hook — best-effort with retry + silent stderr fallback

### hooks/lib/impact_log.js — JS Writer Mirror (v3.14.0)
- Same schema as `impact_log.py`. Used by `injector-engine.js` and `session-learner.js` for the fast path (no Python spawn per tool use)
- Public API: `logEvent(event, fields)`, `logInjectBatch(instincts, ctx)`, `logFollow(iid, followed, errAfter, sid, win)`, `logReject(iid, reason, sid)`
- Direct `fs.appendFileSync` with mode 0o600 — atomic at the line level under POSIX append semantics
- Validates event name against `VALID_EVENTS` set; bad names are dropped silently (with stderr warn under `CORTEX_DEBUG=1`)

### hooks/lib/fire_once.py — Once-per-Session Primitive (v3.15.0)
- Reusable "execute exactly once per session_id, with optional TTL + stale cleanup"
- API: `not_fired(name, sid, ttl_hours=None)`, `mark()`, `unmark()`, `once(name, sid)` (context manager), `cleanup_stale(max_age_hours=24)`
- Markers live under `~/.claude/cortex/.fire-once/<name>-<sid24>` with mode 0o600
- Adopted by `precompact.py`; available to other hooks when they are next refactored
- Names + sids are slug-safe (`[a-zA-Z0-9_-]` only, truncated to 32 / 24 chars)

---

## Commands (20)

| Command | Purpose | Token Cost |
|---|---|---|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, tracking, health, domain grouping. **`--impact` flag** (v3.14.0): show the Sprint 0 funnel + Go/No-Go Gate recommendation. **`--reflexes` flag** (v3.18.0): per-reflex health table with healthy/borderline/NOISY/unknown status | ~200 |
| `/cx-dashboard` | Visual HTML report with Fersora brand — laws, instincts, reflexes, projects, health, timeline | ~150 |
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
| `/cx-feedback` | **(v3.14.0, source-split v3.17.0)** Close the human loop on the impact funnel. Always writes `source: user`. Modes `useful \| noise \| ignore` (last-injected) or explicit `<instinct-id>`. Soft confidence nudge (+0.02 / -0.05). Writes `feedback.jsonl` mirror | ~100 |
| `/cx-feedback-auto` | **(v3.17.0)** Agent-emitted feedback for tool-choice reflexes the user cannot evaluate. Always writes `source: agent`. No confidence nudge on instincts; tracks `noiseCount` on reflexes for auto-disable (default-on via installer-managed `CORTEX_AGENT_DISABLE_REFLEXES=1` since v3.19.0). See `docs/AGENT-FEEDBACK.md` | ~100 |
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
**Domain dedup**: 1 instinct per domain per injection. Higher confidence wins within the same domain. Max 3 domains per tool use. Prevents context saturation from redundant advice.
**Promotion**: Jaccard similarity ≥0.70 + 2 projects + avg confidence ≥0.60 → global via `/cx-promote`. Cross-project analysis uses `projects_seen[]` from instinct-tracking.json.
**Draft auto-promote**: 5+ trigger matches across 3+ distinct sessions → confidence bumped to 0.35. Events logged to `knowledge-log.md` with source `injector-engine`.
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
- Hooks (6 files: observe.py, injector.sh, injector.js, session-start.py, session-learner.js, **precompact.py** new in v3.15.0)
- `hooks/lib/` (8 files: dream_cycle.py, validate_instinct.py, yaml-utils.js, yaml_normalize.py, dashboard_gen.py, **impact_log.py**, **impact_log.js**, **fire_once.py**)
- Commands (20 .md files, including `cx-feedback` since v3.14.0 and `cx-feedback-auto` since v3.17.0)
- SKILL.md + 3 agents (cortex-observer, cortex-reviewer, cortex-planner)
- Cortex section in CLAUDE.md
- Version marker
- `settings.json` registers 5 hook events (PreToolUse, PostToolUse, SessionStart + /compact, Stop, **PreCompact**)
- Git pre-push hook (in repo context) — runs version-consistency check + security + dream tests

---

## Tests (12 suites, 208 tests)

| Suite | Tests | Coverage |
|---|---|---|
| `test_security.sh` | 7 | Injection, command injection, scrubbing, validation |
| `test_dream_cycle.sh` | 35 | Jaccard, contradictions (incl. topic-overlap gate), staleness, regex, health, decay formula, **cleanup module 6** |
| `test_observe.sh` | 8 | Scrubbing, is_error, dedup, atomic write, e2e, perf, subagent capture |
| `test_session_learner.sh` | 8 | Error-fix pairs, corrections, chains, proposals, command timeline |
| `test_injector.sh` | 16 | Sanitization, ReDoS, limits, markers, yaml-utils, .last-instinct, engine |
| `test_yaml_utils.sh` | 13 | Floats, ints, strings, colon values, update, list |
| `test_install.sh` | 42 | Fresh install, upgrade, idempotency, **strict** path traversal (no fake-green), **v3.19.0 env merge** (CORTEX_AGENT_DISABLE_REFLEXES added, user vars preserved, idempotency, opt-out respected) |
| `test_hooks_e2e.sh` | 14 | Full pipeline: observe→inject→learn, **token budget reset** |
| `test_uninstall.sh` | 13 | Cleanup, backup creation, data preservation, **safety guard**, CLAUDE.md preservation, **v3.19.0 env removal** (Cortex var removed, user vars preserved, empty env block dropped) |
| `test_integrity.sh` | 14 | observe.py direct, **20 commands** validated, core file schemas, **version consistency** |
| `test_install_ps1.ps1` | 9 | PowerShell syntax, version consistency, security features, backup categories, hook config, **CI on windows-latest** |
| `test_impact.sh` | 32 | **Sprint 0/1 funnel** — schema v1, JS↔Python compat, concurrent writes (10 parallel → 0 loss), rotation, gate GO/NO-GO, formulas, input validation, **v3.17.0 source split** (user/agent ratios, gate input, legacy default), **v3.18.0 auto-eval** (3 evaluator types, no-evaluator default, reflex iid prefix) |

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
├── version                       # Installed version (e.g., "3.15.0")
├── memory.json                   # Config + stats (identity removed in v3.12.0)
├── reflexes.json                 # 10 deterministic rules
├── proposals.json                # Pending proposals from learner + cx-analyze
├── instinct-tracking.json        # Operational source of truth (v3.15.0): {count, sessions[20], projects_seen[], first_seen, last_seen}
├── instinct-tracking.json.pre-v4.0  # Backup created by migrate-tracking-v4.py
├── impact.jsonl                  # Sprint 0 funnel — inject/follow/reject/feedback/outcome events (v3.14.0+)
├── feedback.jsonl                # /cx-feedback mirror (sampled view of feedback events)
├── impact.archive/               # Archived impact events older than 30 days
├── .session-token-budget         # Per-session token counter
├── .obs-count                    # Observation counter (triggers at 50)
├── .learn-pending                # Marker: run /cx-analyze
├── .last-distill                 # Timestamp of last cx-distill
├── .last-audit                   # Timestamp of last cx-audit
├── .last-session-date            # Last session date
├── .last-instinct                # IDs of last batch injected (used by /cx-downvote and /cx-feedback)
├── .eod-last-read                # EOD read-once guard
├── .project-domains-cache        # Domain pre-filter cache (v3.15.0, 5-min TTL)
├── .fire-once/                   # fire_once markers (v3.15.0): name-sid24 files
│   └── precompact-flush-<sid>    # PreCompact double-flush guard (1-h TTL)
├── laws/                         # One-liners (max 10 active)
│   ├── *.txt
│   └── archive/
├── instincts/
│   ├── global/                   # Cross-project instincts
│   └── archive/                  # Decayed/archived instincts
├── projects/
│   ├── registry.json             # All known projects
│   └── {sha256hash}/
│       ├── observations.jsonl
│       ├── observations.archive/
│       ├── context.md             # Session bridge (14d TTL)
│       └── instincts/             # Project-scoped instincts
├── evolved/
│   ├── skills/
│   ├── commands/
│   ├── rules/
│   └── agents/
├── knowledge-log.md              # Append-only knowledge event timeline
├── daily-summaries/              # EOD summaries (*.md)
├── exports/                      # Portable skills
└── log/                          # Session learner logs
```

### Scripts (new in v3.15.0)

The repo ships a `scripts/` folder with maintenance utilities that run
locally (not installed to `~/.claude/`):

| Script | Purpose |
|--------|---------|
| `scripts/check-version-consistency.py` | Validates `install.sh` / `install.ps1` / `CHANGELOG.md` / `docs/FEATURES.md` agree on the same version. Run via `pre-push` hook; bocks push on drift |
| `scripts/migrate-tracking-v4.py` | One-shot idempotent migration: merges YAML `occurrences:` + `last_seen:` into `instinct-tracking.json`. Backup to `tracking.json.pre-v4.0`. Default dry-run; pass `--apply` to persist |

---

## memory.json Configuration

### Active config values (read by hooks at runtime)

| Key | Default | Used by | Purpose |
|---|---|---|---|
| `max_observations_mb` | 10 | observe.py | Auto-archive observations.jsonl when exceeds this size |
| `archive_days` | 30 | observe.py | Auto-purge archived observations older than N days |
| `learn_threshold` | 50 | observe.py | Mark `.learn-pending` after N observations |

### Config values used by commands (read by Claude, not by hooks)

| Key | Default | Used by | Purpose |
|---|---|---|---|
| `law_threshold` | 0.90 | /cx-distill | Minimum confidence to distill instinct → law |
| `max_laws` | 10 | /cx-distill, session-start.py | Maximum active laws |
| `decay_per_30_days` | 0.05 | /cx-distill, /cx-dream | Linear confidence decay rate |
| `promote_min_projects` | 2 | /cx-promote | Minimum projects for cross-project promotion |
| `promote_min_confidence` | 0.80 | /cx-promote | Minimum avg confidence for promotion |
| `jaccard_threshold` | 0.70 | /cx-promote, dream_cycle.py | Jaccard similarity threshold for dedup/promotion |
| `confidence_cap` | 0.95 | /cx-distill | Maximum confidence value |
| `context_ttl_days` | 14 | session-start.py | Context bridge expiry |

### Previously dormant, now active (v3.12.0)

| Key | Default | Now used by | Note |
|---|---|---|---|
| `max_instincts_per_injection` | 3 | injector-engine.js | Was hardcoded, now read from config with fallback to 3 |
| `max_reflexes_per_injection` | 2 | injector-engine.js | Was hardcoded, now read from config with fallback to 2 |

### Removed (v3.12.0)

| Key | Reason |
|---|---|
| `identity.name` | Never read by any hook. User identity lives in CLAUDE.md |
| `identity.role` | Never read by any hook |
| `identity.language` | Never read by any hook |

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
| v3.11.1 | 2026-04-12 | Test expectations fix for 17 commands |
| v3.12.0 | 2026-04-14 | Dream Cycle Module 6 (cleanup), configurable injection limits, identity removal, reflex stats |
| v3.12.1 | 2026-04-14 | Fix staleness_score naive vs aware datetime crash (archived ALL instincts) |
| v3.12.2 | 2026-04-20 | Fix install.ps1 Join-Path crash on PowerShell 7.6 (issue #16) |
| v3.12.3 | 2026-04-21 | Fix 19 additional Join-Path 3+ arg calls in install.ps1 + tests (issue #16 continuation) |
| v3.12.4 | 2026-04-22 | Windows injector.js cross-platform hook (bash no longer required) |
| v3.13.0 | 2026-04-23 | /cx-dashboard visual HTML report with Fersora brand + project dedup by root |
| v3.13.1 | 2026-04-24 | Silent YAML parse repair: auto-fix invalid double-quoted regex escapes in instincts (18 files repaired); yaml_normalize.py runs on every SessionStart; cx-validate/cx-gotcha/cx-analyze templates enforce single-quote rule |
| v3.13.2 | 2026-04-24 | Dream Cycle contradiction detector: topic-overlap Jaccard gate (default 0.30) eliminates 97% of false positives (38 → 1 on live corpus); parameterizable threshold with back-compat opt-out; 3 new tests |
| v3.13.3 | 2026-04-24 | CI hotfix: `${exit}` braces in workflow YAML — unblocks `test-windows` after 4 consecutive red releases (PowerShell 7 was parsing `$exit:` as drive-provider) |
| v3.14.0 | 2026-04-24 | **Sprint 0 · Instrumentation** — impact funnel (`impact.jsonl`, schema v:1) + `/cx-feedback` (closes the human loop) + `/cx-status --impact` (Go/No-Go Gate). New libs `impact_log.py` + `impact_log.js`. 17 tests in `test_impact.sh`. Origin: multi-agent Opus 1M audit (score 5.8/10) |
| v3.14.1 | 2026-04-24 | Patch: `tests/test_install.sh` command count 18 → 19 (cx-feedback) so the Linux+macOS CI matrix recovers |
| v3.15.0 | 2026-04-24 | **Sprint 1 · P1 bugfixes** — PostToolUse parser unwraps `tool_response.content[]`; monorepo-aware domain detection (recursive depth 3 + workspace configs); cross-detector dedup by incident; time-based sliding windows; tracking unified to JSON (live: 1 → 110 entries); PreCompact hook + `fire_once.py`; `install.ps1` `exit 1` on settings merge fail; fake-green path-traversal test rewritten; version-consistency check in pre-push |
| v3.16.0 | 2026-04-25 | session-learner: raise repetition+chain detection thresholds 5 → 8 (fewer noisy proposals on long sessions) |
| v3.17.0 | 2026-04-25 | impact funnel: split user vs agent feedback; user counters drive the Go/No-Go gate, agent counters drive reflex auto-disable |
| v3.17.1 | 2026-04-25 | Docs: fix doubled-cortex path in spec files; tests: bump expected command count to 20 |
| v3.18.0 | 2026-04-25 | impact funnel: auto-evaluate reflex injections at Stop (`correlateReflexFeedback` + 3 evaluator types) — opt-in via `CORTEX_AGENT_DISABLE_REFLEXES=1` |
| v3.19.0 | 2026-04-25 | installer: wire `CORTEX_AGENT_DISABLE_REFLEXES=1` into `~/.claude/settings.json` env block by default (idempotent) |
| v3.19.1 | 2026-04-26 | **Hotfix** — reflex auto-evaluation was silently broken since v3.18.0: hardcoded `CORTEX_DIR` (no env-var honor), wrong `_sid` field name in fallback, orphan-harness-sid filter discarded all real injects. Both `correlateImpactEvents` and `correlateReflexFeedback` now union candidate sids from observations. New Test 29 + Test 30 in `test_impact.sh` (38/38 PASS). |
| v3.19.2 | 2026-04-26 | **Cleanup** — propagates `CORTEX_DIR` env-var honor to remaining hooks (observe.py, session-start.py, precompact.py, injector.sh, injector.js) and lib modules (dashboard_gen.py, yaml_normalize.py, injector-engine.js). Dashboard reflex table now renders Useful/Noise/Health columns with v3.18.0 health classification. Docs sync (README, SKILL v3.10→v3.19.2, claudemd-section, AUTO-EVALUATION, IMPACT-METRICS). |
| v3.19.3 | 2026-04-26 | **Critical bugfix** — reflex auto-evaluation appeared to work since v3.19.1 (38/38 tests green) but in production the `usefulCount`/`noiseCount` counters never moved. Root cause: `observe.py` truncated `session_id` to `[:24]` while Claude Code session IDs are 36-char UUIDs, so `candidateSids.has(ev.sid)` filter in both correlators never matched. Fixed: raise cap to `[:64]` so UUIDs round-trip; add `sidMatches()` helper that also accepts the legacy 24-char prefix. Tests updated (`test_observe.sh`: 8→9 passing). |
| v3.19.4 | 2026-04-26 | **Three follow-up bugs from the v3.19.3 audit.** (1) `impact_log.py` now `_normalize_iid()`-rewrites the `reflex-<id>` typo to `reflex:<id>` so the impact dashboard no longer splits into phantom rows per reflex. (2) `correlateImpactEvents` finally emits the `outcome` event the schema has defined since v3.14.0 — pre-fix the funnel always reported `outcome: 0`. (3) `evalErrorMonitor` rewritten to emit `useful` when the inject was followed by any observation AND no matching error fired in the window, fixing the structural bias that condemned 16/21 reflexes (every `error-monitor` evaluator) to `agent → useful: 0.0000`. `test_impact.sh`: 38 → 40 PASS. |
| v3.19.5 | 2026-04-26 | **Data hygiene + docs sync.** New one-shot `scripts/migrate-legacy-reflex-iid.py` rewrites historical `iid: reflex-<id>` events in `impact.jsonl` to canonical `reflex:<id>` (whitelisted against `reflexes.json`, idempotent, atomic, backs up to `.pre-v3.19.5.bak`). Production run rewrote 5 events across 3 reflex ids. Docs synced: `AUTO-EVALUATION.md` Type C semantics now match v3.19.4 `evalErrorMonitor` contract; `IMPACT-METRICS.md` `outcome` event no longer flagged "Reserved for Sprint 5". New `tests/test_migrate_legacy_iid.sh` (12/12 PASS). Documents the systemic `fireCount` under-count caused by the v3.19.3 sid bug as a known issue, deferred to a Sprint 5 `--reconcile-counters` extension. |
| v3.19.6 | 2026-04-26 | **Cosmetic** — `docs/FEATURES-visual.html` footer was stuck at `v3.19.2` since the v3.19.3 release (missed in three consecutive bumps: v3.19.3, v3.19.4, v3.19.5). Footer now reads `v3.19.6`. No functional change. |
| v3.20.0 | 2026-04-26 | **Sprint 5 · Autonomy + intelligence.** New `compute_outcome_ranking()` + `apply_outcome_nudges()` in `hooks/lib/impact_log.py` plus 2 CLI subcommands (`outcome-ranking`, `outcome-nudge`). `session-learner.js` Step 5e calls `outcome-nudge --apply` at every Stop hook so instinct YAML `confidence:` fields move ±0.05 based on the observed `error_within_10` ratio over 14 days (clamped `[0.10, 0.99]`, reflex iids skipped, ≥5 outcomes required). Refined matchers for the 3 tool-substitution reflexes (`bash-cat-use-read`, `bash-grep-use-grep-tool`, `bash-find-use-glob`) — added to `core/reflexes.default.json` (was missing) and runtime reactivated with reset counters. Audit of 9 NEVER-FIRED reflexes: all kept (matchers correct, just narrow domains not in this corpus). New `docs/OUTCOME-RANKING.md`. `tests/test_impact.sh` 40 → 48 PASS. |
