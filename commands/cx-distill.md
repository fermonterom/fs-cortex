---
name: cx-distill
description: Distill laws from mature instincts, apply decay, check promotions
command: true
---

# /cx-distill

## What it does

Maintenance command that:
1. Auto-distills Laws from instincts with confidence >= 0.90
2. Applies confidence decay (-0.05 per 30 days unused)
3. Checks Jaccard promotions (project → global)
4. Archives decayed instincts (confidence < 0.10)
5. Enforces max 10 active laws

## Usage

```
/cx-distill              # Full maintenance pass
/cx-distill --dry-run    # Show what would change without writing
```

## Implementation

### Step 1: Scan All Instincts

Read all instinct YAML files from:
- `~/.claude/cortex/instincts/global/*.yaml`
- `~/.claude/cortex/projects/*/instincts/*.yaml`

For each, extract: id, trigger, action, confidence, domain, tags, scope, last_seen, occurrences

### Step 2: Apply Confidence Decay

For each instinct:
```
days_unused = (today - last_seen).days
decay_periods = floor(days_unused / 30)
new_confidence = confidence - (0.05 * decay_periods)
```

If new_confidence < 0.10:
- Move YAML file to `~/.claude/cortex/instincts/archive/`
- Display: "Archived [id] — confidence decayed to [value]"

If confidence changed:
- Update the YAML file with new confidence and add evidence note: "Decay applied: -X on YYYY-MM-DD"

### Step 3: Auto-Distill Laws

Scan instincts with confidence >= 0.90 that don't have a corresponding law:

For each:
1. Condense action into one-liner (max 120 chars)
   Format: "When X, do Y" or "Always X when Y" or "NEVER X"
2. Write to `~/.claude/cortex/laws/{id}.txt`

If more than 10 laws after distillation:
- Sort by source instinct confidence descending
- Archive lowest to `~/.claude/cortex/laws/archive/`

### Step 4: Check Jaccard Promotions

For each project-scoped instinct with confidence >= 0.80:
1. Compute Jaccard similarity of trigger + action tokens against all instincts in OTHER projects
2. If Jaccard >= 0.70 and pattern exists in 2+ projects:
   - Create global copy in `~/.claude/cortex/instincts/global/`
   - Set scope: global, confidence: average of matched instincts
   - Mark source instincts with `promoted_to: "{global-id}"`

Jaccard computation:
```
tokens_a = set(trigger_a.split("|") + action_a.lower().split())
tokens_b = set(trigger_b.split("|") + action_b.lower().split())
jaccard = len(tokens_a & tokens_b) / len(tokens_a | tokens_b)
```

### Step 5: Summary

```
CORTEX DISTILL — Results
  Instincts scanned: N
  Decay applied: N instincts
  Archived (decayed): N
  Laws distilled: N
  Promotions (project→global): N
  Active laws: N/10
```

## Recommended schedule

Run weekly, or when /cx-status shows mature instincts ready for distillation.
