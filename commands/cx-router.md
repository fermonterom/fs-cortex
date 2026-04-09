---
name: cx-router
description: Show available Cortex commands with descriptions and estimated token costs
command: true
---

# /cx-router

## What it does

Lightweight skill router — shows all available Cortex commands with their purpose and estimated token cost. Helps users discover functionality without injecting a heavy catalog at session start.

## Implementation

### Step 1: Display Command Catalog

Show the complete list of Cortex commands with costs:

```
CORTEX COMMAND ROUTER
=====================

Command          Cost        Purpose
─────────────────────────────────────────────────────────────
/cx-status       ~200 tok    Dashboard: laws, instincts, projects, tracking, health
/cx-analyze      ~5K tok     Detect patterns in observations → proposals (Opus 1M agent)
/cx-validate     ~500 tok    Review and accept/reject proposals interactively
/cx-distill      ~800 tok    Promote instincts to laws, apply decay, Jaccard promotions
/cx-dream        ~600 tok    Dream Cycle: dedup, contradictions, staleness, health score
/cx-evolve       ~1K tok     Cluster mature instincts → skills/commands/rules
/cx-audit        ~400 tok    Token overhead, duplicates, conflicts, cleanup
/cx-eod          ~300 tok    End-of-day summary for next session
/cx-gotcha       ~200 tok    Capture error→fix as high-priority instinct
/cx-promote      ~300 tok    Promote project instinct to global (cross-project)
/cx-export       ~500 tok    Generate portable skill for Claude.ai or sharing
/cx-backup       ~100 tok    Create .tar.gz backup for machine transfer
/cx-restore      ~200 tok    Import knowledge from backup archive
/cx-router       ~50 tok     This catalog

Recommended flow:
  Work normally → /cx-analyze (when prompted) → /cx-validate → /cx-distill → /cx-dream
```

### Step 2: Show Session Token Budget

Read `~/.claude/cortex/instinct-tracking.json` and estimate current session injection cost:

```
SESSION TOKEN ESTIMATE:
  Laws injected (SessionStart):     ~400 tokens (8 laws)
  Avg instincts/tool use:           ~120 tokens (2.1 avg per tool use)
  Estimated for 50 tool uses:       ~6,400 tokens total
  Budget recommendation:            Keep under 8,000 tokens/session
```

### Step 3: Suggest Next Action

Based on system state, suggest the most useful next command:
- If `.learn-pending` exists: "Run /cx-analyze to detect patterns"
- If proposals.json has pending items: "Run /cx-validate to review N proposals"
- If instincts >30 days without distill: "Run /cx-distill for maintenance"
- If instincts >7 days without dream: "Run /cx-dream for knowledge cleanup"
- Otherwise: "System healthy. Keep working normally."
