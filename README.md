# fs-cortex — Continuous Learning for Claude Code

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

   OBSERVATIONS  →  PROPOSALS  →  INSTINCTS  →  LAWS  →  SKILLS/COMMANDS/RULES
   (JSONL, 0 tok)                  (YAML)       (TXT)     (evolved/)
```

### Dual Injection

1. **SessionStart**: Laws (max 10) + EOD resume + project context bridge (~550 tokens)
2. **PreToolUse**: Matched instincts (max 2) + reflexes (max 2) per tool use (~120 tokens max)

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

```bash
bash install.sh
```

The installer will:
- Create `~/.claude/cortex/` data directory
- Install the cortex skill and 11 commands
- Configure 4 hooks in `settings.json` (with backup)
- Import knowledge from a previous backup (if provided)
- Append Cortex section to `CLAUDE.md`
- Ask your name, role, and language for personalization

### 3. Use

Open Claude Code and work normally. Cortex works automatically:

1. **Laws inject at session start** — your crystallized knowledge, always present
2. **Context bridge injects** — yesterday's session context, auto-resumed (shown once, not repeated)
3. **Instincts inject per tool use** — matched patterns, confidence-gated
4. **Observations capture in background** — silent, zero overhead
5. **Session learner runs at close** — detects patterns, writes proposals
6. Every ~50 tool calls, you'll see: *"Run `/cx-analyze` to detect patterns"*

## Commands (11)

| Command | What it does |
|---------|-------------|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, health |
| `/cx-analyze` | Detect patterns in observations → proposals |
| `/cx-distill` | Distill laws, apply decay, check Jaccard promotions |
| `/cx-validate` | Review/confirm/reject proposals and weak instincts |
| `/cx-evolve` | Cluster mature instincts → skills/commands/rules |
| `/cx-audit` | Token overhead, duplicates, conflicts, cleanup |
| `/cx-eod` | End-of-day summary, saves context for next session |
| `/cx-gotcha` | Capture error→fix as high-priority instinct |
| `/cx-export` | Generate portable skill for Claude.ai or sharing |
| `/cx-backup` | Create portable .tar.gz backup for machine transfer |
| `/cx-restore` | Import knowledge from a backup archive |

### Learning Pipeline

```
/cx-analyze  →  /cx-validate  →  /cx-distill  →  /cx-evolve  →  /cx-audit
 detect          confirm          laws + decay     skills         cleanup
 patterns        or reject        + promotions     commands
                                                   rules
```

## Architecture

### Hooks (4, always running)

| Hook | Event | Purpose | Blocking? |
|------|-------|---------|-----------|
| `session-start.sh` | SessionStart | Inject Laws + EOD resume (once) + context.md bridge | Sync (5s) |
| `observe.sh` | PreToolUse / PostToolUse | Capture tool start/complete | Async (0 tokens) |
| `injector.sh` | PreToolUse | Inject matched reflexes + instincts | Sync (3s) |
| `session-learner.js` | Stop | Analyze session, proposals, context.md | Sync (15s) |

Also fires `session-start.sh` on `/compact` to re-inject laws.

### Agents (invoked on demand)

| Agent | Model | Purpose |
|-------|-------|---------|
| `cortex-observer` | Haiku | Detect patterns in observations |
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
│   └── rules/
├── daily-summaries/         # EOD summaries
├── exports/                 # Portable skills
└── log/
```

## Reflexes

Deterministic rules that fire via hooks — not probabilistic instructions.

Default reflexes (8):

| Reflex | Trigger | Action |
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
| Instincts (max 2) | ~80 | PreToolUse (if match) |
| Reflexes (max 2) | ~40 | PreToolUse (if match) |
| **Session total** | **~1,750** | **Estimated** |

## Uninstall

```bash
bash uninstall.sh
```

Offers portable backup before removal. Preserves learned data by default. Cleans settings.json and CLAUDE.md.

## Credits

Cortex — Continuous Learning Engine for Claude Code
(c) 2026 Fernando Montero / Fersora Solutions

Inspired by:
- [Sinapsis](https://salgadoia.com) by Luis Salgado — hook architecture and injection patterns
- [Everything Claude Code](https://github.com/AffaanMustafa/everything-claude-code) by Affaan Mustafa — observation format and project scoping

## License

MIT
