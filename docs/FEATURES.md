# fs-cortex v3.38.0 — Feature Reference

> Complete inventory of all features, commands, hooks, modules, and capabilities.
> Last updated: 2026-06-19

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
| **PreToolUse** | Instincts (max 3) + Reflexes (max 2); same id max 2x per session (v3.37.0 cooldown) | Every tool use (if trigger matches) | ~200 max |

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
- **Heuristic false-positive guards** (v3.37.2, mirrored in `session-learner.js` `isError()`): network tools (`WebFetch`/`WebSearch`) are exempt from the keyword scan (explicit `is_error` flag only — their output is page/search content where "error" is just a word), structured responses with HTTP 2xx `code` are success by contract, and test-runner output (`=== Results:`, `PASS:`/`FAIL:` lines, `N passed`, `Tests: N`) never counts as a tool failure
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
- Injects Laws (max 15) from `~/.claude/cortex/laws/*.txt`
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
  1. Error-fix pairs (is_error flag → Edit/Write within 10-event AND ≤300 s window — v3.15.0 added the temporal guard). v3.37.0: requires `err_msg` evidence; trigger derived from distinctive tokens of the FAILING input (validated against the injector matchTarget, never a bare tool name); error signature quoted in the action; project-specific evidence (`/Users/`, URLs) → `scope: project`; proposals carry `sample_input`/`sample_output`/`err_msg` (200 c)
  2. Repetitions (same tool+input 5+ times)
  3. User corrections (same file edited 3+ times with overlapping regions — reduces false positives)
  4. Workflow chains (3-tool trigrams repeated 3+ times)
  5. Agent patterns (recurring Agent tool usage with similar descriptions, Jaccard >= 0.40, 4+ uses → agent-evolution proposals; v3.37.0: trigger scoped to the description, never bare `Agent`; domain validated HUMAN, not AUTO)
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
- **Step 5f — storage rotation** (v3.35.1, #56.2; extended v3.36.0 audit): calls `hooks/lib/storage-rotation.js::maybeRotateStorage()`. Size-gated (`impact.jsonl` ≥ 10 MB → `impact_log.py rotate` spawned detached; `cross-day-tracker.jsonl` ≥ 1 MB → `prune()`), at most once per 24 h via marker `.last-storage-rotate`. v3.36.0 adds: `proposals-history.jsonl` ≥ 3 MB → rename-rotate to `proposals.archive/` under `.proposals-history.lock`; `knowledge-log.md` ≥ 2 MB → `knowledge-log.archive/`; `daily-snapshots/` + `daily-summaries/` keep newest 60 files; `.fire-once/` markers > 30 d deleted. Impact live window 30 → 15 d (v3.36.0), floor raised to 18 d in v3.37.0 (widest reader window is 14 d; the 1-day margin was eatable by clock drift). Env overrides: `CORTEX_IMPACT_ROTATE_MB`, `CORTEX_TRACKER_PRUNE_MB`, `CORTEX_IMPACT_ROTATION_DAYS`, `CORTEX_HISTORY_ROTATE_MB`, `CORTEX_KNOWLEDGE_ROTATE_MB`, `CORTEX_DAILY_KEEP_FILES`, `CORTEX_FIREONCE_MAX_DAYS`, `CORTEX_ROTATE_SYNC=1` (tests)
- **Step 3h timeline root-scan** (v3.35.2): `detectCommandUsage` also scans the GLOBAL observation stream (`~/.claude/cortex/observations.jsonl`) with a ts cursor (`.timeline-cursor`) — `/cx-*` commands run from project-less cwds land there (`pid=global`) and were invisible to the per-project loader, killing the timeline since 2026-05-27
- Learner log appends with `mode 0o600` + healing chmod (v3.35.2, #47 follow-up)
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
- Rotation at 30 days to `~/.claude/cortex/impact.archive/impact-<ts>-<pid>.jsonl` — **wired in v3.35.1** (#56.2) from session-learner Step 5f; rename-first algorithm is loss-proof under concurrent JS/Python writers and never deletes events (pre-scan no-op → atomic rename → recent events re-appended in line-aligned chunks on an `O_APPEND` fd → static archive rewritten with only old events)
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
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, tracking, health, domain grouping. **`--impact` flag** (v3.14.0): show the Sprint 0 funnel + Go/No-Go Gate recommendation. **`--reflexes` flag** (v3.18.0): per-reflex health table with healthy/borderline/NOISY/unknown status. **`--pipeline` flag** (v3.23.1): consolidated knowledge-pipeline activity (auto-validate / auto-distill / auto-evolve counts, queue depths, last-run markers) — single source of truth for what the system did automatically | ~200 |
| `/cx-dashboard` | Visual HTML report with Fersora brand — laws, instincts, reflexes, projects, health, timeline | ~150 |
| `/cx-analyze` | Detect patterns in observations → proposals (Opus 1M agent) | ~5K |
| `/cx-distill` | Promote instincts to laws (0.90+), apply decay, Jaccard promotions | ~800 |
| `/cx-validate` | Review and accept/reject proposals interactively (shorthand UX) | ~500 |
| `/cx-evolve` | Cluster mature instincts → skills/commands/rules/agents | ~1K |
| `/cx-dream` | Dream Cycle: dedup, contradictions, staleness, regex, health score | ~600 |
| `/cx-router` | Command catalog with token costs, session budget estimate, next action | ~50 |
| `/cx-promote` | Cross-project instinct promotion (Jaccard ≥0.70, 2+ projects) | ~300 |
| `/cx-audit` | Token overhead, duplicates, conflicts, cleanup | ~400 |
| `/cx-eod` | **(v3.38.0)** End-of-day summary for next session. Deterministic gather (`core/_cx-eod-gather.sh`, no LLM) over all projects' last 24h; idempotent intraday regeneration with `## Ejecuciones hoy` trace; `--auto` flag for cron/launchd | ~300 |
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

## Reflexes (11 default)

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

## Tests (35 bash suites, 578+ tests, + 1 PowerShell suite)

> Totals verified with `run_all.sh` on 2026-06-09 (34/34 suites green; 569 tests
> across the 31 suites that print the standard `Results:` counter); v3.38.0 adds
> `test_cx_eod_gather.sh` (9 tests). The table
> below describes the core suites — `run_all.sh` and CI execute every
> `tests/test_*.sh` regardless of whether it is listed here.

| Suite | Tests | Coverage |
|---|---|---|
| `test_security.sh` | 7 | Injection, command injection, scrubbing, validation |
| `test_dream_cycle.sh` | 35 | Jaccard, contradictions (incl. topic-overlap gate), staleness, regex, health, decay formula, **cleanup module 6** |
| `test_cx_eod_gather.sh` | 9 | **(v3.38.0)** `core/_cx-eod-gather.sh`: root/non-git detection, name-merge across subdir+root, cross-OS basename, 24h rolling window, registry hash→name, error counting, JSON shape |
| `test_observe.sh` | 11 | Scrubbing, is_error, dedup, atomic write, e2e, perf, subagent capture; **v3.37.0**: binary/base64 output detection; **v3.37.2**: heuristic guards (network tools, 2xx, test-runner) |
| `test_session_learner.sh` | 42 | Error-fix pairs, corrections, chains, proposals, command timeline; **v3.36.1**: semantic fix summary, hollow-fix skip, writeProposals quality gate; **v3.37.0**: err_msg required, input-derived trigger validation, project scope, evidence samples, agent-pattern scoped trigger; **v3.37.1**: rejection tombstones; **v3.37.2**: isError guards + WebFetch 200-OK no-proposal e2e |
| `test_injector.sh` | 29 | Sanitization, ReDoS, limits, markers, yaml-utils, .last-instinct, engine; **v3.36.1 e2e**: category domain injects with detected stack, hollow action never injects; **v3.37.0 e2e**: per-session repeat cooldown (max 2 + suppress events), token-budget degrade keeps highest-confidence, concurrent-injector count integrity |
| `test_yaml_utils.sh` | 16 | Floats, ints, strings, colon values, update, list; **v3.36.1**: literal/folded/last-field block scalars |
| `test_install.sh` | 42 | Fresh install, upgrade, idempotency, **strict** path traversal (no fake-green), **v3.19.0 env merge** (CORTEX_AGENT_DISABLE_REFLEXES added, user vars preserved, idempotency, opt-out respected) |
| `test_hooks_e2e.sh` | 14 | Full pipeline: observe→inject→learn, **token budget reset** |
| `test_uninstall.sh` | 13 | Cleanup, backup creation, data preservation, **safety guard**, CLAUDE.md preservation, **v3.19.0 env removal** (Cortex var removed, user vars preserved, empty env block dropped) |
| `test_integrity.sh` | 14 | observe.py direct, **21 commands** validated (EXPECTED_COMMANDS subset; 22 command files total incl. cx-feedback-auto + cx-backfill + cx-stop), core file schemas, **version consistency** |
| `test_install_ps1.ps1` | 10 | PowerShell syntax, version consistency, security features, backup categories, hook config, v3.26-v3.28 source files present, **CI on windows-latest** |
| `test_impact.sh` | 32 | **Sprint 0/1 funnel** — schema v1, JS↔Python compat, concurrent writes (10 parallel → 0 loss), rotation, gate GO/NO-GO, formulas, input validation, **v3.17.0 source split** (user/agent ratios, gate input, legacy default), **v3.18.0 auto-eval** (3 evaluator types, no-evaluator default, reflex iid prefix) |
| `test_cross_day_tracker.sh` | 10 | Roundtrip, boost tiers (1/2/4/8 days), confidence cap 0.95, Jaccard match, single-token guard, prune >365d, concurrent append |
| `test_detectors_v327.sh` | 12 | detectAgentSubtypes (emit/no-emit/rate), detectFileCoupling (emit/no-emit/missing-path, `::` in paths), detectTimeOfDayPatterns (buckets, empty, merge, reflect JSON structure, corrupted-file no-clobber) |
| `test_v328_operational.sh` | 4 | `write_daily_snapshot` (creates JSON, idempotent, empty CORTEX_DIR), cx-analyze `--deep` spec present |
| `test_storage_rotation.sh` | 46 | **v3.35.1 #56.2, extended v3.36.0** — rotate() rename-first split (no-loss invariant, idempotency, 0600 perms, malformed-line preservation, pre-scan no-op), storage-rotation.js size + 24h-marker gates, tracker prune wiring, learner Step 5f wiring; v3.36.0: rotation-window default/override/floor, proposals-history + knowledge-log rename-rotation, daily-dir retention, fire-once pruning, small-file no-ops |
| `test_distill_engine.sh` | 52 | Auto-validate pipeline, promotion gates, law cap/demote, **Test 51 (v3.35.2): law line 200-char word-boundary cut**, **Test 52: tags block format** |

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
├── .last-storage-rotate          # 24h gate for Step 5f storage rotation (v3.35.1)
├── .last-instinct                # IDs of last batch injected (used by /cx-downvote and /cx-feedback)
├── .eod-last-read                # EOD read-once guard
├── .project-domains-cache        # Domain pre-filter cache (v3.15.0, 5-min TTL)
├── .fire-once/                   # fire_once markers (v3.15.0): name-sid24 files
│   └── precompact-flush-<sid>    # PreCompact double-flush guard (1-h TTL)
├── laws/                         # One-liners (max 15 active; deprecation via /cx-distill --swap)
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
| `max_observations_mb` | 5 | observe.py | Auto-archive observations.jsonl when exceeds this size |
| `archive_days` | 90 | observe.py | Auto-purge archived observations older than N days |
| `learn_threshold` | 50 | observe.py | Mark `.learn-pending` after N observations |

### Config values used by commands (read by Claude, not by hooks)

| Key | Default | Used by | Purpose |
|---|---|---|---|
| `law_threshold` | 0.90 | /cx-distill | Minimum confidence to distill instinct → law |
| `max_laws` | 15 | /cx-distill, session-start.py | Maximum active laws (`LAW_MAX_ACTIVE`, v3.32.0 §4.5) |
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
| Laws (max 15) | ~600 | SessionStart (1x) |
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
| v3.20.1 | 2026-04-26 | **Repo hygiene.** CI `.github/workflows/test.yml` now runs `test_impact.sh` (48), `test_migrate_legacy_iid.sh` (12), `test_integrity.sh` (14), `test_uninstall.sh` (13) on every push — 4 suites that existed in the repo but were never executed by CI (gap of 87 tests). README updated: reflex count 10 → 13 with the 3 tool-substitution defaults documented in the table; `session-learner.js` row mentions Step 5e outcome auto-ranking; `~/.claude/cortex/` tree shows `impact.jsonl`. SECURITY.md: refreshed measures section (no longer pinned to v3.6), added Sprint 5 safeguards, suite list updated to actual **240 tests / 13 suites** with CI matrix breakdown. No code changes. |
| v3.20.2 | 2026-04-26 | **Hotfix — outcome-nudge idempotency.** Detected via `/cx-status --impact` after v3.20.1: `gotcha-agent-spawn-preflight` raced from `0.77 → 0.99` (cap) in five consecutive Stop hooks on identical evidence because `apply_outcome_nudges` re-evaluated the same 14-day outcome window each call without remembering prior applications. Fix: persist `~/.claude/cortex/nudge-state.json` per iid (`{outcome_total, last_nudge_ts}`) and gate the nudge on `now_seen > prev_seen`. Saturated iids (already at clamp) record state but emit no apply entry, so the gate stays a no-op afterward. New tests 38–41 in `test_impact.sh` (idempotency, gate re-open on new outcomes, state shape, saturated iid). 48 → **56 PASS**. `OUTCOME-RANKING.md` adds safeguard #7 + reset instructions (`rm nudge-state.json`). |
| v3.21.0 | 2026-04-27 | **Cohort-based outcome nudging — definitive fix.** The v3.20.2 `outcome_total` gate closed the visible saturation symptom but left four latent defects exposed by an internal Six-Hat review + independent sub-agent audit: aggregate-ratio drift, archive decrement, parallel-Stop race, no clawback. v3.21.0 reframes the apply path around a **cohort** of new evidence: new helper `compute_outcome_decisions(state)` only counts outcomes with `ts > state.iids[iid].last_event_ts`, so the ratio is marginal (only what arrived since the last decision). Schema bump `nudge-state.json` v1 → v2 (`{version: 2, iids: {<iid>: {last_event_ts, last_nudge_ts, last_direction, conf_at_last_nudge}}}`); v1 state is discarded on first load (already-applied YAML confidences are preserved). Concurrency: `fcntl.flock` advisory lock on `nudge-state.json.lock` serializes parallel Stop hooks (no-op fallback on Windows). Tests 42–45 added: drift cohort decay, parallel-apply lock, archive resilience, v1→v2 migration. `test_impact.sh` 56 → **61 PASS**. `OUTCOME-RANKING.md` safeguard #7 rewritten. |
| v3.21.1 | 2026-04-27 | **Hotfix — `install.sh` Step 8b crashed when run from outside the repo.** Latent bug since v3.0.1 (2026-04-09): `git -C "$SCRIPT_DIR" rev-parse --git-dir` returns the **relative** path `.git`, which the subsequent `cp` resolves against the user's `cwd`, not against `SCRIPT_DIR`. If the user invoked the installer with an absolute path (e.g. `bash /Users/fmm/github/fs-cortex/install.sh`) from any non-repo directory, the script aborted at Step 8b under `set -e`, leaving Steps 10–14 unexecuted (settings.json hooks merge, CLAUDE.md update, version marker). The Cortex code itself was already in place (Steps 5–8a finished), so end-users typically saw a half-finished install with stale `~/.claude/cortex/version`. Fix: use `git rev-parse --absolute-git-dir`. `install.ps1` does not install a pre-push hook, so it is unaffected. |
| v3.21.2 | 2026-04-27 | **Cleanup — remove two reflexes whose matcher design never worked.** `instinct-downvote` (matcher `Bash` + condition `/cx-downvote\|wrong instinct\|...`) and `capture-decision` (matcher `Bash\|Edit\|Write` + condition `from now on\|always use\|...`) targeted user-prompt patterns, but reflexes match against tool **input**, not against the user's chat message — so neither reflex ever fired in production (0 fires across 14 days, against 2314 inject events). Both removed from `core/reflexes.default.json`. Default reflex count 13 → **11**. New `docs/SPRINT-5-PENDING-GATES.md` tracks the three Sprint 5 measurement gates that need fresh production data (matcher quality of `bash-grep-use-grep-tool`, no-re-disable check on the three reactivated NOISY reflexes, ≥40% injection-rate reduction vs pre-Sprint-5 baseline). `CLAUDE.md` references the gates doc so it surfaces at SessionStart until all gates pass. User-local `~/.claude/cortex/reflexes.json` is **not** modified by the installer — existing copies of the two removed reflexes stay in place until the user prunes them. No code changes. |
| v3.22.0 | 2026-04-27 | **Sprint 6 · Auto-distill engine.** New `hooks/lib/distill_engine.py` (827 LOC, pure stdlib, `fcntl.flock`-locked, atomic writes) automates the deterministic parts of `/cx-distill` at SessionStart, gated to once per 24h via `~/.claude/cortex/.last-auto-distill` marker. Three operations run automatically: (1) **decay** -0.05 per 30 days unused, (2) **archive** instincts with confidence < 0.10, (3) **auto-promote-to-law** under a 7-criteria gate (conf ≥ 0.95, sustained ≥ 14d via new YAML field `at_law_threshold_since`, ≥ 3 distinct projects, 0 noise + ≥ 5 useful events in 14d, no Jaccard ≥ 0.50 overlap with existing laws, < 10 active laws). Instincts that meet conf ≥ 0.95 but fail the universality/timing/Jaccard checks are written to `~/.claude/cortex/auto-distill-candidates.md` as a 1-line summary for human review. `hooks/session-start.py` invokes the engine in `main()` step 3d (silently swallows errors so it never blocks session start) and gates the existing `[MAINT] Run /cx-distill` reminder so it only fires when candidates are pending — eliminating the 7-day weekly nag for users whose system has nothing to review. Knowledge log entries are written under source `cx-auto-distill` (vs `cx-distill` for manual). New `tests/test_distill_engine.sh` (15/15 PASS) covers decay determinism, threshold tracking, all 7 promotion-gate failure modes, idempotency, rate-limit, and parallel-lock semantics. **Known issue:** `test_impact.sh` 31-33 fail intermittently because they hardcode `2026-04-26T10:00:00Z` with `--days 1` — the window expires when the wall clock advances past 24h after the fixture date. Test fragility, not a regression. Will be patched in v3.22.1 by switching to dynamic timestamps. |
| v3.22.1 | 2026-04-27 | **Reset-aware impact stats + test fragility cleanup.** Two fixes in one patch: (1) `/cx-status --impact` was reporting a misleading `1.13×` useful/noise ratio for `bash-grep-use-grep-tool` because it aggregated events from BOTH eras of the matcher — pre-v3.20.0 (62 noise events) and post-v3.20.0 (refined matcher, 0 fires in 50 h). New optional `resetAt` field per reflex; `hooks/lib/impact_log.py` reads `reflexes.json` once via the new `_load_reflex_resets()` helper and `_iter_events()` discards `reflex:X` events with `ts < resetAt[X]` only when called from `compute_metrics()` (other callers — `rotate()`, outcome-ranking, outcome-nudge — leave the boundary disabled). `core/reflexes.default.json` 2.2.0 → 2.3.0; the field is opt-in and backward compatible. `hooks/session-learner.js` `correlateReflexFeedback` auto-heals existing user-local runtimes by backfilling `resetAt = 2026-04-26T13:31:57+02:00` on the three v3.20.0-reset reflexes when they match the known-reset shape (`fireCount > 0 AND useful === 0 AND noise === 0`). Idempotent. (2) `tests/test_impact.sh` 31-34 now derive `NOW_TS` from `datetime.utcnow()` instead of hardcoding `2026-04-26T10:00:00Z`, closing the time-fragility deferred from v3.22.0. New tests 46-48: `compute_metrics` excludes pre-`resetAt` events, `_load_reflex_resets()` returns `{}` on missing file, `resetAt` on one reflex doesn't affect events of other reflexes. `test_impact.sh` 58/61 → **64/64 PASS**. Unblocks `docs/SPRINT-5-PENDING-GATES.md` Gate 1. |
| v3.22.2 | 2026-04-30 | **Cleanup pass + Sprint 5 gates partial closure.** Triggered by Fer's intuition that `noise_events: 1` post-v3.22.1 looked too clean — three parallel sub-agents (haiku + 2× sonnet) confirmed the pipeline is healthy and identified accumulated cruft. Documented findings + cleanup recommendations: (1) `docs/SPRINT-5-PENDING-GATES.md` rewritten — **Gate 2 closed (PASS)** with final reflex states (3 reactivated reflexes still `enabled: true`, `noiseCount: 0` after 5+ days), **Gate 3 dropped** (no reconstructible pre-v3.20.0 baseline; intent already covered by aggregate ratios), **Gate 1 reframed** (measurable from mid-May onward when post-`resetAt` evidence accumulates). (2) Recommended migration in `~/.claude/cortex/laws/`: 4 niche laws (`playwright-selector-priority`, `supabase-rls-verify`, `three-layer-security`, `touch-visible-buttons`) belong in their respective skills (`fs-e2e`, `fs-supabase-gotchas`, `fs-web-design`), not in the always-injected laws bucket — they burn ~135 tokens per session in projects that don't use that stack. Active law count after archive: 11 → 7 (universal-only). The `≥ 3 distinct projects` criterion in `distill_engine.py` `auto_promote_to_law` already enforces universality for new laws; manual `/cx-distill` should adopt the same standard. (3) Recommended pruning of dead reflexes: `html-twin-deliverables` (35 fires / 0 useful sustained — pure noise) → delete; `git-tag-after-amend` (39 fires / 1 useful) and `docker-cross-network` (682 fires / 3 useful) → severity high/medium → low (informational, not stop-sign). No code changes shipped — this release documents the audit conclusions and updates the gates doc. Local pruning is per-user and reversible. |
| v3.23.0 | 2026-04-30 | **Sprint 7 · Pipeline automation.** Closes the two manual gates that remained in the knowledge pipeline after Sprint 6: proposal→instinct (`/cx-validate`) and instinct→skill (`/cx-evolve`). `hooks/lib/distill_engine.py` extended (+424 LOC, 827 → 1251) with two new public functions: (1) `auto_validate_proposals()` auto-accepts proposals matching the whitelist (`gotcha`/`pattern`/`error-recovery`/`agent-evolution` AND `confidence ≥ 0.50` AND no existing instinct with same id), generates the instinct YAML, updates `proposals.json` status atomically, and logs to `knowledge-log.md` under source `cx-auto-validate`. Proposals tagged `correction`/`user-preference`/`decision`/`workflow` stay pending — they need human judgment. (2) `auto_evolve_detect()` clusters mature instincts (`confidence ≥ 0.70`) by domain via Jaccard similarity (≥ 0.50 over trigger+action tokens, BFS connected components), generates a skill DRAFT at `~/.claude/cortex/evolved/skills/<cluster-id>.draft.md` for any cluster of 3+ instincts not already covered by an existing `~/.claude/skills/*/SKILL.md`. Cluster-id is `cluster-<domain>-<sha1[:8]>` so it's stable across runs but rebuilds when the instinct set changes. The user reviews the draft and either installs (`cp` to `~/.claude/skills/<id>/SKILL.md`) or discards. `run_auto_distill()` pipeline order is now decay → archive → **auto-validate** → auto-promote-to-law → **auto-evolve**, so freshly-validated instincts are eligible for promotion in the same 24h window. `hooks/session-start.py` step 3d replaced the 1-line summary with a multi-line `[CORTEX KNOWLEDGE PIPELINE]` block that shows ONLY non-zero lines (validated, decayed, archived, promoted, evolve drafts, pending review counters). New tests 16-23 in `test_distill_engine.sh`: auto-validate accepts/rejects (gotcha-conf-high, correction-needs-judgment, low-conf, idempotent-existing-instinct), auto-evolve detection (cluster-of-3, rejects-cluster-of-2, rejects-low-jaccard, skips-when-skill-exists). 15 → **23/23 PASS**. `commands/cx-validate.md` and `commands/cx-evolve.md` updated with auto-mode sections. |
| v3.23.1 | 2026-05-01 | **`/cx-status --pipeline` — single source of truth for pipeline activity.** Triggered by Fer asking "debería tener datos o un informe que poder consultar". Sprint 7's auto-validate/auto-evolve write data across 5 dispersed sources (`knowledge-log.md`, `proposals.json`, `auto-distill-candidates.md`, `evolved/skills/`, last-run markers); the new flag aggregates them in one read. New `compute_pipeline_stats(days=14)` in `hooks/lib/distill_engine.py` (+276 LOC, 1252 → 1528) plus `pipeline-stats` CLI subcommand with `--days N` and `--json` flags mirroring the `--impact`/`--reflexes` pattern. ASCII output groups data into 5 sections: VALIDATE (auto/manual accepted, rejected, pending by domain with whitelist tag), PROMOTE (auto/manual promoted, candidates queued, active laws/cap), EVOLVE (auto/manual drafts, pending install), MAINTENANCE (decayed, archived), LAST RUNS (5 marker mtimes). 4 new tests 24-27 in `test_distill_engine.sh` (zero-state, source counters, pending-by-domain, evolve-drafts) — 23 → **27/27 PASS**. `commands/cx-status.md` extended with `--pipeline` flag spec. `commands/cx-router.md` and the FEATURES.md commands table reference the new flag. **Bug-fix-as-side-effect:** Sprint 7 (v3.23.0) had been pushed but never installed locally — Fer's `~/.claude/hooks/cortex/lib/distill_engine.py` was running v3.22.x code with 0 occurrences of `auto_validate_proposals`. The `bash install.sh` run during this release sync-ed it (now MD5 matches repo, 8 occurrences). Forced `run_auto_distill()` confirmed `validated: 0, skipped_validate: 33` is correct behavior — all 33 pending proposals are `workflow`/`user-preference` outside the auto-accept whitelist. |
| v3.23.2 | 2026-05-01 | **Restore zero-deps invariant — drop PyYAML from `yaml_normalize.py`.** `hooks/lib/yaml_normalize.py` had imported `yaml` (PyYAML) since the module was introduced — the only third-party Python dependency in the project. `install.sh` and `install.ps1` deliberately never run `pip install`, so on any machine without PyYAML pre-installed (the default on macOS system Python and a fresh Linux install) the SessionStart normalization pass raised `ModuleNotFoundError`. The error was swallowed by `hooks/session-start.py`'s `try/except` so Cortex still ran, but the auto-repair pass never executed. Refactor: removed `import yaml`; replaced both `yaml.safe_load_all()` call sites with a stdlib helper `_has_broken_dq_line(text)` that detects exactly the failure mode the module fixes (invalid backslash escapes inside double-quoted strings on `REGEX_KEYS` fields — `trigger`, `condition`, `matcher`, `action`). Pre-check in `normalize_all()` skips files with no broken DQ line on those keys; post-rewrite safety in `normalize_file()` refuses to persist if the result still has a broken line. Pre-compiled regex `_DQ_LINE_RE` shared between `_convert_line` and `_has_broken_dq_line`. New `tests/test_yaml_normalize.sh` (12/12 PASS): module imports with `sys.modules['yaml'] = None`, detects/ignores escapes correctly, normalize_file end-to-end + idempotent, normalize_all on sandbox CORTEX_DIR with global+project subdirs, skips archive/, missing dir graceful. **Total tests: 158/158 PASS** (was 146 in v3.23.1 + 12 new). Cross-platform verified: `install.sh` (macOS / Linux) and `install.ps1` (Windows) already respect zero-deps, no `pip install` anywhere — fresh installs on any platform with Python 3.6+ stdlib will no longer hit `ModuleNotFoundError`. |
| v3.28.8 | 2026-05-13 | **Guard — `/cx-analyze` Opus 1M preflight.** Added `Step 0: Preflight — MUST run on Opus 1M` at the top of the Implementation section in `commands/cx-analyze.md`. The command now refuses to proceed unless the active session is `claude-opus-4-7` (or newer Opus) with the `[1m]` context flag. Sonnet/Haiku and Opus without 1M cannot fit the 1.5-3 MB compressed observation payload (≈400-800K tokens) in a single context, which previously caused silent sampling, mid-analysis failures, or workaround sub-Agent fanout that defeats the inline cross-project visibility design. The guard prints a switch-model instruction (`/model claude-opus-4-7[1m]`) and stops before any compression or analysis steps. |
| v3.37.2 | 2026-06-12 | **is_error heuristic false-positive guards.** `detect_is_error()` (observe.py) and `isError()` (session-learner.js) ran the keyword scan on output bodies: 3 WebFetch 200-OK pages mentioning "error" + 1 passing test suite ("FAIL:" labels) became bogus gotchas. Guards: network tools exempt (explicit flag only), structured 2xx responses are success by contract, test-runner output never matches. `test_observe` 10→11, `test_session_learner` 40→42. |
| v3.37.1 | 2026-06-12 | **Rejection tombstones — kills the resurrection loop.** `writeProposals()` consults `proposals-history.jsonl`: ids rejected by an authorized rejecter never re-persist as pending (live proof: same gotcha id rejected 9× across weeks; 90 cleaned proposals resurrected within hours by a stale-code parallel session). `test_session_learner` 39→40. |
| v3.37.0 | 2026-06-12 | **Noise-regression release (overnight audit, AD Codex GPT-5.5, PRs #69 #70 #71).** Corpus audit: 132/203 live instincts (65%) were noise from the error-fix + agent-pattern detectors. (1) `detectErrorResolutions()` requires `err_msg`, derives the trigger from the FAILING input's distinctive tokens (validated against matchTarget, never bare tool name), quotes the error signature, scopes `/Users/`+URL evidence to `scope: project`, attaches `sample_input`/`sample_output`/`err_msg`; fixSummary floor 10→5. (2) `detectAgentPatterns()` trigger scoped to description (was hardcoded `'Agent'`); domain `agent-evolution` AUTO→HUMAN. (3) Per-session repeat cooldown: same id max 2x/session (`.session-injected.json`, reset at SessionStart); suppressed repeats emit `suppress` impact events. (4) Impact inject logging moved below budget enforcement (was inflating funnel metrics). (5) Token killswitch degrades one-by-one instead of flushing the batch. (6) `observe.py` caps 2000/1000→5000/8000; binary blobs → `[binary output omitted]`. (7) Impact rotation floor 15→18 d. (8) `law-cap-stall` knowledge entry on saturated-cap deadlock. (9) Sort id tiebreaker (byte-stable injection). `test_injector` 21→29, `test_session_learner` 36→39, `test_observe` 8→10. |
| v3.36.1 | 2026-06-10 | **Signal quality (multi-agent audit 2026-06-10).** (1) `CATEGORY_DOMAINS` missing 8+ live category labels — `error-recovery` (emitted by the learner itself; 23 live instincts silently filtered in stack-detected projects), `agent-evolution`, `correction`, `coupling`, `agent-quality`, `meta`, `tool-preference`, `release-engineering`, `claude-code-tooling`, `claude-behavior`, `reflex` now always pass. (2) Error-fix detector: new `summarizeFixInput()` replaces raw tool-input JSON (file_path+old_string blobs cut mid-string, 28 live single-use gotchas) with semantic summaries (command / basename / description); no-content pairs skipped (16 live hollow "try: " proposals). (3) `writeProposals()` quality gate rejects actions < 40 chars or dangling "try:". (4) `parseInstinctYaml()` skips hollow actions (< 30 chars or "try:"-terminated) — corrupted YAMLs on disk never inject. (5) `updateMemoryStats()` refreshes `total_projects` (drift: said 11, 31 dirs). (6) Domain-dedup skips logged under `CORTEX_DEBUG`. (7) `parseYamlFrontmatter()` resolves block scalars (`|-`/`|`/`>-`) — five live multiline-action instincts injected the bare "|-" indicator pre-fix. `test_injector.sh` 18 → 21, `test_session_learner.sh` 32 → 36, `test_yaml_utils.sh` 13 → 16. |
| v3.36.0 | 2026-06-10 | **Storage hygiene (multi-agent audit 2026-06-10).** Live install had hit 134 MB (62 MB `impact.jsonl`). (1) `impact_log.py` live window 30 → 15 d, env-overridable `CORTEX_IMPACT_ROTATION_DAYS`, floor 15 (consumers read ≤ 14 d); rotated events still archived, never deleted. (2) `storage-rotation.js` caps four more unbounded artifacts inside the same 24 h gate: `proposals-history.jsonl` ≥ 3 MB rename-rotated to `proposals.archive/` under the shared writer lock, `knowledge-log.md` ≥ 2 MB → `knowledge-log.archive/`, `daily-snapshots/`+`daily-summaries/` keep newest 60 files, `.fire-once/` markers > 30 d pruned. `test_storage_rotation.sh` 28 → 46. |
| v3.35.2 | 2026-06-10 | **Runtime-audit fixes (7-subagent sweep, #56 follow-up).** (1) Timeline dead since 2026-05-27: `detectCommandUsage` never saw `/cx-*` Skill obs because project-less sessions write to the GLOBAL stream (`pid=global`, 114 obs there vs 4 per-project) — now scans it with a `.timeline-cursor` (idempotent). Test 8 sandboxed + new 8b (`test_session_learner.sh` 28 → 32). (2) `_proposal_to_instinct_yaml` emitted the first tag INLINE after the key (`tags:   - 'x'`) — strict-invalid YAML, 27 live files shipped malformed; first item now on its own line (Test 52). (3) #56.1: `_derive_law_line` cap 120 → 200 + word-boundary cut (Test 51; `test_distill_engine.sh` 50 → 52). (4) `session-learner.log` now 0600 (was 0644). (5) `commands/cx-stop.md` recovered into the repo (existed only deployed; reinstall would lose it) + `EXPECTED_COMMANDS` 21 → 22. Runtime data healed in the same sweep (not repo code): 114/114 instinct YAMLs now parse in BOTH the engine parser and strict YAML (21 had unclosed frontmatter → never injected; 4 had no `action:` → injected nothing; 27 inline-tags; 1 unescaped quotes), advisor-escalation ↔ delegate-by-model-routing tiebreaker line added. |
| v3.35.1 | 2026-06-09 | **#56.2 — storage rotation wired (was dead code; `impact.jsonl` hit 80 MB live).** `impact_log.py rotate` and `cross-day-tracker.js prune()` existed but no hook ever called them. New `hooks/lib/storage-rotation.js::maybeRotateStorage()` called from `session-learner.js` Step 5f (Stop): size-gated (impact ≥ 10 MB, tracker ≥ 1 MB; env `CORTEX_IMPACT_ROTATE_MB`/`CORTEX_TRACKER_PRUNE_MB`), max once per 24 h (marker `.last-storage-rotate`), python3 spawned **detached** so the Stop 15 s budget is never at risk (`CORTEX_ROTATE_SYNC=1` for tests). `rotate()` rewritten rename-first, loss-proof under concurrent lock-less JS writers: pre-scan no-op → atomic rename into `impact.archive/` → recent events re-appended in ≤ 64 KB line-aligned chunks on `O_APPEND` fd → static archive rewritten with only old events; crash at any step leaves every event in ≥ 1 of the 2 files. New files 0600. New `tests/test_storage_rotation.sh` (28). `test_impact.sh` 65/65 green on the rewrite. |
| v3.35.0 | 2026-06-07 | **#49 — `/cx-backfill --apply` re-enabled with a cross-runtime write lock (closes the P0 data-loss race).** The Node Stop hook appended to `proposals-history.jsonl` (`proposals-storage.js::_appendHistory`) and flushed `instinct-tracking.json` (`session-learner.js::_flushTracking`) with **no lock**, so a backfill `os.replace` could silently drop lines Node had just written; the Python-only `fcntl.flock` from v3.34.3 (#45) could not serialize against Node. **Fix:** shared `O_EXCL` lockfile `~/.claude/cortex/.proposals-history.lock` coordinated by both runtimes — new `hooks/lib/file_lock.py` (`os.open(O_CREAT\|O_EXCL)`) + `hooks/lib/file-lock.js` (`fs.openSync(path,'wx')`), zero deps, cross-platform. Lock features: stale detection (mtime + PID-alive), per-lock nonce verified on `release` (a paused owner never unlinks a stale-stealer's reclaimed lock), atomic rename-to-claim reclaim (two stealers can't both win). `_cmd_backfill` gate removed; backfill writes both files via `_atomic_write` (tmp cleanup) and keeps history/tracking a consistent pair (restore-from-backup if the tracking write fails after history was replaced); tracking gains the same `(size, mtime_ns)` guard as history. AD-surfaced degrade: a Stop-hook writer that can't acquire within 12 s does NOT write without the lock (keeps appends in `proposals.json` / skips the snapshot flush) rather than reintroduce the race. New `tests/test_file_lock.sh` (11, incl. Python↔Node cross-runtime + 8-way rename-to-claim race = exactly 1 winner) and `tests/test_backfill_concurrency.sh` (30: 5 race rounds zero-loss + §B serialization-proof `wait_ms≥600`). 3 AD rounds (Codex GPT-5.5). Design: `docs/ISSUE-49-PLAN.md`. |
| v3.34.3 | 2026-06-06 | **Security hardening — issues #45/#47/#48.** #47: `log/*.jsonl` (skip-breakdown, security-events, timeline) now created `0o600` operator-only (were `0644`) — `chmod` after each write in Python + JS, new `test_security` case, live logs re-permed. #45: new `_write_locked` decorator serializes `manual_swap_promote` / `demote_law_to_domain` / `manual_promote_detector` under the blocking advisory `LOCK_FILE` (new `test_distill_engine` Test 50); the Stop hook's cross-runtime append stays issue #49. #48: `commands/cx-promote.md` documents the `--auto` trust boundary (no second factor; local operator is the boundary). |
| v3.34.2 | 2026-06-05 | **Universality opt-in for law promotion (Criteria 8).** `auto_promote_to_law` only auto-promotes instincts with explicit `law_eligible: true`; everything else (however statistically mature) routes to `auto-distill-candidates.md` for human review via `/cx-distill` (already surfaced as a SessionStart "Pending review" reminder). Closes the gap that let contextual project/stack instincts silently inflate the always-injected Core — the bug behind needing to mark 14 instincts by hand. `commands/cx-distill.md` §3a documents the engine enforcement. Tests: `test_distill_engine` +1 (49), promotion fixtures updated to seed `law_eligible: true`. |
| v3.34.1 | 2026-06-05 | **Anti-drift guard + ruido podado (la raíz de "Cortex a medias").** New `session-start.py:check_deploy_drift()` warns at SessionStart when the deployed system is behind the repo (`install.sh` writes `~/.claude/cortex/.repo-path`; compares deployed `version` vs repo `NEW_VERSION`) — closes the failure mode where repo edits never get deployed and silently strand new code. New `tests/test_deploy_drift.sh` (6 cases) in `.githooks/pre-push`. New opt-in `noisy_detectors_off` config flag gates the `correction` + `file-coupling` detectors (lifetime ~0% accept → pure backlog) without touching error-fix/agent. Data hygiene: noisy non-security reflexes + junk-`action` gotcha instincts archived. |
| v3.34.0 | 2026-05-31 | **Core/Domain law split — Phase 2 (`demote_law_to_domain` + `/cx-distill --demote`).** A Domain law can be demoted back to the relevance-gated instinct pool: stops injecting at every SessionStart (~40 tok saved each), re-joins the PreToolUse injector, surfaces only when its `trigger` matches. Reversible (`.txt` → `laws/archive/`), fail-safe (refuses to demote a law with no instinct-yaml backing or no trigger — never invents one). New `law_eligible: false` frontmatter flag + `auto_promote_to_law` guard prevents re-promotion. New `tests/test_law_tier.sh` (14 cases incl. an e2e gate asserting the real `injector-engine.js` re-injects a demoted law via its trigger — satisfies `gotcha-ad-por-fase-no-sustituye-e2e`); wired into `.githooks/pre-push`. Design: `docs/DESIGN-LAW-INJECTION-V2.md`. |
| v3.33.1 | 2026-05-31 | **`max_laws` config desync fix + Core/Domain law-split design.** `core/memory.template.json` and the FEATURES config table declared `max_laws: 10` while the engine enforced `LAW_MAX_ACTIVE = 15` since v3.32.0 — new installs seeded a stale `max_laws: 10`. Both synced to 15 (runtime unaffected; the engine constant always governed). New `docs/DESIGN-LAW-INJECTION-V2.md`: design for splitting laws into Core (always-injected, ~8) vs Domain (relevance-injected via the existing PreToolUse injector), grounded in live-Cortex curation (1714 proposals-history rows, 300 tracked instincts, 170 yaml-orphans) and an honest comparison vs Sinapsis v4.5 (skill-router routes *skills* not knowledge; per-injection token cap + domain dedup are the 3 transplantable ideas). No code behavior change. Tests: integrity 14/14, security 8/8. |
| v3.32.0 | 2026-05-27 | **Sprint 9 PR2 — autopilot foundation: HUMAN→AUTO promotion gate + laws cap raise + deprecation policy.** (§4.4) `hooks/lib/distill_engine.py` new `can_promote_to_auto(source)` with 4 statistical gates (n ≥ 20 reviewed, accept_rate ≥ 70 %, distinct_sessions ≥ 3, critical_count == 0) reading `~/.claude/cortex/proposals-history.jsonl` (AD P0-1). n=10 visibility tier surfaces partial progress without enabling promotion (AD P1-2). `manual_promote_detector(source, confirm=True)` is the ÚNICO writer of `.promoted-detectors.json` (AD P0-4); engine never writes it. `_load_promoted_detectors` is fail-closed (any parse / schema / source-regex violation → empty set + audit log to `~/.claude/cortex/log/security-events.jsonl`). New `rejection_category` enum (`security` / `breaking` / `injection` / `noise` / `other`) with ES + EN keyword heuristic fallback for legacy rejects (AD P1-6). `auto_validate_proposals` honors `promoted_sources` in BOTH HUMAN-domain skip checks (second skip fix surfaced by Assert 10 of the e2e gate — validates AD P1-5 / instinct gotcha-ad-por-fase-no-sustituye-e2e). `commands/cx-promote.md` extended with "Sub-mode --auto"; `commands/cx-validate.md` Step 4b extended with `rejection_category` ask. (§4.5) `LAW_MAX_ACTIVE` 12 → 15 (token cost ~480 → ~600 baseline; quality gates unchanged). New `_find_least_impactful_law` (lowest `useful_14d / (1 + noise_14d)`, tie-break by oldest mtime, age guard `LAW_DEPRECATE_MIN_AGE_DAYS=7` per AD P1-3, healthy-cohort guard returns None when ratio > 1.0). New `manual_swap_promote(new_iid, deprecate_iid)` with explicit in-memory rollback if the new-law write fails after the old was unlinked (AD P1-7). Cap-check `failed_reason` now suggests the swap command line. Doc sync (9 sites: README × 3, FEATURES × 3, cx-distill × 2, session-start docstring) plus symbol-anchor replacement (`distill_engine.py:83` → `distill_engine.py:LAW_MAX_ACTIVE`) to prevent future drift. `commands/cx-distill.md` extended with "Sub-mode --swap". (§4.7 / AD P1-5) `git mv tests/test_v329_acceptance.sh tests/test_v332_acceptance.sh` (blame preserved) + 3 references updated in `.githooks/pre-push`. New asserts 9 (marker fail-closed e2e) + 10 (full promotion cycle: history → can_promote → manual_promote → marker → auto_validate ACCEPTS HUMAN proposal). **Tests: `test_promotion_gate.sh` NEW 8/8, `test_distill_engine.sh` 41 → 47 (+6 §4.5 + Test 10 updated to seed 15 laws), `test_v332_acceptance.sh` 9 → 11 (+2 e2e). Baseline: 456 (v3.31.2) → 472 PASS (28 suites).** Plan: `docs/SPRINT-9-AUTOPILOT.md` v3 FINAL. Sprint 8 §5.1/§5.2 (`analyze_engine.py` + auto-analyze trigger) **deferred to v3.33+** per AD P0-2/P0-3. |
| v3.31.2 | 2026-05-26 | **Sprint 9 PR1 — 3 cleanup bug fixes, no behavior change in detector signal.** (§4.1.A) `hooks/lib/distill_engine.py:auto_promote_to_law` narrows the §4.16 grandfather clause to fire ONLY when (entry absent) OR (`sessions == []` explicit). Previously any tracking-entry that wasn't a dict was treated as missing, which hid corruption shapes (`sessions: null`, missing `sessions` key) behind a successful promotion. AD P1-1 absorbed. Tests `test_distill_engine.sh` +5 cases (3 positive: entry-absent / sessions-[] / sessions-populated → promote; 2 negative: sessions-null / missing-sessions-key → block, corruption guard). (§4.1.B) `auto_validate_proposals` now returns a `skip_breakdown` Counter (high-cardinality reasons `orphan-domain:*` / `unsafe-trigger:*` / `validate_instinct:*` bucketed by prefix; `low-confidence` / `already-instinct` / `needs-human-judgment` pass through) and appends one JSONL row per run to `~/.claude/cortex/log/auto-validate-skips.jsonl` (rotated to `.1` at 512KB, mirror of session-learner.js:60-76). Logging is best-effort: any `OSError` is swallowed so logging never breaks auto-validate. AD P1-4 absorbed (no 24-48h window — root-cause investigation of the 42 stuck AUTO pending deferred to v3.33+ once 7d of logs exist). Tests +2 cases. (§4.1.C) `hooks/lib/dream_cycle.py` new `archive_proposals_backups_if_due(cortex_dir, repo_root=None, days=7)` reads/writes `.last-proposals-archive` marker, auto-detects repo_root, falls back to `script-not-installed` (no crash) when running in an installed setup without the repo `tests/` dir, invokes the shell script with `CORTEX_DIR` exported and a 30s timeout, touches the marker only on `returncode 0` so failed runs retry next cycle. `commands/cx-dream.md` grows a Step 3d that imports the helper and shows one of three outcomes. Tests `test_dream_cycle.sh` +2 cases (first-run archives 3 backups + marker touched + tarball present; second-run within 7d → cooldown skip, .bak file untouched). **Baseline: 447/447 PASS pre-PR1. After PR1: 456/456 PASS (+9 cases).** Plan: `docs/SPRINT-9-AUTOPILOT.md` v3 FINAL (AD Codex GPT-5.5 round 1 absorbed: 4 P0 + 7 P1 + 3 P2 findings). |
| v3.31.1 | 2026-05-20 | **Bugfix — `load_laws()` truncated to 10, breaking v3.29.2 cap raise to 12.** `hooks/session-start.py:55` `sorted(LAWS_DIR.glob('*.txt'))[:10]` was hard-coded since pre-v3.29.2 when the engine cap was 10. After v3.29.2 raised `LAW_MAX_ACTIVE` to 12 in `hooks/lib/distill_engine.py:83`, the loader kept truncating to 10 alphabetically, so the 2 laws sorting last (`pattern-test-after-change`, `project-bootstrap` in the operator's install) were never injected at SessionStart. Engine `_active_law_count()` and `auto_promote_to_law()` correctly used the new cap, masking the bug — `/cx-status` showed 12 laws but only 10 reached the session context. **Fix:** removed the `[:10]` slice; loader now reads all `*.txt` files in `laws/`. Cap is enforced upstream by the distill engine, so removing the loader cap is safe (idempotent — `_active_law_count()` would reject any 13th promotion). Docstring updated to `"Read all active law files. Engine caps total at LAW_MAX_ACTIVE=12 (see hooks/lib/distill_engine.py:83)."`. **Doc sync** for the v3.29.3 catch-up that missed `commands/cx-distill.md` lines 16 + 99 (`max 10` → `max 12` with cross-reference to `distill_engine.py:83`). HTML audit reports under `docs/cortex-v3*` left intact (timestamped historical artifacts). Internal `docs/CORTEX-AUDIT.md` (gitignored) also synced locally. **No detector signal changes — Sprint 8 observation window protected.** |
| v3.31.0 | 2026-05-17 | **Session bridge redesign — adopts Sinapsis context.md format.** `hooks/session-learner.js:writeContextFile` rewritten: Spanish narrative (`## Proyecto:`), basenames-only (deduped, max 6), `/cx-analyze` CTA on errors, ≤ 500 bytes by design (was 2KB+ telemetry blob with full paths and tool counts). `hooks/session-start.py:inject_context_bridge` reads full file (no longer first 10 lines space-joined) and wraps with `[project-context]` semantic tag. `inject_eod_resume` wraps with `[eod-summary YYYY-MM-DD]`. `hooks/lib/cortex_utils.py:sanitize_injection` regex changed from `[\x00-\x1f\x7f]` to `[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]` — preserves `\t \n \r` so multiline injections keep structure (fallback duplicate in session-start.py patched in lockstep). New `cleanup_corrupted_context_files()` in `hooks/lib/dream_cycle.py` rotates legacy English-format files (`## Project:`) to `.legacy-YYYYMMDD` backups, wired into `/cx-dream`. New `bin/cleanup-context-once.sh` standalone migration script (format-based, not size-based — safe in any order). New `tests/test_context_bridge.sh` 12 cases (writer ≤500 bytes, Spanish keywords, gotcha CTA conditional, basename cap/dedup, Windows paths, reader prefix, newlines preserved, cleanup rotate/preserve, idempotency, EOD tag). Wired into `.githooks/pre-push`. Pipeline de aprendizaje intacto: zero changes to detectors, laws, instincts, dream cycle main, impact funnel. v3.30.0 reserved for Sprint 8 detector overhaul. Tests: `test_security` 7→8/8, `test_context_bridge` 12/12, `test_dream_cycle` 38/38, `test_integrity` 14/14. Adversarial Defense PASS (Sonnet + Codex GPT-5.5 dual review, two blockers identified and resolved before code). |
| v3.29.5 | 2026-05-17 | **Safety hotfix — 5 fixes, NO detector signal changes (protects Sprint 8 observation window).** (F1) `hooks/lib/distill_engine.py` — new `KNOWN_DOMAINS = VALIDATE_AUTO_DOMAINS ∪ VALIDATE_HUMAN_DOMAINS`. Proposals whose `domain` falls outside this union were previously skipped with `needs-human-judgment` but stayed `pending` forever (invisible to `/cx-validate`, no exit path); now they get HELD with `hold_reason="orphan-domain:<name>"` so the operator sees the gap and the engineering team gets a signal. (F2) `hooks/lib/validate_instinct.py` — extracted `validate_yaml_content(content)` pure function; `distill_engine.auto_validate_proposals` now calls it BETWEEN `_proposal_to_instinct_yaml()` and `_atomic_write()`. Pre-v3.29.5 a proposal with `"ignore previous instructions"` or `"you are now…"` in `action` became an active instinct without barrier — the validation module existed but was only used as a CLI tool. (F3) `hooks/lib/cross-day-tracker.js` — `appendDetection()` no longer mutates `_trackerCache` in-session. Pre-v3.29.5 a proposal emitted in the same Stop saw the just-added entry via Jaccard ≥ 0.70 trigger matching, counted today twice, and reported inflated `dayCount`. Effect at scale (Sprint 8 §4.8 reactivation, 1077-proposal first run): dozens of HUMAN-gated proposals received tier-1 cross-day boost without genuine cross-day evidence. Dedup against Stop-hook re-emit is preserved via a separate per-session memo `_appendedThisSession`. (F4) `hooks/observe.py` — new `HOME_PATH_RE` normalizes `/Users/<x>/...` and `/home/<x>/...` to `~/...` inside `scrub_secrets`. Pre-v3.29.5 the error-fix detector copied raw `input` (containing absolute cross-project paths) into proposal `action` text, leaking the username into proposals.json. Path structure preserved so `extractFilePath()` + `path.basename()` continue to work. (F5) `hooks/lib/proposals-storage.js` (NEW) — proposals.json archive split. `migrateAcceptedRejectedToHistory()` one-shot migration (idempotent via `.migrated-to-history.jsonl` flag) + `splitForPersist()` per-Stop helper. Production file had 1,206 entries spanning weeks, growing monotonically; new layout keeps `proposals.json` to live (pending + held) and appends terminal-state (accepted + rejected) to `proposals-history.jsonl`. Tests: `tests/test_v329_5_safety.sh` (9/9 PASS) + `tests/test_cross_day_tracker.sh` extended (+2, 14/14 PASS). Regression: `test_security` 7/7, `test_dream_cycle` 38/38, `test_integrity` 14/14. **Sprint 8 observation window protected — zero detector logic touched (no changes to `detectErrorResolutions`, `detectUserCorrections`, `detectFileCoupling`, `detectAgentPatterns`, `detectAgentSubtypes` or the boost logic of `applyCrossDayBoost`).** |
| v3.29.4 | 2026-05-16 | **Hardening pass v2 — 9 fixes (5 originales + 4 AD Codex GPT-5.5).** (a) `hooks/observe.py:450` MD5 → SHA256 — under FIPS-enforced Python (`hashlib.md5` raises `ValueError`) the top-level except was silently dropping every observation. (b) `hooks/session-learner.js:122` `shortHash()` MD5 → SHA256 — same FIPS failure mode in Node, would abort the Stop hook silently. (c) `hooks/observe.py` new `_scrub_git_remote()` strips `user:token@` from HTTPS remotes before they reach `registry.json` / project cache / `project_id` hash, where `scrub_secrets` never inspects. (d) `hooks/session-learner.js:1387` `evalErrorMonitor` now gates `ev.error_pattern` through `isSafeRegex()` from `lib/regex-guard.js` (parity with the existing guards at `:912` / `:921`); a malformed instinct trigger could previously hang the Stop hook during impact-funnel evaluation. (e) `hooks/observe.py:108,574` `write_with_lock()` accepts an optional `pre_write_fn`; `main()` now runs `archive_if_needed` INSIDE the same lock so a concurrent appender cannot write into a just-renamed file (and the archive timestamp switched to `datetime.now(timezone.utc)` for parity with the rest of the file). (f) `hooks/session-learner.js:477` `slugifySubtype()` — pre-v3.29.4 the second `&&`-operand recomputed `slug` so the check was a tautology and sanitized-but-collision-prone inputs (`foo/bar` and `foo-bar` both → `foo-bar`) returned the same id; corrected to `slug === lower`, hash-suffix path now fires when characters were stripped. (g) `hooks/lib/distill_engine.py:752` audit message now uses `LAW_MIN_PROJECTS` constant instead of stale literal `"3"` (lowered to `1` in v3.24.0). (h) `hooks/lib/distill_engine.py:241` `_atomic_write` wrapped in try/finally so a failed `os.replace` no longer leaks `.tmp.PID` files (pattern already in `observe.py:atomic_write_json`). (i) `hooks/session-learner.js:1576` `knowledge-log.md` append now logs to stderr under `CORTEX_DEBUG` instead of swallowing the failure entirely; tmp+rename rejected here because concurrent Stop hooks tolerate interleaved single-line appends but would lose updates under unlocked tmp+rename. (j) `skills/cortex/SKILL.md` header bumped `v3.28.5` → `v3.29.4` (3-release drift from prior frontmatter scan). Existing user installs update on next `bash install.sh`. |
| v3.29.3 | 2026-05-16 | **Hardening pass — 3 code blockers + doc sync.** (a) `hooks/observe.py:108` `write_with_lock()` Windows fallback rewritten — pre-v3.29.3 the `msvcrt.locking` call took the lock on the data file's own FD and `seek(0)` before `LK_UNLCK`, which on cross-platform installs could corrupt the append cursor for `observations.jsonl`. POSIX (`fcntl.flock`) path was already correct and is unchanged. (b) `hooks/injector.sh:7,24` dropped `set -e` (any failure in `mktemp`/`chmod`/redirect would have exited non-zero, violating the documented exit-0-always contract) and switched `echo "$INPUT_JSON"` → `printf '%s\n'` (echo interprets payloads starting with `-` as flags). Both critical steps gained explicit `\|\| exit 0`. (c) `hooks/session-learner.js:785-878` `updateInstincts()` refactored — `instinct-tracking.json` is now read ONCE before the loop and written ONCE after, instead of one full atomic read-modify-write per matched instinct. New helpers `_mirrorToTrackingMem()` + `_flushTracking()` replace the old `_mirrorToTracking()`. Two concurrent Stop hooks could previously lose tracking writes since the operation was unlocked. (d) Doc sync: `README.md` (3 sites) and `docs/FEATURES.md` (2 sites) updated from `Laws (max 10)` → `(max 12)` after the v3.29.2 cap raise. Token-budget rows updated to ~480 tok (12 laws × ~40). (e) `CORTEX_AUTODISTILL_OFF` documented as the third Sprint 8 kill switch (it lives in `hooks/lib/distill_engine.py:1396`, alongside `CORTEX_OBSERVE_OFF` and `CORTEX_DETECTORS_OFF`). Existing user installs update on next `bash install.sh`. |
| v3.29.2 | 2026-05-16 | **Raised `LAW_MAX_ACTIVE` cap from 10 to 12.** `hooks/lib/distill_engine.py:82` — was the bottleneck blocking 25 conf≥0.95 candidates queued in `auto-distill-candidates.md` after Sprint 8 (v3.29.0) cleaned the detectors. Quality gates untouched (`LAW_THRESHOLD_CONF=0.95`, `LAW_SUSTAINED_DAYS=14`, `LAW_MIN_DISTINCT_SESSIONS=3`, `LAW_MAX_NOISE_14D=0`). Net cost: +80 tok/session baseline (2 extra laws × 40 tok). Existing user installs update on next `bash install.sh`. |
| v3.29.1 | 2026-05-16 | **Removed `/cx-stop` command.** Unused in practice — Stop hook fires automatically when Claude Code closes a session normally, and PreCompact hardening in v3.29.0 (§4.15) closed the `/compact` data-loss gap that was `/cx-stop`'s only real use case. Forward-only: the command file is deleted, and 10 sites in the catalog/installer/tests are updated. Existing user installs lose `~/.claude/commands/cx-stop.md` on next `bash install.sh` (clean removal). Files touched: `commands/cx-stop.md` (deleted), `commands/cx-router.md`, `core/claudemd-section.md`, `hooks/session-start.py` (commands hint), `skills/cortex/SKILL.md` (frontmatter description + `### Commands (21)` → `(20)` + table row), `README.md` (commands count + table row + tests line), `docs/FEATURES.md` (this entry + tests table), `tests/test_install.sh` (count 21 → 20), `tests/test_install_ps1.ps1` (required-sources list), `tests/test_v328_operational.sh` (removed `cx-stop: session-learner exits 0` test, 5 → 4 cases). |
| v3.29.0 | 2026-05-16 | **Sprint 8 — Detector overhaul + autopilot foundation.** Largest single release since Sprint 5. (a) `distill_engine.py`: `coupling` + `agent-quality` registered in `VALIDATE_HUMAN_DOMAINS` (pre-v3.29 both were orphans — detectors emitted them but no whitelist accepted them, every proposal fell through `needs-human-judgment` forever); new `_detect_unauthorized_rejections()` ghost guard runs on every `auto_validate_proposals()` pass, restoring proposals rejected by identities not in `VALIDATE_AUTHORIZED_REJECTERS` (specifically `cx-validate-auto`, the bulk-reject ghost from 2026-05-05, see `docs/GHOST-CX-VALIDATE-AUTO.md`); new `LAW_MIN_DISTINCT_SESSIONS=3` multi-session promotion gate with defensive `_count_distinct_sessions()` reader + grandfather clause for pre-v3.29 high-confidence instincts missing tracking entries (source: Sinapsis pattern, see `docs/SINAPSIS-COMPARISON.md`). (b) `session-learner.js`: `detectRepetitions` + `detectWorkflowChains` retired (deleted code, 2 helper local + tests too); `detectFileCoupling` rewritten with regex-on-tool-input trigger `Edit.*(?:f1|f2)`, conf 0.55, `scope:'project'`, imperative action; `detectUserCorrections` rewritten with `domain:'correction'`, conf 0.55, scope project, imperative action; `detectAgentSubtypes` rewritten with conf 0.50, imperative action; `detectAgentPatterns` floor raised 3→4 (clears the 0.55 borderline); `CORTEX_LEGACY_DETECTORS` env var retired; new `CORTEX_DETECTORS_OFF` kill switch. (c) `observe.py`: `CORTEX_OBSERVE_OFF` kill switch — exits before any write. (d) `session-start.py`: `[ACTION]` banner counts only `VALIDATE_AUTO_DOMAINS` (HUMAN-gated proposals stop nagging). (e) `precompact.py` hardened — `CORTEX_OBSERVE_OFF` + `CORTEX_DETECTORS_OFF` honored, `CORTEX_SESSION_ID` propagated to spawned learner as env var, full try/except wrap for fire-and-forget. (f) New `hooks/lib/regex-utils.js` with `escapeRegex()` dedupe helper. (g) New ops scripts: `tests/cleanup_retired_instincts.sh` (move orphan `repeat-*` / `workflow-*` YAMLs to archive), `tests/archive_proposals_backups.sh` (bundle `proposals.json.bak*` into timestamped tar.gz + SHA-256). (h) Tests: 366 → 433 PASS (+67). New suites: `test_kill_switches.sh` (10), `test_session_start.sh` (4), `test_precompact.sh` (11), `test_e2e_pipeline.sh` (10), `test_v329_acceptance.sh` (9 invariants, pre-ship gate wired in `.githooks/pre-push`). (i) Docs: `docs/GHOST-CX-VALIDATE-AUTO.md` (archaeology), `docs/SINAPSIS-COMPARISON.md` (spike), `docs/SPRINT-8-DETECTOR-OVERHAUL.md` plan v7, `docs/V3.27-GATES-CLOSED.md` deleted (Sprint 5 + v3.27 gates closed). |
| v3.28.9 | 2026-05-15 | **Detector cleanup + Sprint 5/v3.27 gate closure.** Three changes in one release: (1) `hooks/lib/impact_log.py` `gate_recommendation()` switched from `useful_ratio_user`/`health_ratio_user` to aggregate `useful_ratio`/`health_ratio` — reflex feedback is always written with `source="agent"` so the previous formula made Sprint 5 Gate 1 structurally unable to ever PASS even when `reflexes.json` showed healthy ratios (e.g. bash-grep-use-grep-tool useful=60 noise=3 ratio=20× was invisible). The aggregate ratio treats agent self-evaluations against deterministic evaluators (tool-substitution, error-monitor) as valid signal. Closes Sprint 5 Gate 1. (2) `hooks/session-learner.js` gates 5 detectors with structural bugs behind `CORTEX_LEGACY_DETECTORS=1` (default OFF): `detectRepetitions` (conf=0.30 sub-floor, descriptive action), `detectUserCorrections` (domain user-preference human-gated), `detectWorkflowChains` (trigger only first tool of trigram), `detectAgentSubtypes` (domain `agent-quality` orphaned — not in any `distill_engine.py` whitelist), `detectFileCoupling` (trigger `Edit\|f1\|f2` is malformed regex alternation + domain `coupling` orphaned). `detectErrorResolutions`, `detectAgentPatterns`, `detectTimeOfDayPatterns`, `detectCommandUsage` stay active. (3) Bulk-rejected stale pending proposals from the disabled detectors with reason `v3.28.9-detector-disabled`. Docs: `docs/SPRINT-5-PENDING-GATES.md` deleted (Sprint 5 closed); `docs/V3.27-DETECTOR-GATES.md` renamed to `docs/V3.27-GATES-CLOSED.md` with closure summary; `docs/SPRINT-8-DETECTOR-OVERHAUL.md` added with full diagnosis (broken Gate 1 metric, 5 noisy detectors, orphan `cx-validate-auto` script) and forward plan for end-to-end pipeline automation. `CLAUDE.md` Pending validation section replaced with Active sprint pointing to Sprint 8. |
| v3.28.7 | 2026-05-09 | **Fix — collector script fd leak + unsafe cast.** (1) All 8 bare `open()` calls in the `cx-status` collector script replaced with `with` context managers (laws glob, registry JSON, YAML flat parser, obs count loop, reflexes JSON, settings JSON, last-obs readlines, tracking JSON). Eliminates file-descriptor leak on large registries. (2) `int(sess)` cast in tracking parser hardened: `(int(sess) if isinstance(sess, (int, float)) else 0)` — previously raised `TypeError` on dict/None, swallowing all tracking data silently inside the outer `try/except`. No behavior change on valid data. |
| v3.28.6 | 2026-05-09 | **Perf — `/cx-status` single-pass collector.** Replaced 3-round multi-step data collection with one Python3 heredoc script that gathers all 7 dashboard sections (laws, instinct YAMLs, project obs/inst counts, reflexes, health checks, tracking top-10, evolved counts) in a single Bash call and outputs JSON. Root cause of prior latency: sequential tool-call rounds + PyYAML import failure requiring a second attempt. Fix: regex flat-YAML parser (no third-party deps), one `python3 << 'COLLECTOR'` block covers everything. `commands/cx-status.md` implementation section rewritten; same dashboard output, same flags, same render format. |
| v3.28.5 | 2026-05-09 | **Hotfix — AD GPT-5.5 audit found 5 schema/security bugs.** (1) `detectRepetitions` emitted `source: 'session-learner'` plain while other 5 detectors used `'session-learner:X'` — 210 production proposals had inconsistent source. Fixed to `'session-learner:repetition'`. (2) `detectAgentSubtypes` + `detectFileCoupling` (v3.27.0) omitted `status: 'pending'` field; `writeProposals` dedup logic (`existing.status !== 'pending'`) treated `undefined` as truthy → legacy proposals couldn't be updated, `/cx-validate` filter by `status==='pending'` made 129 file-coupling proposals invisible. Both detectors now emit `status: 'pending'`. Runtime backfill: 129 proposals updated. (3) `detectAgentSubtypes` security — `subagent_type` user-controlled value embedded raw in id (which becomes YAML filename). New `slugifySubtype()` allowlists `[a-z0-9_-]`, caps 40 chars, hashes residue. Closes path-traversal vector. (4) `_prune_cross_day_tracker()` Python port of v3.28.4 dedup was missing — Node and Python prune paths now equal. (5) `write_daily_snapshot` `observations` field misnamed (was lifetime, named like daily) — split into `observations_total_active` + `observations_on_date` (filtered by `ts` startswith `last_date`). Tests: `test_detectors_v327.sh` 12 → 13 PASS. Known limitations documented for v3.29.0: detectFileCoupling sid scope, time-of-day race, rejected retention. |
| v3.28.4 | 2026-05-09 | **Hotfix — `applyCrossDayBoost` was duplicating tracker entries 21×.** Discovered immediately after v3.28.3 install via the v3.27 detector gates baseline: `cross-day-tracker.jsonl` had grown to **15,061 entries with only 703 distinct pattern_ids in a single day** — 21× expected size. Root cause: `applyCrossDayBoost()` unconditionally appended on every call, but the Stop hook re-processes observations on every session close, re-emitting the same proposals. **Fix:** `same-day same-pattern_id` guard before `appendDetection()`. Distinct-date counting (the boost logic) is unaffected — first append of the day is always made, so `cross_day_count` and the +0.05/+0.10/+0.15 tiers behave identically. Bonus: `prune()` now also compacts same-day duplicates from legacy data, so existing bloated trackers self-heal on next `run_auto_distill()` cycle. `tests/test_cross_day_tracker.sh` 10 → 12 PASS. |
| v3.28.3 | 2026-05-09 | **Doc — measurement gates for v3.26-v3.27 detectors.** New `docs/V3.27-DETECTOR-GATES.md` with 5 gates (A-E) tracking whether `detectAgentSubtypes`, `detectFileCoupling`, `detectTimeOfDayPatterns`, and `applyCrossDayBoost` produce useful signal vs noise. Each gate has a pass criterion + bash one-liner + action plan if FAIL. Re-check date 2026-05-11. Referenced from `CLAUDE.md` "Pending validation" so it surfaces at SessionStart until all gates pass. Non-destructive — no code change to detectors. |
| v3.28.2 | 2026-05-09 | **Doc sync — README + SKILL.md catch up to v3.28.x.** `skills/cortex/SKILL.md` header bumped from stale `v3.19.2` → `v3.28.1` (drift across 9 releases). `README.md` `## Commands (20)` → `(21)` with `/cx-stop` row added. `README.md` Tests section rewritten — listed all 20 bash test suites + 1 PowerShell suite (was listing 11 outdated suites). New `test_install_ps1.ps1` test 9b: asserts `cross-day-tracker.js`, `cx-stop.md`, `test_cross_day_tracker.sh`, `test_detectors_v327.sh`, `test_v328_operational.sh` source files all present in repo (so Windows installer copies them). PS1 test count 9→10. Sandbox install verified end-to-end on macOS: 21 commands, 14 lib files, all detectors callable, `write_daily_snapshot` writes JSON. |
| v3.28.1 | 2026-05-09 | **Hotfix — CI green after v3.28.0 catalog drift.** v3.28.0 added `/cx-stop` (21 commands total) but five catalog/list locations still hardcoded `20`: `tests/test_install.sh:50` (`-eq 20`), `core/claudemd-section.md:9` (commands list), `commands/cx-router.md` (table missing row), `hooks/session-start.py:386` (`Cortex commands:` hint string), and `skills/cortex/SKILL.md` (description frontmatter, `### Commands (20)` header, table). All eight CI matrix legs (Ubuntu/macOS × Python 3.11/3.13 × Node 22/24) failed on `Fresh Install / commands: 21 (expected 20)`. Forward-only: existing user installs unaffected. Tests: `test_install.sh` 41→42 PASS. |
| v3.28.0 | 2026-05-09 | **Operational tools: `/cx-stop`, `--deep` analysis, daily snapshots.** New `/cx-stop` command triggers `session-learner.js` on demand without closing the chat (uses `uuidgen` with Python UUID fallback, logs to `$TMPDIR`). New `write_daily_snapshot()` in `session-start.py` writes `~/.claude/cortex/daily-snapshots/YYYY-MM-DD.json` on first SessionStart of each new day (observations per project, proposals, instincts, laws counts; idempotent; atomic write; mode 0o600). `cx-analyze --deep` flag spec added: concatenates `observations.archive/*.jsonl` before compressor (archives first, chronological), warns at >5MB. Tests: `tests/test_v328_operational.sh` 5/5 PASS. |
| v3.27.0 | 2026-05-09 | **Three new behavioral detectors + `/cx-status --reflect`.** New `detectAgentSubtypes()` emits proposal when a subagent type has ≥3 uses with >30% error rate (confidence 0.45). New `detectFileCoupling()` emits proposal when two files are edited together in ≥5 distinct sessions (confidence 0.40). New `detectTimeOfDayPatterns()` accumulates tool-use + error data per hour into `~/.claude/cortex/productivity-patterns.json` (morning/afternoon/evening/night buckets, auto-insights for high-error periods). `/cx-status --reflect` reads and renders this file with hourly breakdown, bucket stats, and insights. `--help` flag added (shows reference without running dashboard). `setTimeout` in `session-learner.js` now calls `.unref()` so test `require()` does not block. Tests: `tests/test_detectors_v327.sh` 12/12 PASS (includes corrupted-file no-clobber + `::` path edge case from AD review). Bug fixes: `detectTimeOfDayPatterns` parse failure now aborts write instead of clobbering data; merge+write block restructured to minimize race window (known race documented, same as cross-day-tracker.js); `detectFileCoupling` pair key changed from `::` to null-byte delimiter. |
| v3.26.0 | 2026-05-09 | **Cross-day pattern boost universal.** New `hooks/lib/cross-day-tracker.js` (zero deps Node) with `applyCrossDayBoost()` wrapper applied to all 5 proposal-emitting detectors. Append-only `~/.claude/cortex/cross-day-tracker.jsonl` tracks patterns seen across distinct days; +0.05/+0.10/+0.15 boost by tier (2-3, 4-7, 8+ days). Confidence cap 0.95. Jaccard ≥0.70 dedup tolerant of regex variants. Auto-prune >365d via `distill_engine._prune_cross_day_tracker()` in `run_auto_distill()`. Tests: `tests/test_cross_day_tracker.sh` 9/9 PASS. Defaults lowered: `MAX_FILE_SIZE_MB` 10→5, `ARCHIVE_DAYS` 30→90 (configurable via `memory.json`). |
| v3.25.5 | 2026-05-09 | **Config — `learn_threshold` raised to 100.** `hooks/observe.py` default raised 50→100; `hooks/session-start.py` now reads `learn_threshold` from `memory.json` config (same pattern as `observe.py`) instead of hardcoding 50. Configurable via `~/.claude/cortex/memory.json` `config.learn_threshold`. |
| v3.25.4 | 2026-05-08 | **Bugfix — state flag cleanup.** `cx-analyze` Step 6: deletes `.learn-pending` and rewrites `.last-learn-count` baseline after analysis so session-start "50+ observations" banner suppresses until ≥50 new observations accumulate. `cx-distill` Step 6: truncates `auto-distill-candidates.md` after run so `[MAINT]` reminder suppresses until `distill_engine.py` finds new candidates. |
| v3.25.3 | 2026-05-08 | **CI unblock + session-start cleanup.** `commands/cx-analyze.md` stale `observe.sh` ref → `observe.py`; `hooks/session-start.py` remove `[CORTEX ATTENTION]` forced injection; `.githooks/pre-push` new hook (integrity + security tests + version sync + AI review); `docs/FEATURES-visual.html` removed. |
| v3.25.2 | 2026-05-07 | **Bugfix — `cx-analyze` compressor schema corrected.** Step 3 pre-processing pseudocode referenced a stale schema (`timestamp`, `args.*`, `result`, `status`) that never matched the JSONL written by `observe.sh`. Real fields: `ts`, `ev` (`"ts"`=tool-start / `"tc"`=tool-complete), `input` (serialized JSON string), `output` (tc events only), `err` (boolean). Wrong schema stripped all signal — Opus agent received lines like `{"tool":"Bash"}` and produced 0 proposals. Fix: `commands/cx-analyze.md` Step 3 updated with correct field names, JSON-deserialization of `input`, and event-type branching. |
| v3.25.1 | 2026-05-07 | **Hotfix — silent downgrade through stale local repo.** After v3.25.0 was merged to `main`, the operator's local clone of the repo was still at the v3.24.1 SHA because no `git pull` had run. Re-running `bash install.sh` from that stale repo silently DOWNGRADED a fresh v3.25.0 installation back to v3.24.1, overwriting the new SessionStart and session-learner code while preserving counters. **Fix:** `install.sh` now compares `NEW_VERSION` against the locally-installed version (`sort -V` semver compare) and aborts with `DOWNGRADE BLOCKED` unless `--allow-downgrade` is passed. `install.ps1` adds the same gate via a `[version]` cast (Windows parity). Both also add a same-version branch ("already installed — refreshing files") so re-running on top of itself is no longer mislabelled as an upgrade. New `tests/test_install_downgrade.sh` (5/5 PASS) covers clean install / same-version / downgrade-blocked / `--allow-downgrade` override / real upgrade path with `mktemp -d` + `HOME=$SANDBOX` isolation. **Forward-only** — existing installations are not migrated; the safeguard takes effect on the next `bash install.sh` run. Total tests: 17 suites green. |
| v3.25.0 | 2026-05-07 | **Two P0/P1 fixes that unlock autonomous operation.** Codex GPT-5.5 adversarial review surfaced two structural blockers: (1) `error-fix` detector at `hooks/session-learner.js:266` emitted `confidence=0.40` while auto-validate threshold sat at `0.50` — every gotcha parked in `proposals.json` waiting for manual `/cx-validate`; raised to `0.50` so the autonomous chain *observation → error-fix → auto-validate → instinct → distill → law* now flows end-to-end. (2) `hooks/session-start.py:282-360` injected pipeline activity, learn-pending banners, and `[ACTION]`/`[MAINT]` reminders as silent `additionalContext`; only EOD carried "present in first response". New trailing `[CORTEX ATTENTION]` block now arms whenever pipeline / reminders have actionable content, mirroring the EOD pattern. Bonus: `commands/cx-status.md` `--reflexes` panel STATUS rules updated to mirror the v3.24.1 auto-disable gate (`NOISY` now requires `usefulCount < noiseCount`, label and gate finally agree). Catalog drift cleaned in `commands/cx-router.md` (16 → 20) and `hooks/session-start.py:294` commands hint (16 → 20) — both were missing `/cx-dashboard`, `/cx-feedback`, `/cx-feedback-auto`, `/cx-timeline`. Tests: 16/16 suites green. Command consolidation (20 → 5 canonical) deferred to v3.26.0. |
| v3.24.1 | 2026-05-05 | **Hotfix — auto-disable threshold ignored ratio.** Within hours of v3.24.0, `bash-cat-use-read` was auto-disabled with `usefulCount=111, noiseCount=3` (ratio 37x — clearly healthy). Gate at `session-learner.js:1315` only checked absolute thresholds. **Fix:** added `usefulCount < noiseCount` requirement (ratio < 1.0). Re-enabled `bash-cat-use-read` manually during the release. Knowledge-log entry expanded with `usefulCount=...` and ratio for auditable disable history. Forward-only — existing `enabled: false` records not auto-restored. |
| v3.24.0 | 2026-05-05 | **Stability release — 7 P0 + 4 P1 fixes from a 4-agent parallel audit.** After >1 week of cortex feeling broken despite multiple patches, an Opus 1M audit pass across PreToolUse pipeline / Stop pipeline / distill engine / corpus health revealed several structural biases that silenced 98%+ of instincts and mis-counted reflex outcomes. **P0 (silently broken):** (1) `injector-engine.js:275` domain filter compared category labels (`gotcha`, `pattern`, `tool-pref`) against tech-stack labels (`react`, `node`, `python`) — 121/122 instincts silently rejected; new `CATEGORY_DOMAINS` set always-passes category domains. (2) `session-learner.js:574` `updateInstincts` matched trigger against bare tool name; now matches `tool + " " + input` like the injector does. (3) `session-learner.js:176` sid filter exact-match silently fell back to last 200 cross-project lines on truncated sids; now uses `buildCandidateSids`. (4) `session-learner.js:1213` counter loss after `resetAt` — added rebuild pass that recounts post-resetAt feedback events from `impact.jsonl` and applies max(current, rebuilt). (5) `distill_engine.py:407` confidence decay double-counted daily — anchored on `last_decay_at` instead of `last_seen`. (6) `distill_engine.py:LAW_MIN_PROJECTS` 3→1 — was unreachable for solo-project knowledge, 11 mature instincts queued for weeks. (7) `distill_engine.py:_proposal_to_instinct_yaml` apostrophe injection broke YAML — new `_yaml_single_quote` helper. **P1:** (8) `_log_knowledge` source hardcoded — pipeline-stats counters reported zero forever; `source` is now a parameter. (9) `evalErrorMonitor` window=1 reflexes scanned only the inject's own observation — noise slice now covers `[currentIdx, currentIdx+1+window)`. (10) silent staleness skip — added `CORTEX_DEBUG` log. (11) test_impact Test 22 assertion was stale post-v3.23.7 — updated semantics, added Test 22b. **Forward-only fix:** counters self-heal on next Stop hook. Domain filter fix unlocks ~120 previously-silenced instincts immediately. Total tests still green via `bash tests/run_all.sh`. |
| v3.23.7 | 2026-05-05 | **Hotfix — `evalToolSubstitution` structural bias.** 24h after v3.23.4 deployed, audit showed asymmetric `useful` accumulation across the Sprint-5 trio: `bash-cat-use-read` 43% pivot rate to Read, but `bash-find-use-glob` 9% and `bash-grep-use-grep-tool` **0%**. Root cause in `hooks/session-learner.js:1036-1050`: the tool-substitution evaluator only emitted `'useful'` on an immediate pivot to `expected_tool` within `window=3` after the fire. Real-world: when an agent has already run `cat foo.py` and got the data, it does not re-execute the query with `Read`; same for `find→Glob` and `grep -r→Grep`. The warning was pedagogically useful (the agent learns to start with the right tool next time) but the evaluator could not detect that utility from the immediate window. **Same structural bias `evalErrorMonitor` had before v3.19.4.** Fix: adopted `aligned-or-ignored` semantics — (1) pivot in window → useful (strong signal); (2) reincidence with `anti_pattern` in window → noise (warning ignored); (3) no reincidence and the agent kept working → useful (the warning prevented the anti-behavior or was absorbed without harm); (4) empty window → ignore (cannot judge). Reincidence wins over pivot if both happen. **Forward-only fix** — existing `usefulCount`/`noiseCount` not recounted; counters catch up naturally. New 4 tests in `test_session_learner.sh` (8 → 12 PASS) cover all four scenarios. `run_all.sh` 16 suites green. Sprint-5 Gate 2: `bash-cat-use-read` already PASSED under old logic (5.0× ratio); `bash-find-use-glob` and `bash-grep-use-grep-tool` will accumulate useful within 1–2 post-v3.23.7 sessions. |
| v3.23.6 | 2026-05-04 | **Documentation — Sprint-5 timeline.** `docs/SPRINT-5-PENDING-GATES.md` updated: measurement window now anchored on 2026-05-04 (post-v3.23.4 deployment, when `bash-cat-use-read` actually started firing) instead of 2026-05-02 (post-v3.23.3, when the runtime guard still silenced it). Estimate shortened from 5–7 days to **1–2 days** because the operator runs Claude Code across many projects in parallel daily, so the ≥30 fires + ≥50 events floors fill 3–5× faster than typical solo-project usage. No code surface changed; bump exists only to satisfy the pre-push CHANGELOG-discipline guard. |
| v3.23.5 | 2026-05-04 | **Hotfix — Windows installer parity.** `install.sh:209-219` had been propagating `evaluator.*` sub-fields (the matcher fix on `bash-cat-use-read` / `bash-grep-use-grep-tool` / `bash-find-use-glob` requires updating `condition` AND `evaluator.anti_pattern` together) since v3.23.3, but `install.ps1` was never patched. Windows users running the installer post-v3.23.3 would silently end up with the new `condition` but stale `evaluator.anti_pattern` — exact same matcher-evaluator drift bug v3.23.3 closed. **Fix:** PowerShell migration block now propagates the same nine `evaluator.*` sub-fields (`type`, `anti_pattern`, `expected_tool`, `anti_tool`, `precondition_tool`, `match_field`, `lookback`, `window`, `error_pattern`). When the user reflex has no `evaluator` object, the whole default `evaluator` is grafted in via `Add-Member`. Per-field atomic updates preserve all runtime data (`fireCount`, `lastFired`, `usefulCount`, `noiseCount`, `enabled`). New test 10 in `tests/test_install_ps1.ps1` asserts the nine sub-fields and the `PSObject.Properties['evaluator']` guard are all present in source — catches future PS↔bash drift. |
| v3.23.4 | 2026-05-04 | **Hotfix — third silent bug in the Sprint-5 regression. ReDoS guard rejected legitimate regexes.** v3.23.3 fixed two regex bugs but `bash-cat-use-read` stayed dead 8 more days. Triple false-positive in `hooks/lib/injector-engine.js:33-45` and three duplicates in `hooks/session-learner.js` rejected the (legitimate) bash-cat condition: `length>100` (it grew to 136 with the v3.23.3 fix), the static ReDoS detector matched the safe pattern `(-[0-9]+\s+)?` because the `?` outer quantifier was wrongly listed alongside `+/*`, and pipe-count>5 silenced any regex with ≥6 alternations. The same pipe filter had quietly killed three global instincts (`gotcha-bash-cat-instead-of-read`, `pattern-macos-path-prefix-npm-node`, `pref-fix-all-lint-test-issues`) for an indeterminate period. **Fix:** centralize the guard in two new modules `hooks/lib/regex-guard.js` + `hooks/lib/regex_guard.py` (single source of truth, parity Node↔Python verified by corpus tests). Limits raised — `MAX_LEN` 100→**200**, `MAX_PIPES` 5→**25**, `REDOS_DETECTOR` removed `?` from outer quantifier list. Live 50ms timeout against `'a'×100` is now the canonical ReDoS safety net (the static detector is heuristic only). All four call sites (`injector-engine.js` lines 115/116/283, `session-learner.js` lines 562/650/659, `dream_cycle.py:217`) refactored to use the shared module. Inner reflex loop in `session-learner.js` compiles `condRe` once per reflex instead of per observation (pure speed-up). Sprint-7 `auto_validate_proposals` (`distill_engine.py:805`) now validates `trigger` BEFORE writing the YAML; rejected proposals persist with `status="held"`, `hold_reason="unsafe-trigger:<reason>"` so `/cx-validate` can review them — proposals can no longer be silently dropped. Structured stderr logging deduped per `(tag, reason, pattern[:64])` makes future silent-silencing events visible. **New `tests/test_guard_corpus.sh` (9/9 PASS):** all shipped reflex matchers/conditions + all `~/.claude/cortex/instincts/global/*.yaml` triggers must pass both guards, with parity check (Node and Python return identical reasons), adversarial corpus (`(a+)+`, 201 chars, 27 pipes — must reject), safe corpus (`(a+)?b`, 200 chars, 25 pipes, Sprint-5 conditions — must accept), known-gap assertion (`(a|aa)+` accepted today; live timeout catches it dynamically), and live-reflexes coverage. **Updated** `test_injector.sh` 16→**18** and `test_dream_cycle.sh` 35→**38** with boundary cases. **Total: 16 suites green** (run_all). **Concerns:** static detector still misses alternation-overlap ReDoS — relies on live timeout; tracked for v3.24.0+. Sprint 5 Gate 1+2 measurement window remains valid — post-v3.23.4 all three reflexes will accumulate honest fires. |
| v3.23.3 | 2026-05-04 | **Hotfix — fix 2 silent regex bugs in `bash-cat-use-read` / `bash-grep-use-grep-tool` / `bash-find-use-glob` matchers (Sprint 5 v3.20.0 regression).** Triggered by Fer questioning the "0 fires post-`resetAt`" interpretation. Forensic on `observations.jsonl` revealed 95 + 133 + 78 = **306 real-world Bash commands in 6 days** that the matchers should have caught but didn't. Root cause: the v3.20.0 "matcher refinement" was too aggressive — (1) `^` anchor rejected compound commands (`a; b`, `a && b`, `a \| b`) which make up >90% of real-world Bash; (2) `-[a-zA-Z]*[rR]` required `r/R` as the LAST letter of the flag prefix, missing common forms like `-rn`, `-rE`, `-RE`. Fix in `core/reflexes.default.json`: replace `^` with `(?:^\|[;&\|]\\s*)` for compound-command capture; for grep, change `-[a-zA-Z]*[rR]` → `-[a-zA-Z]*[rR][a-zA-Z]*` so `r/R` can be anywhere in the flag prefix. Bonus: extend cat/head/tail extension list with `jsonl` (JSON Lines, used heavily by Cortex itself), and add optional numeric arg `(-[0-9]+\\s+)?` so `head -50 file.md` and `tail -100 file.json` also match. New `tests/test_reflex_matchers.sh` (28/28 PASS) covers compound commands (`;`/`&&`/`\|`), `r/R` flag positions (`-rn`, `-rE`, `-nR`, `-rni`), exclusion clauses (`-delete`, `-exec`), and edge cases. **Sprint 5 gates reopened:** `docs/SPRINT-5-PENDING-GATES.md` rewritten — Gate 1 + Gate 2 both depend on a fresh measurement window starting 2026-05-02 (the previous "PASS" reading was an artifact of broken matchers, not real signal). New Gate 2 criterion adds `fireCount post-resetAt ≥ 30` AND `useful/noise ≥ 2.0`. Estimate: enough data by 2026-05-09. Also archived 1 duplicate instinct (`pattern-sandbox-installer-test-mktemp` ↔ pre-existing `pattern-sandbox-installer-test`, J=0.36). User-local `~/.claude/cortex/reflexes.json` patched in-place during this release. **Total tests: 186/186 PASS** (158 + 28 new in test_reflex_matchers). |
| v3.38.0 | 2026-06-19 | **`/cx-eod` deterministic gather + intraday cron support.** New `core/_cx-eod-gather.sh` (pure Node, no LLM) scans all registered projects' last-24h observations + git per root and emits structured JSON — previously Claude scanned projects by hand at token cost. Adapted to the Cortex obs schema (`ts/ev/tool/err/pid/pname/input`, distinct from Sinapsis), cross-OS safe (basename splits `/` and `\`, foreign roots skipped, projects merged by name). `commands/cx-eod.md` Step 1 invokes it with legacy fallback. Intraday idempotency: re-runs REGENERATE the day file (24h window → no dupes) and accumulate a `## Ejecuciones hoy` trace; new `--auto` flag (and non-TTY detection) skips the overwrite prompt for cron/launchd. `examples/launchd/` ships a generic plist + install helper + README (defaults 15/19/22, Linux cron snippet). `install.sh`/`install.ps1` deploy `core/*.sh` to `~/.claude/cortex/core/`. New `tests/test_cx_eod_gather.sh` (9/9 PASS). |
