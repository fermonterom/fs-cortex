# fs-cortex — Continuous Learning for Claude Code

[![version](https://img.shields.io/github/v/tag/fermonterom/fs-cortex?label=version&sort=semver&color=44cc11)](https://github.com/fermonterom/fs-cortex/releases)
[![tests](https://img.shields.io/badge/tests-159%20passing-44cc11)](https://github.com/fermonterom/fs-cortex/actions)
[![CI](https://img.shields.io/github/actions/workflow/status/fermonterom/fs-cortex/test.yml?label=CI&logo=github)](https://github.com/fermonterom/fs-cortex/actions)
[![license](https://img.shields.io/github/license/fermonterom/fs-cortex?color=blue)](LICENSE)

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

Parallel systems: **Reflexes** (8 deterministic rules, always fire) and **Agents** (3 specialized: pattern analysis, code review, task planning).

### Dual Injection

1. **SessionStart**: Laws (max 10) + EOD resume + project context bridge (~550 tokens)
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

**Decay**: -0.05 per 30 days without seeing the pattern. What you don't use fades.

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
| `session-start.sh` | Session open / `/compact` | Injects your laws + context bridge + EOD resume |
| `injector.sh` | Every tool use | Injects matching instincts (max 3) + reflexes (max 2) |
| `session-learner.js` | Session close | Detects error→fix pairs, corrections, workflows → proposals |

You don't configure or run anything. Just work — Cortex learns in the background.

### What you run periodically

Cortex reminds you when action is needed:

**Every 1-2 days** — when you see `[ACTION] N pending proposals`:

```
/cx-analyze    ← Detect patterns in observations → generate proposals
/cx-validate   ← Review proposals: A=accept, X=reject, S=skip
```

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
2. Work normally        → observe.py records, injector.sh injects
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

## Commands (14)

| Command | What it does |
|---------|-------------|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, tracking, health |
| `/cx-analyze` | Detect patterns in observations → proposals (with descriptions) |
| `/cx-distill` | Distill laws (universality gate), decay, Jaccard promotions |
| `/cx-validate` | Review proposals with Claude verdicts + shorthand input |
| `/cx-evolve` | Cluster instincts → skills/commands/rules/agents (checks existing) |
| `/cx-dream` | Dream Cycle: dedup, contradictions, staleness, regex validation, health score |
| `/cx-router` | Command catalog with token costs and next action suggestion |
| `/cx-promote` | Promote project instincts to global (cross-project, Jaccard ≥0.70) |
| `/cx-audit` | Token overhead, duplicates, conflicts, cleanup |
| `/cx-eod` | End-of-day summary, saves context for next session |
| `/cx-gotcha` | Capture error→fix as high-priority instinct |
| `/cx-export` | Generate portable skill for Claude.ai or sharing |
| `/cx-backup` | Create portable .tar.gz backup for machine transfer |
| `/cx-restore` | Import knowledge from a backup archive |

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

### Hooks (4, always running)

| Hook | Event | Purpose | Blocking? |
|------|-------|---------|-----------|
| `session-start.sh` | SessionStart | Inject Laws + EOD resume (once) + context.md bridge | Sync (5s) |
| `observe.py` | PreToolUse / PostToolUse | Capture tool start/complete (single-process, ~70ms) | Async (0 tokens) |
| `injector.sh` | PreToolUse | Inject matched reflexes + instincts | Sync (3s) |
| `session-learner.js` | Stop | Analyze session, proposals, context.md | Sync (15s) |

Also fires `session-start.sh` on `/compact` to re-inject laws.

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
├── reflexes.json            # Deterministic rules (8 default)
├── proposals.json           # Pending proposals from session-learner + cx-analyze
├── laws/                    # One-liners (max 10 active)
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
├── daily-summaries/         # EOD summaries
├── exports/                 # Portable skills
└── log/
```

## Reflexes

Deterministic rules that fire via hooks — not probabilistic instructions. Triggers are regex patterns matched against tool names and inputs.

Default reflexes (8):

| Reflex | Trigger (regex) | Action |
|--------|---------|--------|
| `read-before-edit` | Edit/Write | Verify file was Read first |
| `env-never-commit` | git add/commit | Check .env in .gitignore |
| `test-after-change` | Edit route.ts/component | Suggest running tests |
| `git-commit-quality` | git commit | Verify tests, lint, conventional format |
| `git-push-safety` | git push / gh pr create | Fetch+rebase, --force-with-lease |
| `git-merge-verify` | gh pr merge | Verify checks, clean up branch |
| `api-auth-check` | Edit route.ts/api/ | Validate authentication |
| `security-headers` | Edit vercel.json/next.config | Verify security headers |

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
| Laws (max 10) | ~300 | SessionStart (1x) |
| EOD resume | ~150 | SessionStart (1x per EOD, not repeated) |
| Context bridge | ~100 | SessionStart (1x) |
| Instincts (max 3) | ~120 | PreToolUse (if match) |
| Reflexes (max 2) | ~40 | PreToolUse (if match) |
| **Session total** | **~1,750** | **Estimated** |

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
bash tests/run_all.sh              # Run 10 bash suites (150 tests) + 1 PS1 suite (9 tests)
bash tests/test_security.sh        # 7 security regression tests
bash tests/test_dream_cycle.sh     # 26 dream cycle tests (dedup, decay, health)
bash tests/test_observe.sh         # 7 observer tests (scrubbing, is_error, dedup, perf)
bash tests/test_session_learner.sh # 7 session learner tests (detectors, proposals)
bash tests/test_injector.sh        # 14 injector tests (sanitization, ReDoS, limits)
bash tests/test_yaml_utils.sh      # 13 YAML parser tests (floats, strings, edge cases)
bash tests/test_install.sh         # 37 install tests (fresh, upgrade, idempotency)
bash tests/test_hooks_e2e.sh       # 14 end-to-end hook pipeline tests
bash tests/test_uninstall.sh       # 11 uninstall tests (cleanup, backup, safety guard)
bash tests/test_integrity.sh       # 14 integrity tests (commands, core files, versions)
pwsh tests/test_install_ps1.ps1    # 9 PowerShell installer tests (CI windows-latest)
```

All suites run on `git push` to main (pre-push hook) and on every PR via GitHub Actions CI (macOS + Linux + Windows, Python 3.9/3.12, Node 18/22).

## Credits

Cortex — Continuous Learning Engine for Claude Code
(c) 2026 Fernando Montero / Fersora Solutions

Inspired by:
- [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) by Affaan Mustafa — observation format and project scoping
- [Sinapsis](https://github.com/Luispitik/sinapsis-3.2/) by Luis Salgado — hook architecture and injection patterns

## License

MIT
