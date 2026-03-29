---
name: cortex
description: |
  Continuous learning system for Claude Code. Observes sessions,
  crystallizes patterns as atomic instincts with confidence scoring,
  distills proven knowledge into laws. Commands: /cx-status, /cx-learn,
  /cx-eod, /cx-gotcha, /cx-export, /cx-backup, /cx-restore.
auto_activate: true
---

# Cortex -- Continuous Learning System

> Every session creates a connection. Cortex turns them into instinct.

## Architecture

3-level knowledge distillation:

```
Observations (JSONL, async hooks, 0 tokens)
    | /cx-learn
Instincts (YAML, on demand, ~50-100 tokens each)
    | confidence >= 0.90
Laws (TXT one-liners, injected every session, ~30 tokens each)
```

## Data Location

`~/.claude/cortex/`

## How It Works

### Automatic (no user action needed)
- **Laws** injected at session start via SessionStart hook
- **EOD Resume** injected at session start -- Claude MUST present it proactively (see below)
- **Observations** captured silently via async PreToolUse/PostToolUse hooks
- **Reflexes** fire deterministically via PreToolUse hook (reflex-engine.sh)
- After ~50 observations, session-start suggests running /cx-learn

### Session Start Behavior (MANDATORY)

When the system prompt contains `EOD RESUME`, Claude MUST proactively present it in the **first response** of the session, WITHOUT the user asking. Format:

1. **Greeting** -- Brief saludo
2. **Yesterday's summary** -- Paraphrase the EOD RESUME content (1-2 lines)
3. **Learning status** -- If there are pending observations, mention `/cx-learn`
4. **Today's priorities** -- List the PRIORITIES as a numbered list
5. **Ask** -- "¿Por dónde empezamos?"

This is the default opening behavior. If the user's first message already asks for something specific, address their request first, then briefly mention the EOD context if relevant.

### On Demand (user invokes)
- `/cx-learn` -- Full pipeline: analyze observations, create/update instincts, distill laws, check promotions, offer inheritance/bootstrap for new projects
- `/cx-status` -- Dashboard: laws, instincts, projects, reflexes, system health
- `/cx-eod` -- End of day summary, saves context for next session
- `/cx-gotcha` -- Capture error->fix as high-priority instinct
- `/cx-export` -- Generate portable skill with condensed instincts for Claude web/app
- `/cx-backup` -- Create portable .tar.gz backup of all knowledge for machine transfer
- `/cx-restore` -- Import knowledge from a backup archive, merging with existing data

## Confidence Tiers

| Range | Tier | Meaning |
|-------|------|---------|
| 0.0-0.3 | Observation | Raw, unvalidated |
| 0.3-0.5 | Hypothesis | Seen 2x, plausible |
| 0.5-0.7 | Pattern | Consistent, likely correct |
| 0.7-0.9 | Instinct | Validated, reliable |
| 0.9-1.0 | Law | Proven cross-project, crystallized |

## Confidence Adjustments

| Event | Change |
|-------|--------|
| User says "always/never" | +0.3 |
| User corrects Claude | +0.2 |
| Pattern seen 2x same session | +0.1 |
| Pattern in 3+ sessions | +0.2 |
| Pattern in 5+ sessions | +0.3 |
| Pattern in 2+ projects | +0.15 |
| Reinforced (applied, not corrected) | +0.1 |
| 60 days without observation | -0.1 |
| User contradicts instinct | -0.2 |

## Instinct Format (YAML)

```yaml
---
id: example-instinct
trigger: "when doing X in context Y"
confidence: 0.7
domain: "workflow-general"
source: "session-observation"
scope: project
---

# Descriptive Title

## Action
What to do -- concrete, actionable.

## Evidence
- What observations generated this
- Frequency and last seen date
```

## Domains

| Domain | Description |
|--------|-------------|
| workflow-general | Cross-project patterns (git, tools, workflow) |
| web-development | Frontend, backend, APIs, frameworks |
| saas-development | SaaS, multi-tenancy, subscriptions |
| deployment | CI/CD, Docker, infrastructure |
| automation | Scripts, workflows, integrations |
| documentation | Docs, READMEs, specs |
| testing | Unit, integration, E2E, QA |
| security | Auth, permissions, secrets, compliance |

## Promotion Criteria (project -> global)

- Same pattern in **2+ projects** (semantic matching, Jaccard >= 0.70)
- Average confidence **>= 0.80**
- Compatible domain (workflow-general, security, testing, documentation, automation)

## Reflexes

`~/.claude/cortex/reflexes.json` -- deterministic rules fired via hooks.
Applied automatically, never interrupt the user. Silent enforcement.

## Memory

`~/.claude/cortex/memory.json` -- persistent memory (identity, config, and stats).
Read when you need user context (identity, config, preferences).

## Agents

| Agent | Purpose | Model |
|-------|---------|-------|
| cortex-observer | Detect patterns in observations | Haiku |
| cortex-reviewer | Code review after edits | Haiku |
| cortex-planner | Decompose complex tasks | Sonnet |
