# fs-cortex — Continuous Learning for Claude Code

[![version](https://img.shields.io/github/v/tag/fermonterom/fs-cortex?label=version&sort=semver&style=flat-square&color=blue)](https://github.com/fermonterom/fs-cortex/releases)
[![tests](https://img.shields.io/endpoint?url=https%3A%2F%2Fgist.githubusercontent.com%2Ffermonterom%2Fc8919c03d35cd7e2b1a25fd483d64409%2Fraw%2Ffs-cortex-tests.json&style=flat-square)](https://github.com/fermonterom/fs-cortex/actions)
[![CI](https://img.shields.io/github/actions/workflow/status/fermonterom/fs-cortex/test.yml?label=CI&logo=github&style=flat-square)](https://github.com/fermonterom/fs-cortex/actions)
[![license](https://img.shields.io/badge/license-MIT-44cc11?style=flat-square)](LICENSE)
[![python](https://img.shields.io/badge/python-3.11%2B-3776ab?style=flat-square&logo=python&logoColor=white)](https://python.org)
[![node](https://img.shields.io/badge/node-22%2B-339933?style=flat-square&logo=node.js&logoColor=white)](https://nodejs.org)

> Your AI assistant learns from every session. Automatically.

**fs-cortex** is a continuous learning system for [Claude Code](https://claude.ai/code) that observes your sessions, detects recurring patterns, and crystallizes them into reusable knowledge — all without slowing you down.

## What it does

- **Observes** every tool call silently via async hooks (0 tokens overhead), capturing real output + error lines with anti-noise guards
- **Injects** matched instincts and reflexes per tool use via PreToolUse (~120 tokens max)
- **Learns** patterns automatically: instincts start as silent `draft`, earn `confirmed` (injectable) at 5+ occurrences across 3+ sessions — no manual analyze/validate step
- **Maintains** itself: `/cx-maintain` (deterministic, cron-able) promotes proven instincts to Laws — auto-swapping the least-impactful law when the cap is full (v4.3.0); the retired law falls back to the instinct pool instead of dying (v4.3.1) — dedups, decays, expires stale proposals at 30 days, rotates storage. Zero questions
- **Reports** instead of assigning work: the SessionStart badge tells you what the last pass did; `/cx-review` is an optional veto digest — nothing ever waits on you
- **Protects** with deterministic reflex hooks (not probabilistic instructions)

v4.0.0 ("signal-first, zero-decision") replaced the old 20+-command,
mostly-interactive pipeline with this design — see
[`docs/MIGRATION-V4.md`](docs/MIGRATION-V4.md) if you're upgrading from v3.

## How it works

```
Observe (hooks, output+err_msg captured)  →  draft (silent tracking)
    auto                                        auto

  draft → confirmed (occ>=5, sessions>=3)  →  /cx-maintain  →  /cx-review
     auto                                    cron-able         optional veto

  OBSERVATIONS → INSTINCTS (draft/confirmed) → LAWS → SKILLS/COMMANDS/RULES
  (JSONL, 0 tok)   (YAML)                       (TXT)   (evolved/)
```

Parallel systems: **Reflexes** (13 deterministic rules, always fire) and **Agents** (3 specialized: pattern analysis, code review, task planning).

### Dual Injection

1. **SessionStart**: Laws (max 15) + EOD resume + project context bridge (~850 tokens)
2. **PreToolUse**: Matched instincts (max 3, domain-filtered) + reflexes (max 2) per tool use (~200 tokens max). Same id injects at most 2x per session (v3.37.0 repeat cooldown)

### Confidence Lifecycle

Continuous 0.0–0.95 scale (capped, always refinable):

| Confidence | Label | Injection behavior |
|---|---|---|
| 0.00 - 0.29 | Observation | Not injected |
| 0.30 - 0.49 | Hypothesis | Only if trigger + tool match |
| 0.50 - 0.69 | Pattern | When trigger matches |
| 0.70 - 0.89 | Instinct | Automatic, promotion candidate |
| 0.90 - 0.95 | Law | Auto-distilled one-liner, injected always |

New instincts also carry a separate `status: draft` field — tracked silently,
never injected regardless of confidence, until they earn `status: confirmed`
at 5+ occurrences across 3+ distinct sessions.

**Inline staleness**: instincts not seen in 60+ days are silently skipped at injection time (no file writes, immediate effect).

**Decay**: -0.05 per 30 days, applied by `/cx-maintain`. What you don't use fades.

**Feedback**: `/cx-downvote` (via the optional `/cx-review` digest) vetoes incorrect injections. 30%+ rejection rate → confidence reduced. Human-gated proposals not reviewed within 30 days expire on their own (tombstoned).

**Promotion**: Jaccard similarity ≥ 0.70 + 2 projects + avg confidence ≥ 0.80 → global, computed inside `/cx-maintain`.

## Quick Start

### 1. Clone

```bash
git clone https://github.com/fermonterom/fs-cortex.git
cd fs-cortex
```

### 2. Install

**macOS / Linux:**
```bash
bash install.sh
```

**Windows (PowerShell):**
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

> **Windows requirements**: Python 3, Node.js, and Git must be installed and in your PATH. Hooks run via Git Bash automatically.

The installer will:
- Create `~/.claude/cortex/` data directory
- Install the cortex skill, 12 commands, and Python modules
- Configure 4 hooks in `settings.json` (with backup)
- Import knowledge from a previous backup (if provided)
- Append Cortex section to `CLAUDE.md`
- Ask your name, role, and language for personalization
- Write a version marker for future upgrades

### 3. Update (existing installation)

Just run the installer again — it detects existing installations automatically:

**macOS / Linux:**
```bash
cd fs-cortex
git pull
bash install.sh
```

**Windows (PowerShell):**
```powershell
cd fs-cortex
git pull
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer:
- Detects your installed version and shows the upgrade path
- Preserves all your data (laws, instincts, observations, reflexes, proposals)
- Updates only hooks, commands, skill, and Python modules
- Updates the Cortex section in CLAUDE.md without touching your other sections

### 3b. Use

Open Claude Code and work normally. Cortex works automatically.

### 3c. Schedule the weekly maintenance (recommended)

`/cx-maintain` is deterministic and safe to run unattended. Register it once
with cron (macOS/Linux) or Claude Code's own schedule:

```cron
0 4 * * 0 claude -p "/cx-maintain" >> ~/.claude/cortex/log/cx-maintain-cron.log 2>&1
```

A daily "maintain-lite" pass (decay + rotation) already runs automatically at
every SessionStart, so the weekly cron is a top-up, not a requirement — but
without it, decay/promotion/dedup only advance on days you happen to open
Claude Code.

## Usage Guide

### What happens automatically (no action needed)

| Hook | When it runs | What it does |
|------|-------------|-------------|
| `observe.py` | Every tool use | Records observations + real output/error lines silently (async, 0 tokens, ~70ms), with per-line noise guards |
| `session-start.py` | Session open / `/compact` | Injects your laws + context bridge + EOD resume (with Eisenhower Q1-Q4 classification) |
| `injector.sh` / `injector.js` | Every tool use | Injects matching `confirmed` instincts (max 3) + reflexes (max 2), same id max 2x/session. `.sh` on Unix, `.js` on Windows. |
| `session-learner.js` | Session close | Detects error→fix pairs, corrections, workflows → new instincts (born `status: draft`, auto-promote to `confirmed` at 5+ occurrences / 3+ sessions) |

You don't configure or run anything. Just work — Cortex learns in the background.

### What you run periodically

**Weekly, deterministic** — cron-able, zero questions:

```
/cx-maintain   ← decay + dedup + promotion to law + storage rotation + health check
```

**Optional, human veto** — the `[cx] maintain:` badge reports what the last
pass already did (law swaps, expired proposals, queue):

```
/cx-review     ← ONE shorthand digest of what auto-swapped, what expired and
                 what waits. Pure veto — skipping it never blocks anything.
```

**When needed:**

```
/cx-status     ← Dashboard: laws, instincts, projects, system health
/cx-gotcha     ← Capture an error→fix as a high-priority instinct
/cx-eod        ← End-of-day summary (cumulative, auto-injected tomorrow morning)
/cx-backup     ← Portable .tar.gz backup for another machine
```

### Daily workflow

```
1. Open Claude Code     → laws inject automatically, [cx] badge reports last maintain
2. Work normally        → observe.py records real output/errors, injector injects
3. Instincts mature      → draft → confirmed automatically, no action from you
4. End of day            → /cx-eod (optional but useful, now cumulative)
```

### Weekly maintenance

```
/cx-maintain  →  /cx-review (optional)
 deterministic    human veto digest
```

### How knowledge evolves

```
You work → Cortex captures output+errors (guarded) → instinct born as draft
→ 5+ occurrences across 3+ sessions → status: confirmed → starts injecting
→ /cx-maintain promotes proven instincts to law deterministically
  (auto-swapping the least-impactful law when the cap is full, v4.3.0;
   the retired law falls back to the instinct pool, v4.3.1)
→ stale pending proposals expire on their own after 30 days
→ /cx-review is an optional veto pass — nothing ever waits on you
```

## Commands (7 active + 17 deprecated)

v4.0.0 replaced the old manual-judgment command set. Deterministic maintenance
lives in `/cx-maintain`; the one remaining human-judgment step lives in
`/cx-review`. Upgrading from v3? See [`docs/MIGRATION-V4.md`](docs/MIGRATION-V4.md)
for the full command mapping.

| Command | What it does |
|---------|-------------|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, tracking, health, domain grouping |
| `/cx-maintain` | **Deterministic, cron-able.** decay + Jaccard dedup + purge + deterministic law promotion + storage rotation + proposals↔instincts reconciliation + health check. Zero questions. |
| `/cx-review` | **The only command with judgment, weekly.** One consolidated shorthand digest of everything deterministic maintenance left for a human to decide. |
| `/cx-eod` | End-of-day summary, cumulative across the day, Eisenhower-classified for next session |
| `/cx-gotcha` | Capture error→fix as high-priority instinct |
| `/cx-backup` | Create portable .tar.gz backup for machine transfer |
| `/cx-restore` | Import knowledge from a backup archive |

### Deprecated (17, stub-only)

Each prints a one-line notice + its v4 replacement and runs no legacy logic:
`/cx-analyze`, `/cx-distill`, `/cx-dream`, `/cx-promote`, `/cx-backfill` →
`/cx-maintain`. `/cx-validate`, `/cx-evolve`, `/cx-downvote`, `/cx-retro` →
`/cx-review`. `/cx-timeline`, `/cx-dashboard`, `/cx-export` → `/cx-status`.
`/cx-audit` → workflow `cortex-audit` (no longer a slash command).
`/cx-feedback`, `/cx-feedback-auto`, `/cx-router`, `/cx-stop` → eliminados sin
sustituto. Full rationale in [`docs/MIGRATION-V4.md`](docs/MIGRATION-V4.md).

### Interactive Shorthand

`/cx-review` uses the same shorthand convention the old interactive commands
did — no modal dialogs:

| Letter | Meaning |
|--------|---------|
| A | Accept (proposal) |
| X | Reject (proposal) |
| S | Skip (review later) |
| I | Install (evolve draft) |
| D | Discard (evolve draft) |
| P | Deprecate (law) |
| M | Mantener / keep (law) |

Example: `"1A, 2S, 3M, 4I"`.

Claude provides a verdict with reasoning per item before you decide. All commands require explicit confirmation before writing files.

### Learning Pipeline

```
Observe (output+err_msg, per-line guards) → draft instinct (silent tracking)
   → confirmed (occurrences>=5, sessions_seen>=3)
   → /cx-maintain (deterministic law promotion + dedup + decay + rotation)
   → /cx-review (weekly, the only step left that needs a human)
```

## Architecture

### Hooks (5, always running)

| Hook | Event | Purpose | Blocking? |
|------|-------|---------|-----------|
| `session-start.py` | SessionStart | Inject Laws + EOD resume (once) + context.md bridge | Sync (5s) |
| `observe.py` | PreToolUse / PostToolUse | Capture tool start/complete (single-process, ~70ms) | Async (0 tokens) |
| `injector.sh` / `injector.js` | PreToolUse | Inject matched reflexes + instincts (`.sh` on Unix, `.js` on Windows — both delegate to `lib/injector-engine.js`) | Sync (3s) |
| `session-learner.js` | Stop | Analyze session, proposals, impact-funnel correlation, reflex auto-evaluation, **outcome auto-ranking** (v3.20.0+), context.md | Sync (15s) |

Also fires `session-start.py` on `/compact` to re-inject laws.

### Agents (invoked on demand)

| Agent | Model | Purpose |
|-------|-------|---------|
| `cortex-observer` | Opus 1M | Detect patterns in observations (cross-project, full context) |
| `cortex-reviewer` | Sonnet x3 parallel | Code review: security + quality + correctness |
| `cortex-planner` | Sonnet | Decompose complex tasks into steps |

### Data Directory

```
~/.claude/cortex/
├── memory.json              # Identity + config + stats
├── reflexes.json            # Deterministic rules (13 default — see below)
├── impact.jsonl             # Impact funnel (Sprint 0+, v:1) — inject/follow/feedback/outcome events
├── proposals.json           # Pending proposals from session-learner (human-gated domains only, v4)
├── .review-digest.json      # (v4) written by /cx-maintain, consumed by /cx-review
├── laws/                    # One-liners (max 15 active; deprecation via /cx-review)
│   ├── *.txt
│   └── archive/
├── instincts/
│   ├── global/              # Promoted cross-project instincts (status: draft/confirmed)
│   └── archive/             # Decayed below 0.10
├── projects/
│   ├── registry.json        # All known projects
│   └── {hash}/
│       ├── observations.jsonl
│       ├── context.md       # Session bridge (14d TTL)
│       └── instincts/       # Project-scoped instincts
├── evolved/
│   ├── skills/              # Drafted by /cx-maintain's auto-evolve pass, installed via /cx-review (fs- prefix)
│   ├── commands/
│   ├── rules/
│   └── agents/
├── knowledge-log.md         # Append-only knowledge event timeline
├── daily-summaries/         # EOD summaries
├── exports/                 # Portable skills
└── log/
```

## Reflexes

Deterministic rules that fire via hooks — not probabilistic instructions. Triggers are regex patterns matched against tool names and inputs.

Default reflexes (13):

| Reflex | Trigger (regex) | Action |
|--------|---------|--------|
| `read-before-edit` | Edit/Write | Verify file was Read first |
| `env-never-commit` | git add/commit | Check .env in .gitignore |
| `test-after-change` | Edit route.ts/component | Suggest running tests |
| `git-commit-quality` | git commit | Verify tests, lint, conventional format |
| `git-push-safety` | git push / gh pr create | Fetch+rebase, --force-with-lease |
| `git-merge-verify` | gh pr merge | Verify checks, clean up branch |
| `api-auth-check` | Edit route.ts/api/ | Validate authentication |
| `bash-cat-use-read` | `^(cat\|head\|tail) <path>.<ext>` (source files) | Use Read tool instead — refined matcher in v3.20.0 |
| `bash-grep-use-grep-tool` | `^grep -[rR]` (recursive only) | Use Grep tool instead — refined matcher in v3.20.0 |
| `bash-find-use-glob` | `^find <path> -name <pattern>` (no -exec/-delete/etc.) | Use Glob tool instead — refined matcher in v3.20.0 |
| `security-headers` | Edit vercel.json/next.config | Verify security headers |
| `instinct-downvote` | "wrong instinct" / "ignore instinct" | Suggest /cx-downvote |
| `capture-decision` | "from now on" / "always use" / "never use" | Suggest saving decision |

Each reflex tracks `fireCount` and `lastFired` for audit purposes.

## Backup & Restore

```bash
# Export knowledge
/cx-backup
# → Creates ~/cortex-backup-YYYY-MM-DD.tar.gz

# Install on new machine and import
bash install.sh
# → Asks for backup path during setup

# Or restore into existing installation
/cx-restore ~/cortex-backup-2026-03-28.tar.gz
```

Backups include: laws, instincts, memory, reflexes, evolved content, proposals, daily summaries, exports. Raw observations excluded (patterns captured in instincts).

## Token Budget

| Component | Tokens | When |
|-----------|--------|------|
| Laws (max 15) | ~600 | SessionStart (1x) |
| EOD resume | ~150 | SessionStart (1x per EOD, not repeated) |
| Context bridge | ~100 | SessionStart (1x) |
| Instincts (max 3) | ~120 | PreToolUse (if match; same id max 2x/session) |
| Reflexes (max 2) | ~40 | PreToolUse (if match; same id max 2x/session) |
| Impact funnel (v3.14.0+) | 0 | async writes to `impact.jsonl` |
| **Session total** | **~2,400** | **Estimated** |

## Uninstall

```bash
bash uninstall.sh
```

Offers portable backup before removal. Preserves learned data by default. Cleans settings.json and CLAUDE.md.

## Security

See [SECURITY.md](SECURITY.md) for the full security policy and vulnerability reporting process.

Key measures:
- Prompt injection sanitization on all injected text (instinct actions, context.md, EOD)
- Command injection prevention (`execFileSync` instead of `execSync`)
- 12-pattern secret scrubbing (AWS, GitHub, Stripe, Slack, Anthropic, OpenAI, Google, JWT, PEM, SSH, connection strings)
- ReDoS protection on regex compilation
- Atomic file writes with `flock`/perl fallback
- Instinct validation on import (blocked patterns, wildcard rejection)

## Tests

```bash
bash tests/run_all.sh                  # Run 34 bash suites (569+ tests) + 1 PS1 suite (10 tests)
bash tests/test_security.sh            # 7 security regression tests
bash tests/test_dream_cycle.sh         # 38 dream cycle tests (dedup, decay, health, cleanup)
bash tests/test_observe.sh             # 9 observer tests (scrubbing, is_error, dedup, perf)
bash tests/test_session_learner.sh     # 12 session learner tests (detectors, proposals)
bash tests/test_injector.sh            # 18 injector tests (sanitization, ReDoS, limits)
bash tests/test_yaml_utils.sh          # 13 YAML parser tests (floats, strings, edge cases)
bash tests/test_install.sh             # 42 install tests (fresh, upgrade, idempotency, 21 cmds)
bash tests/test_hooks_e2e.sh           # 14 end-to-end hook pipeline tests
bash tests/test_uninstall.sh           # 13 uninstall tests (cleanup, backup, safety guard)
bash tests/test_integrity.sh           # 14 integrity tests (commands, core files, versions)
bash tests/test_impact.sh              # 65 impact-funnel tests (schema, gates, auto-eval)
bash tests/test_distill_engine.sh      # 27 distill engine tests (auto-validate, pipeline-stats)
bash tests/test_yaml_normalize.sh      # 12 YAML repair tests (zero-deps, regex keys)
bash tests/test_guard_corpus.sh        # 9 ReDoS/length guard parity tests (Node ↔ Python)
bash tests/test_install_downgrade.sh   # 5 downgrade-block tests (--allow-downgrade flag)
bash tests/test_migrate_legacy_iid.sh  # 12 legacy iid migration tests
bash tests/test_reflex_matchers.sh     # 28 reflex matcher tests (regex correctness)
bash tests/test_cross_day_tracker.sh   # 10 cross-day boost tests (v3.26.0+)
bash tests/test_detectors_v327.sh      # 12 v3.27.0 detector tests (subtypes, coupling, ToD)
bash tests/test_v328_operational.sh    # 4 v3.28.0 tests (daily snapshot, --deep spec)
bash tests/test_storage_rotation.sh    # 28 storage rotation tests (v3.35.1 #56.2 — no-loss rotate, gates)
pwsh tests/test_install_ps1.ps1        # 10 PowerShell installer tests (CI windows-latest)
```

All suites run on `git push` to main (pre-push hook) and on every PR via GitHub Actions CI (macOS + Linux + Windows, Python 3.11/3.13, Node 22/24).

## Credits

Cortex — Continuous Learning Engine for Claude Code
(c) 2026 Fernando Montero / Fersora Solutions

Inspired by:
- [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) by Affaan Mustafa — observation format and project scoping
- [Sinapsis](https://github.com/Luispitik/sinapsis-3.2/) by Luis Salgado — hook architecture and injection patterns
- [gstack](https://github.com/garrytan/gstack) by Garry Tan — confidence calibration concepts, command usage timeline, inline staleness approach

## License

MIT
