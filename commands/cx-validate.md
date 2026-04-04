---
name: cx-validate
description: Review and confirm/reject instinct proposals interactively
command: true
---

# /cx-validate

## What it does

Interactive review of pending proposals and weak instincts. Lets the user confirm (+0.20 confidence) or reject (-0.20 or delete) each one.

## Usage

```
/cx-validate             # Review all pending
/cx-validate --accept-all  # Accept all proposals
```

## Implementation

### Step 1: Load Proposals

Read `~/.claude/cortex/proposals.json`. Filter to status: "pending".

### Step 2: Load Weak Instincts

Read all instinct YAML files. Filter to confidence < 0.50 (hypotheses needing validation).

### Step 3: Present for Review

For each proposal:
```
PROPOSAL: [id]
  Trigger: [trigger regex]
  Action: [action text]
  Confidence: [value]
  Domain: [domain]
  Source: [source]
  Detected: [date]

  [A] Accept → create instinct (conf +0.20)
  [R] Reject → delete proposal
  [S] Skip → review later
```

For each weak instinct:
```
HYPOTHESIS: [id] (conf: [value])
  Trigger: [trigger]
  Action: [action]
  Last seen: [date]
  Occurrences: [count]

  [C] Confirm → confidence +0.20
  [D] Dismiss → confidence -0.20 (or delete if < 0.10)
  [S] Skip
```

### Step 4: Execute Choices

- Accept proposal: create YAML file in appropriate instincts directory with confidence + 0.20
- Reject proposal: remove from proposals.json
- Confirm instinct: update confidence + 0.20, update last_seen
- Dismiss instinct: reduce confidence by 0.20, archive if below 0.10

### Step 5: Summary

```
CORTEX VALIDATE — Results
  Proposals accepted: N
  Proposals rejected: N
  Instincts confirmed: N
  Instincts dismissed: N
  Remaining pending: N
```
