# fs-cortex — Continuous Learning for Claude Code

[![version](https://img.shields.io/github/v/tag/fermonterom/fs-cortex?label=version&sort=semver&style=flat-square&color=blue)](https://github.com/fermonterom/fs-cortex/releases)
[![tests](https://img.shields.io/endpoint?url=https%3A%2F%2Fgist.githubusercontent.com%2Ffermonterom%2Fc8919c03d35cd7e2b1a25fd483d64409%2Fraw%2Ffs-cortex-tests.json&style=flat-square)](https://github.com/fermonterom/fs-cortex/actions)
[![CI](https://img.shields.io/github/actions/workflow/status/fermonterom/fs-cortex/test.yml?label=CI&logo=github&style=flat-square)](https://github.com/fermonterom/fs-cortex/actions)
[![license](https://img.shields.io/github/license/fermonterom/fs-cortex?style=flat-square)](LICENSE)
[![python](https://img.shields.io/badge/python-3.11%2B-3776ab?style=flat-square&logo=python&logoColor=white)](https://python.org)
[![node](https://img.shields.io/badge/node-22%2B-339933?style=flat-square&logo=node.js&logoColor=white)](https://nodejs.org)

> Your AI assistant learns from every session. Automatically.

**fs-cortex** is a continuous learning system for [Claude Code](https://claude.ai/code) that observes your sessions, detects recurring patterns, and crystallizes them into reusable knowledge — all without slowing you down.

## What it does

- **Observes** every tool call silently via async hooks (0 tokens overhead)
- **Injects** matched instincts and reflexes per tool use via PreToolUse (~120 tokens max)
- **Analyzes** patterns on demand and proposes instincts with evidence
- **Distills** proven knowledge into Laws — one-liners injected every session (~300 tokens)
- **Evolves** clusters of mature instincts into reusable skills, commands, and rules
- **Protects** with deterministic reflex hooks (not probabilistic instructions)

## How it works

```
Observe (hooks)  →  Analyze  →  Validate  →  Distill  →  Evolve  →  Audit
    auto             manual      manual       manual      manual     manual

   OBSERVATIONS  →  PROPOSALS  →  INSTINCTS  →  LAWS  →  SKILLS/COMMANDS/RULES/AGENTS
   (JSONL, 0 tok)                  (YAML)       (TXT)     (evolved/)
```

Parallel systems: **Reflexes** (11 deterministic rules, always fire) and **Agents** (3 specialized: pattern analysis, code review, task planning).

### Dual Injection

1. **SessionStart**: Laws (max 15) + EOD resume + project context bridge (~850 tokens)
2. **PreToolUse**: Matched instincts (max 3, domain-filtered) + reflexes (max 2) per tool use (~200 tokens max)

### Confidence Lifecycle

Continuous 0.0–0.95 scale (capped, always refinable):

| Confidence | Label | Injection behavior |
|---|---|---|
| 0.00 - 0.29 | Observation | Not injected |
| 0.30 - 0.49 | Hypothesis | Only if trigger + tool match |
| 0.50 - 0.69 | Pattern | When trigger matches |
| 0.70 - 0.89 | Instinct | Automatic, promotion candidate |
| 0.90 - 0.95 | Law | Auto-distilled one-liner, injected always |

**Inline staleness**: instincts not seen in 60+ days are silently skipped at injection time (no file writes, immediate effect).

**Decay**: -0.05 per 30 days via Dream Cycle. What you don't use fades.

**Downvote**: `/cx-downvote` records negative feedback. 30%+ rejection rate → confidence reduced.

**Promotion**: Jaccard similarity ≥ 0.70 + 2 projects + avg confidence ≥ 0.80 → global.

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

## Usage Guide

### What happens automatically (no action needed)

| Hook | When it runs | What it does |
|------|-------------|-------------|
| `observe.py` | Every tool use | Records observations silently (async, 0 tokens, ~70ms) |
| `session-start.py` | Session open / `/compact` | Injects your laws + context bridge + EOD resume |
| `injector.sh` / `injector.js` | Every tool use | Injects matching instincts (max 3) + reflexes (max 2). `.sh` on Unix, `.js` on Windows. |
| `session-learner.js` | Session close | Detects error→fix pairs, corrections, workflows → proposals |

You don't configure or run anything. Just work — Cortex learns in the background.

### What you run periodically

Cortex reminds you when action is needed:

**Every 1-2 days** — when you see `[ACTION] N pending proposals`:

```
/cx-analyze    ← Detect patterns in observations → generate proposals
/cx-validate   ← Review proposals: A=accept, X=reject, S=skip
```

Note: triggers that fail the ReDoS guard are held as `status='held'` and shown in `/cx-validate` output (informational only).

**Weekly** — when you see `[MAINT]`:

```
/cx-distill    ← Promote mature instincts (0.90+) to laws, apply decay
/cx-dream      ← Dedup, contradictions, staleness cleanup, health score
/cx-audit      ← Token overhead, duplicates, conflicts, cleanup
```

**When needed:**

```
/cx-status     ← Dashboard: laws, instincts, projects, system health
/cx-gotcha     ← Capture an error→fix as a high-priority instinct
/cx-eod        ← End-of-day summary (auto-injected tomorrow morning)
/cx-backup     ← Portable .tar.gz backup for another machine
```

### Daily workflow

```
1. Open Claude Code     → laws inject automatically
2. Work normally        → observe.py records, injector injects
3. [ACTION] N proposals → /cx-validate (1 min)
4. [MAINT] reminder     → /cx-distill or /cx-dream (30 sec each)
5. End of day           → /cx-eod (optional but useful)
```

### Weekly maintenance

```
/cx-dream  →  /cx-distill  →  /cx-audit
 cleanup       promotions      token check
```

### How knowledge evolves

```
You work → Cortex observes → /cx-analyze detects patterns → /cx-validate you confirm
→ instinct confidence grows with use → /cx-distill promotes to law → law injects every session
→ unused knowledge decays (-0.05/month) → /cx-dream cleans up stale instincts
```

## Commands (21)

| Command | What it does |
|---------|-------------|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, tracking, health, domain grouping |
| `/cx-analyze` | Detect patterns in observations → proposals (with descriptions) |
| `/cx-distill` | Distill laws (universality gate, max 15), decay, Jaccard promotions. Sub-mode `--swap <old> <new> --confirm` (v3.32.0 §4.5): atomic deprecation when the cap saturates |
| `/cx-validate` | Review proposals with Claude verdicts + shorthand input |
| `/cx-evolve` | Cluster instincts → skills/commands/rules/agents (checks existing) |
| `/cx-dream` | Dream Cycle: dedup, contradictions, staleness, regex, health, cleanup |
| `/cx-timeline` | Knowledge event log: creations, promotions, decays, archives, evolutions |
| `/cx-router` | Command catalog with token costs and next action suggestion |
| `/cx-promote` | Promote project instincts to global (cross-project, Jaccard ≥0.70). Sub-mode `--auto <source> --confirm` (v3.32.0 §4.4): promote a HUMAN-gated detector source to AUTO once the statistical gate passes (n ≥ 20, accept_rate ≥ 70 %, ≥ 3 sessions, 0 critical) |
| `/cx-audit` | Token overhead, duplicates, conflicts, cleanup |
| `/cx-eod` | End-of-day summary, saves context for next session |
| `/cx-gotcha` | Capture error→fix as high-priority instinct |
| `/cx-downvote` | Negative feedback on incorrect instinct injection (reduces confidence) |
| `/cx-retro` | Weekly retrospective: command usage, instinct activations, health trend |
| `/cx-dashboard` | Generate a visual HTML dashboard of Cortex state with Fersora brand — open in browser |
| `/cx-export` | Generate portable skill for Claude.ai or sharing |
| `/cx-backup` | Create portable .tar.gz backup for machine transfer |
| `/cx-restore` | Import knowledge from a backup archive |
| `/cx-feedback` | Cierra el loop humano del funnel de impacto — marca la última inyección como útil o ruido |
| `/cx-feedback-auto` | Agent self-rating on tool-choice reflexes — emits feedback with source=agent |
| `/cx-backfill` | Recover legacy `session_id` data for the promotion gate (dry-run only in v3.33.0; `--apply` deferred to v3.34, issue #49) |

### Interactive Shorthand

All interactive commands use a consistent shorthand system — no modal dialogs:

| Letter | Meaning | Used in |
|--------|---------|---------|
| A | Accept / Promote | validate, distill, evolve |
| X | Reject / No promote | validate, distill, evolve |
| S | Skip (review later) | validate, distill, evolve |
| M | Merge | distill, evolve |
| O | Omit (already covered) | evolve |
| I | Install (pending skill) | evolve |

Example: `"1A, 2A, 3X, 4S"` or `"all-A"` to accept all.

Claude provides a verdict with reasoning per item before you decide. All commands require explicit confirmation before writing files.

### Learning Pipeline

```
/cx-analyze  →  /cx-validate  →  /cx-distill  →  /cx-evolve  →  /cx-dream  →  /cx-audit
 detect          confirm          laws + decay     skills         dedup          cleanup
 patterns        or reject        + promotions     commands       contradictions
                                                   rules          staleness
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
├── reflexes.json            # Deterministic rules (11 default — see below)
├── impact.jsonl             # Impact funnel (Sprint 0+, v:1) — inject/follow/feedback/outcome events
├── proposals.json           # Pending proposals from session-learner + cx-analyze
├── laws/                    # One-liners (max 15 active; deprecation via /cx-distill --swap)
│   ├── *.txt
│   └── archive/
├── instincts/
│   ├── global/              # Promoted cross-project instincts
│   └── archive/             # Decayed below 0.10
├── projects/
│   ├── registry.json        # All known projects
│   └── {hash}/
│       ├── observations.jsonl
│       ├── context.md       # Session bridge (14d TTL)
│       └── instincts/       # Project-scoped instincts
├── evolved/
│   ├── skills/              # Generated by /cx-evolve (fs- prefix)
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
| Instincts (max 3) | ~120 | PreToolUse (if match) |
| Reflexes (max 2) | ~40 | PreToolUse (if match) |
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
bash tests/run_all.sh                  # Run 20 bash suites (~365 tests) + 1 PS1 suite (9 tests)
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
