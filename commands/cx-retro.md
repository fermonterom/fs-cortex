---
name: cx-retro
description: Weekly retrospective — aggregate Cortex activity, command usage, health trend
command: true
---

# /cx-retro

## What it does

Aggregated view of Cortex activity over the last 7 days. Shows projects worked, command usage, instinct activations, downvotes, and health score trend. Pure read-only — no file modifications.

## Usage

```
/cx-retro              # Last 7 days
/cx-retro --days 14    # Custom range
```

## Implementation

### Step 1: Gather data

Read from these sources (skip gracefully if any is missing):

1. **Timeline** (`~/.claude/cortex/log/timeline.jsonl`): filter entries within date range. Group by `cmd` field, count invocations.

2. **Instinct tracking** (`~/.claude/cortex/instinct-tracking.json`): filter instincts with `last_seen` within date range. Sort by `count` descending. Include `downvotes` if field exists.

3. **Daily summaries** (`~/.claude/cortex/daily-summaries/*.md`): list files within date range. Extract project names from headers.

4. **Project registry** (`~/.claude/cortex/projects/registry.json`): filter projects with `last_seen` within date range.

5. **Maintenance markers**:
   - `~/.claude/cortex/.last-dream` — when was dream cycle last run?
   - `~/.claude/cortex/.last-distill` — when was distill last run?
   - `~/.claude/cortex/.last-audit` — when was audit last run?

### Step 2: Compute metrics

- **Projects active**: count of unique projects from registry with `last_seen` in range
- **Commands used**: grouped count from timeline, sorted descending
- **Commands unused**: all 16 cx-* commands minus those found in timeline
- **Instincts fired**: sum of activations in range, top 5 by count
- **Downvotes**: sum of downvotes in range (from instinct-tracking.json)
- **Health trend**: compare health scores from daily summaries (if available), or from dream cycle reports

### Step 3: Generate recommendations

Apply these rules:
- Audit overdue (>30 days since `.last-audit`): "Run /cx-audit"
- Dream overdue (>14 days since `.last-dream`): "Run /cx-dream"
- Distill overdue (>7 days since `.last-distill`): "Run /cx-distill"
- Proposals pending (proposals.json has status=pending): "Run /cx-validate — N proposals waiting"
- Stale instincts (>14 days since last_seen, confidence > 0.50): "N instincts not fired recently — consider /cx-dream"
- High downvote rate (>30% on any instinct): "Review instinct [id] — 30%+ rejection rate"

### Step 4: Display

```
================================================================
  WEEKLY RETRO — 2026-04-06 to 2026-04-12
================================================================

  PROJECTS (4 active):
    trello-test, fs-cortex, storyweaver, tcuadro

  COMMANDS USED:
    cx-status    5x
    cx-dream     2x
    cx-analyze   1x

  COMMANDS UNUSED (last 7 days):
    cx-promote, cx-audit, cx-retro, cx-evolve, cx-export

  INSTINCTS FIRED (top 5):
    gotcha-rls-silent-fail          8x
    pattern-test-after-change       5x
    security-headers-vercel         3x
    e2e-playwright-selectors        2x
    gotcha-stripe-trial-fields      2x

  DOWNVOTES:
    1 total — gotcha-edge-function-deploy-loop (1/12 = 8.3%)

  RECOMMENDATIONS:
    • Run /cx-audit (last run: 32 days ago)
    • 3 instincts not fired in 14 days — consider /cx-dream
    • 9 pending proposals — run /cx-validate

================================================================
```

If timeline.jsonl is missing: "No command usage data yet. Timeline tracking starts automatically on next session end."

## Edge cases

- **No data for date range**: show empty sections with "No activity recorded"
- **Timeline missing**: skip command usage section, note it
- **First week**: show whatever data exists, no "trend" comparison
- **Very active week (>50 instinct firings)**: show top 10 instead of top 5

## What NOT to do

- Do not modify any files — this is purely read-only
- Do not run dream cycle or other maintenance — only recommend
- Do not show raw observations — only processed metrics
- If a directory or file does not exist, show "not found" for that section, do not error out
