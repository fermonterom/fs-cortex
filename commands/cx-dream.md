---
name: cx-dream
description: Run Dream Cycle — dedup, contradiction detection, staleness decay, regex validation, health score
command: true
---

# /cx-dream

## What it does

Knowledge maintenance cycle that runs 5 modules in sequence:
1. **Jaccard dedup** — removes duplicate instincts (threshold 0.80)
2. **Contradiction detection** — finds conflicting instincts in the same domain
3. **Staleness scoring + auto-archive** — decays confidence, archives stale instincts (score >= 90)
4. **Regex validation** — checks all instinct triggers for safety (ReDoS, length, syntax)
5. **Health score** — calculates overall knowledge health 0-100

## Usage

```
/cx-dream              # Full dream cycle
/cx-dream --dry-run    # Show what would change without writing
```

## Implementation

### Step 1: Load All Instincts

Read all instinct YAML files from:
- `~/.claude/cortex/instincts/global/*.yaml`
- `~/.claude/cortex/projects/*/instincts/*.yaml`

Parse each into a dict with: id, trigger, action, confidence, domain, last_seen, created.

### Step 2: Run Dream Cycle Modules

Use the Python module at `hooks/lib/dream_cycle.py`:

```python
import sys
sys.path.insert(0, os.path.expanduser("~/.claude/hooks/cortex/lib"))
from dream_cycle import (
    dedup_instincts,
    detect_contradictions,
    apply_staleness_decay,
    validate_trigger_regex,
    calculate_health_score,
)
```

Execute in order:

1. **Dedup**: `dedup_instincts(all_instincts, threshold=0.80)`
   - Report removed duplicates with their Jaccard similarity scores
   - Keep the instinct with higher confidence

2. **Contradictions**: `detect_contradictions(all_instincts)`
   - Report contradiction pairs with their IDs and conflicting keywords
   - Ask user which to keep/remove/modify

3. **Staleness**: `apply_staleness_decay(all_instincts, archive_threshold=90)`
   - Report decayed instincts with old → new confidence
   - Move archived instincts to `~/.claude/cortex/instincts/archive/`

4. **Regex validation**: `validate_trigger_regex(trigger)` for each instinct
   - Report invalid triggers and ask user to fix or remove

5. **Health score**: `calculate_health_score(stats)`
   - Display score with breakdown
   - **Maintenance bonus/penalty** (from `~/.claude/cortex/log/timeline.jsonl`): +5 if cx-dream or cx-distill run in last 14 days, -5 if no maintenance command run in 30 days. Skip if timeline.jsonl missing.

### Step 3: Apply Changes

If not `--dry-run`:
- Delete duplicate YAML files (keep the winner)
- Update confidence values in YAML frontmatter for decayed instincts
- Move archived instincts to archive directory
- Update `~/.claude/cortex/.last-dream` timestamp

### Step 4: Report

Display a summary:

```
=== Dream Cycle Report ===

Duplicates removed: 3
Contradictions found: 1
  - gotcha-always-mock vs gotcha-never-mock (always/never)
Instincts decayed: 5
Instincts archived: 2
Invalid triggers: 0

Health Score: 82/100
  Staleness: -4
  Contradictions: -10
  Duplicates: 0
  Laws bonus: +6
  Confidence bonus: +5

Last dream: 2026-04-09
Next recommended: 2026-04-16
```

### Confirmation

Before applying destructive changes (archive, delete), ask the user for confirmation:
- Show each duplicate pair and which will be kept
- Show each contradiction and ask for resolution
- Show each instinct to be archived

Only write changes after user confirms.
