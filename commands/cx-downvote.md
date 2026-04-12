---
name: cx-downvote
description: Downvote the last injected instinct — negative feedback reduces confidence
command: true
---

# /cx-downvote

## What it does

Records negative feedback for the most recently injected instinct(s). When an instinct fires incorrectly or is not helpful, the user can downvote it to reduce its confidence over time. This closes the feedback loop — Cortex can now lower confidence, not just raise it.

## Usage

```
/cx-downvote                    # Downvote all instincts from last injection
/cx-downvote gotcha-rls-silent  # Downvote a specific instinct by ID (partial match)
```

## Implementation

### Step 1: Identify target instinct(s)

Read `~/.claude/cortex/.last-instinct` — JSON file written by injector.sh on every PreToolUse:

```json
{"ids": ["gotcha-rls-silent-fail", "pattern-test-after-change"], "ts": "2026-04-12T14:30:00Z"}
```

- **No argument**: downvote ALL instinct IDs from `.last-instinct`
- **With argument**: match the argument (partial or full) against the IDs. If no match, show the list and ask user to pick.
- **File missing or stale (>1 hour)**: "No recent instinct injection found. Run a tool first so Cortex can inject instincts, then try again."

### Step 2: Record downvote

Read `~/.claude/cortex/instinct-tracking.json`. For each target instinct:

1. If key doesn't exist, create it with `count: 0, downvotes: 1`
2. If key exists, increment `downvotes` field (add field if missing, default 0)
3. Record `last_downvote` timestamp

### Step 3: Evaluate confidence adjustment

For each downvoted instinct, calculate rejection rate:

```
rejection_rate = downvotes / max(count, 1)
```

| Rejection Rate | Action |
|---|---|
| < 0.20 | No change — occasional misfire is normal |
| 0.20 – 0.30 | Reduce confidence by 0.05 |
| 0.30 – 0.50 | Reduce confidence by 0.10 |
| > 0.50 | Reduce confidence by 0.15 |

Apply confidence reduction to the instinct's YAML file:
- Read current confidence from YAML frontmatter
- Subtract the penalty
- Write back with atomic tmp+rename
- If confidence drops below 0.10, move instinct to archive directory

### Step 4: Display result

```
================================================================
  INSTINCT DOWNVOTED — Cortex
================================================================

  ID:              gotcha-rls-silent-fail
  Downvotes:       3 / 47 activations (6.4%)
  Action:          No confidence change (rate < 20%)

  ID:              pattern-test-after-change
  Downvotes:       8 / 22 activations (36.4%)
  Action:          Confidence reduced: 0.80 → 0.70
  File:            ~/.claude/cortex/instincts/global/pattern-test-after-change.yaml

================================================================
```

If an instinct was archived:
```
  ⚠ gotcha-rls-silent-fail archived (confidence dropped below 0.10)
    Moved to: ~/.claude/cortex/instincts/archive/
```

## Edge cases

- **No `.last-instinct` file**: show message, suggest running a tool first
- **Instinct already archived**: skip, inform user
- **Downvoting a law** (confidence >= 0.90): warn "This is a crystallized law. Downvoting will demote it to instinct level. Proceed? [y/N]"
- **Multiple instincts in last injection**: downvote all unless user specifies one

## What NOT to do

- Do not delete instincts — always archive (preserves history)
- Do not modify reflexes — reflexes are deterministic, not probabilistic
- Do not reduce confidence below 0.05 — always archive at that point instead
- Do not write to any file other than instinct-tracking.json and the target instinct YAML
