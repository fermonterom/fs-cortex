# fs-cortex — Continuous Learning for Claude Code

> Your AI assistant learns from every session. Automatically.

**fs-cortex** is a continuous learning system for [Claude Code](https://claude.ai/code) that observes your sessions, detects recurring patterns, and crystallizes them into reusable knowledge — all without slowing you down.

## What it does

- **Observes** every tool call silently via async hooks (0 tokens overhead)
- **Learns** patterns and crystallizes them as instincts (YAML, confidence-scored)
- **Distills** proven knowledge into Laws — one-liners injected every session (~300 tokens)
- **Protects** with deterministic reflex hooks (not probabilistic instructions)
- **Remembers** decisions across all projects via persistent memory

## How it works

```
Session 1, 2, 3...        Every ~50 observations       Proven patterns
     |                           |                           |
  [observe.sh]              [/cx-learn]                 [auto-distill]
     |                           |                           |
  OBSERVATIONS ──────────> INSTINCTS ──────────────> LAWS
  (JSONL, async)           (YAML, on demand)         (TXT, always injected)
  0 tokens                 ~50-100 tokens each       ~30 tokens each
```

### Confidence Lifecycle

Every pattern goes through 5 confidence tiers:

| Confidence | Tier | What it means |
|---|---|---|
| 0.0 - 0.3 | Observation | Raw, unvalidated |
| 0.3 - 0.5 | Hypothesis | Seen 2x, plausible |
| 0.5 - 0.7 | Pattern | Consistent, likely correct |
| 0.7 - 0.9 | Instinct | Validated, reliable |
| 0.9 - 1.0 | Law | Proven cross-project, crystallized |

When an instinct reaches **0.90+ confidence**, it's auto-proposed for condensation into a **Law** — a single sentence injected at every session start.

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
- Install the cortex skill and 7 commands
- Configure hooks in `settings.json` (with backup)
- Import knowledge from a previous backup (if provided)
- Append Cortex section to `CLAUDE.md`
- Ask your name, role, and language for personalization

### 3. Use

Open Claude Code and work normally. Cortex works automatically:

1. **Laws inject at session start** — your crystallized knowledge, always present
2. **Observations capture in background** — silent, zero overhead
3. **Reflexes fire on triggers** — deterministic rules, not suggestions
4. Every ~50 tool calls, you'll see: *"Run `/cx-learn` to crystallize patterns"*

## Commands

| Command | What it does |
|---------|-------------|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, system health |
| `/cx-learn` | Full pipeline: analyze → evolve → distill → promote → inherit |
| `/cx-eod` | End of day summary, saves context for next session |
| `/cx-gotcha` | Capture error→fix pattern as high-priority instinct |
| `/cx-export` | Generate portable skill for Claude web/app |
| `/cx-backup` | Create portable .tar.gz backup for machine transfer |
| `/cx-restore` | Import knowledge from a backup archive |

### /cx-learn — The Power Command

`/cx-learn` does everything in one pipeline:

1. **Analyze** observations → detect patterns → create instincts
2. **Evolve** related instincts → propose skills/commands/agents
3. **Distill** high-confidence instincts → condense into Laws
4. **Promote** cross-project patterns → move to global scope
5. **Bootstrap** new projects → scan git history or inherit from similar projects

## Architecture

### Hooks (always running)

| Hook | Event | Purpose | Blocking? |
|------|-------|---------|-----------|
| `session-start.sh` | SessionStart | Inject Laws, detect new day, check EOD | Yes (5s) |
| `session-start.sh` | SessionStart(compact) | Re-inject Laws after /compact | Yes (5s) |
| `git-guard.sh` | PreToolUse(Bash) | Protect git workflow (commit/push/merge) | Yes (5s) |
| `reflex-engine.sh` | PreToolUse(*) | Fire matching reflexes | Yes (500ms) |
| `observe.sh pre` | PreToolUse(*) | Capture tool start | No (async) |
| `observe.sh post` | PostToolUse(*) | Capture tool result | No (async) |

### Agents (invoked on demand)

| Agent | Model | Purpose |
|-------|-------|---------|
| `cortex-observer` | Haiku | Detect patterns in observations, create instincts |
| `cortex-reviewer` | Haiku | Code review after edits |
| `cortex-planner` | Sonnet | Decompose complex tasks into steps |

### Data Directory

```
~/.claude/cortex/
├── memory.json              # Your identity + config + stats
├── reflexes.json            # Active reflexes (deterministic rules)
├── laws/                    # Crystallized wisdom (one-liners)
│   └── *.txt
├── instincts/
│   ├── personal/            # Global instincts (YAML)
│   └── inherited/           # From /cx-learn inheritance
├── projects/
│   ├── registry.json        # All known projects
│   └── {hash}/              # Per-project data
│       ├── observations.jsonl
│       └── instincts/personal/
├── evolved/                 # Skills/commands/agents from /cx-learn
├── daily-summaries/         # EOD summaries for session continuity
└── exports/                 # Portable skills from /cx-export
```

## Reflexes

Reflexes are **deterministic rules** that fire via real hooks — not probabilistic instructions that Claude might forget.

Default reflexes:

| Reflex | Trigger | Action |
|--------|---------|--------|
| `read-before-edit` | Edit/Write tool | Verify file was Read first |
| `env-never-commit` | git add/commit | Check .env in .gitignore |
| `test-after-change` | Edit route.ts/component | Suggest running tests |

Add custom reflexes by editing `~/.claude/cortex/reflexes.json`.

## Backup & Restore

Transfer your knowledge between machines:

```bash
# On old machine — export knowledge
/cx-backup
# → Creates ~/cortex-backup-YYYY-MM-DD.tar.gz

# On new machine — install and import
bash install.sh
# → Installer asks for backup path during setup

# Or restore into an existing installation
/cx-restore ~/cortex-backup-2026-03-28.tar.gz
```

Backups include: laws, instincts, memory, reflexes, evolved content, daily summaries, and exports. Raw observations are excluded (too large, and patterns are already captured in instincts).

## Token Budget

| Component | Tokens | When |
|-----------|--------|------|
| SKILL.md | ~1,500 | Always (auto_activate) |
| Laws (max 10) | ~300 | Always (SessionStart hook) |
| Instincts | ~50-100 each | On demand (/cx-status, /cx-learn) |
| Observations | 0 | Never (async hooks, disk only) |
| **Total overhead** | **~1,800** | **Per session** |

## Uninstall

```bash
bash uninstall.sh
```

Offers portable backup before removal. Preserves learned data by default. Cleans settings.json and CLAUDE.md.

## Credits

Inspired by:
- [sinapsis](https://github.com/Luispitik/sinapsis) by Luis Salgado (SalgadoIA)
- [Everything Claude Code](https://github.com/anthropics/claude-code) (agent patterns)

## License

MIT

