---
name: cx-timeline
description: View the semantic knowledge log — every knowledge-changing event in Cortex
command: true
---

# /cx-timeline

## What it does

Displays the knowledge event log — a chronological record of every instinct creation, promotion, decay, archive, downvote, and evolution in the system. Useful for understanding how knowledge has changed over time and for debugging why an instinct appeared or disappeared.

## Usage

```
/cx-timeline                    # Show last 20 events
/cx-timeline --last 50          # Show last 50 events
/cx-timeline --event promoted   # Filter by event type
/cx-timeline --since 2026-04-01 # Events since a specific date
/cx-timeline --stats            # Show summary statistics only
```

## Implementation

### Step 1: Read Knowledge Log

Read `~/.claude/cortex/knowledge-log.md`.

If the file does not exist or is empty, display:

```
CORTEX TIMELINE
===============
No knowledge events recorded yet.
Events are logged automatically when you run Cortex commands
(cx-validate, cx-distill, cx-dream, cx-downvote, cx-evolve, cx-promote)
and by the injector engine (auto-promote).
```

Then stop — do not continue to further steps.

### Step 2: Parse and Filter

Each line has the format:
```
YYYY-MM-DD | event_type | instinct-id | confidence_info | source_command
```

Parse each line by splitting on ` | ` (pipe with surrounding spaces, 5 fields).
Skip malformed lines silently (lines that do not produce exactly 5 fields).

Apply filters if provided:
- `--last N`: show only the last N events (default: 20)
- `--event TYPE`: filter to matching event_type (created, rejected, promoted, decayed, archived, downvoted, evolved, law, deduped, global, auto-promote)
- `--since DATE`: filter to events on or after the given date (YYYY-MM-DD comparison)

Filters stack — e.g. `--event promoted --since 2026-04-01` shows only promoted events since April 1st.

### Step 3: Display Events

```
================================================================
  CORTEX TIMELINE — Knowledge Event Log
  Showing: last N events (of M total)
================================================================

  DATE         EVENT        INSTINCT                        CONFIDENCE   SOURCE
  ──────────────────────────────────────────────────────────────────────────────
  2026-04-12   created      gotcha-rls-silent-fail          0.30         cx-validate
  2026-04-12   promoted     pattern-parallel-agents         0.55→0.70    cx-distill
  2026-04-11   decayed      gotcha-old-pattern              0.45→0.40    cx-dream
  2026-04-11   archived     pref-deprecated-thing           0.15         cx-dream
  2026-04-10   auto-promote gotcha-draft-example            0.25→0.35    injector-engine
```

Show events in chronological order (oldest first), applying --last N to take the tail.

### Step 4: Summary Statistics

Always shown after the event table (or alone if `--stats` flag):

Count events in the **last 7 days** from the log and display:

```
  LAST 7 DAYS:
    Created: 5  |  Promoted: 2  |  Decayed: 3  |  Archived: 1
    Laws: 0     |  Downvoted: 0 |  Evolved: 0  |  Auto-promote: 4
    Total events: 16
```

If `--stats` flag is provided, show ONLY the statistics section (skip the event table in Step 3).

## Event Types Reference

| Event | Meaning | Source |
|---|---|---|
| created | Proposal accepted → instinct created | cx-validate |
| rejected | Proposal rejected | cx-validate |
| promoted | Confidence increased | cx-distill |
| decayed | Confidence reduced by staleness | cx-distill, cx-dream |
| archived | Instinct moved to archive | cx-distill, cx-dream, cx-downvote |
| law | Instinct distilled to law | cx-distill |
| global | Project → global promotion | cx-distill, cx-promote |
| downvoted | Negative feedback applied | cx-downvote |
| deduped | Duplicate removed | cx-dream |
| evolved | Cluster → skill/command/rule | cx-evolve |
| auto-promote | Draft auto-promoted (5+ fires, 3+ sessions) | injector-engine |

## What NOT to do

- Do not modify the knowledge-log.md file — this is a read-only command
- Do not show events that don't match the applied filters
- If the file has malformed lines, skip them silently (don't error out)
- Do not create the file if it does not exist
