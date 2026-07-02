---
name: cortex
description: |
  Continuous learning system for Claude Code. Observes sessions,
  crystallizes patterns as atomic instincts with confidence scoring,
  distills proven knowledge into laws. Commands: /cx-status, /cx-maintain,
  /cx-review, /cx-eod, /cx-gotcha, /cx-backup, /cx-restore. 17 legacy
  commands (cx-analyze, cx-distill, cx-validate, cx-evolve, cx-dream,
  cx-promote, cx-backfill, cx-timeline, cx-dashboard, cx-audit, cx-feedback,
  cx-feedback-auto, cx-downvote, cx-retro, cx-router, cx-export, cx-stop)
  are deprecated stubs — see docs/MIGRATION-V4.md.
auto_activate: true
---

# Cortex v4.0.0 — Continuous Learning System

> Every session creates a connection. Cortex turns them into instinct.

## Architecture

3-level knowledge distillation with dual injection:

```
Observations (JSONL, async hooks, 0 tokens)
    ↓ /cx-analyze (cortex-observer agent, Opus 1M)
Instincts (YAML, confidence 0.0-0.95, injected via PreToolUse)
    ↓ confidence >= 0.90 via /cx-distill
Laws (TXT one-liners ≤120 chars, injected every SessionStart)
    ↓ clusters of 3+ mature instincts via /cx-evolve
Evolved artifacts (skills, commands, rules in evolved/)
```

## Data Location

`~/.claude/cortex/`

## How It Works

### Automatic (no user action needed)
- **Laws** injected at SessionStart (~300 tokens for max 10 laws)
- **Context bridge** injected at SessionStart (project context.md, 14d TTL)
- **EOD Resume** injected at SessionStart — Claude MUST present it proactively
- **Instincts** injected per PreToolUse via injector.sh (Unix) / injector.js (Windows) (max 3 instincts + 2 reflexes)
- **Observations** captured silently via async hooks (0 tokens)
- **Session analysis** runs at Stop (session-learner.js: proposals, context.md)
- After ~50 observations, session-start suggests running /cx-analyze

### Session Start Behavior (MANDATORY)

When the system prompt contains an `[eod-summary YYYY-MM-DD]` block (v3.31.0+; was `EOD RESUME` pre-v3.31), Claude MUST proactively present it in the **first response**, WITHOUT the user asking:

1. **Greeting** — Brief saludo
2. **Yesterday's summary** — Paraphrase the `[eod-summary]` block (1-2 lines)
3. **Learning status** — If pending observations, mention `/cx-analyze`
4. **Priorities** — List PRIORITIES as numbered list
5. **Ask** — Ask where to start (user's language from memory.json)

### Commands (7 active + 17 deprecated stubs)

| Command | Purpose |
|---------|---------|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, health |
| `/cx-maintain` | **Deterministic, cron-able.** decay + Jaccard dedup + purge + deterministic law promotion + storage rotation + health check + proposals↔instincts reconciliation. Zero questions. |
| `/cx-review` | **Only command with judgment, weekly.** One consolidated shorthand digest: human-gated proposals + evolve drafts + law deprecation candidates. |
| `/cx-eod` | End-of-day summary for next session, now cumulative + Eisenhower classification of "for tomorrow" bullets |
| `/cx-gotcha` | Capture error→fix as high-priority instinct |
| `/cx-backup` | .tar.gz backup for machine transfer |
| `/cx-restore` | Import backup with intelligent merge |

Deprecated (stub prints notice + replacement, no legacy logic runs):
`/cx-analyze`, `/cx-distill`, `/cx-dream`, `/cx-validate`, `/cx-evolve`,
`/cx-promote`, `/cx-backfill`, `/cx-timeline`, `/cx-dashboard`, `/cx-audit`,
`/cx-feedback`, `/cx-feedback-auto`, `/cx-downvote`, `/cx-retro`, `/cx-router`,
`/cx-export`, `/cx-stop`. Full v3→v4 mapping in `docs/MIGRATION-V4.md`.

### Learning Pipeline

```
Observe (hooks, output+err_msg captured) → draft instinct (silent tracking)
   → confirmed (occurrences>=5, sessions>=3) → /cx-maintain (deterministic
   promotion to law) → /cx-review (weekly human digest for what's left)
```

## Confidence System

Continuous 0.0–0.95 (capped, always refinable):

| Range | Label | Injection |
|-------|-------|-----------|
| 0.00-0.29 | Observation | Not injected |
| 0.30-0.49 | Hypothesis | Only if trigger+tool match |
| 0.50-0.69 | Pattern | When trigger matches |
| 0.70-0.89 | Instinct | Automatic, promotion candidate |
| 0.90-0.95 | Law | Auto-distilled, injected always |

**Up**: +0.10/occurrence (max +0.30/cycle), +0.20 user validation, +0.20 cross-project
**Down**: -0.20 contradiction, -0.10 failed application, -0.05/30 days unused
**Promotion**: Jaccard ≥0.70 + 2 projects + avg conf ≥0.80

## Instinct Format (v4.0 YAML)

```yaml
---
id: supabase-rls-auth-uid
trigger: "rls|policy|supabase|auth\\.uid"
action: "Verify auth.uid() in WHERE. Test with auth and service roles."
confidence: 0.75
domain: database
tags: [supabase, rls, security]
scope: project
project_id: "hash"
source: session-observation
status: draft
first_seen: "2026-03-28"
last_seen: "2026-04-03"
occurrences: 4
occurrences_v4: 0
evidence:
  - "2026-03-28: User corrected missing auth.uid()"
---
```

`status: draft` (default for new instincts) tracks occurrences/sessions in
silence but never injects; auto-promotes to `confirmed` at
`occurrences >= 5 AND sessions_seen >= 3`. Legacy instincts without the field
are treated as `confirmed`. `occurrences_v4` is the post-fix law-promotion
counter (starts at 0 via lazy migration); the pre-v4 value survives in
`occurrences_legacy`.

## Domains

workflow-general | web-development | saas-development | database |
deployment | automation | documentation | testing | security

## Agents

| Agent | Model | Purpose |
|-------|-------|---------|
| cortex-observer | Opus 1M | Detect patterns in observations (cross-project, full context) |
| cortex-reviewer | Sonnet x3 | Parallel code review (security + quality + correctness) |
| cortex-planner | Sonnet | Task decomposition |

## Token Budget (~1,750/session)

- SessionStart: ~550 (laws + EOD + context bridge)
- PreToolUse: ~40 avg per tool use (max 3 instincts + 2 reflexes)
