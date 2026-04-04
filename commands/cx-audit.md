---
name: cx-audit
description: Audit Cortex ecosystem — token overhead, duplicates, conflicts, unused artifacts
command: true
---

# /cx-audit

## What it does

Audits the entire Cortex ecosystem: laws, instincts, reflexes, evolved artifacts. Calculates token overhead, detects duplicates and conflicts, identifies unused components, and proposes cleanup actions.

## Usage

```
/cx-audit                # Full audit
/cx-audit --fix          # Auto-apply safe fixes (archive unused, compress oversized)
```

## Implementation

### Step 1: Scan Everything

Scan these locations:
- `~/.claude/cortex/laws/*.txt` — Active laws
- `~/.claude/cortex/instincts/global/*.yaml` — Global instincts
- `~/.claude/cortex/projects/*/instincts/*.yaml` — Project instincts
- `~/.claude/cortex/reflexes.json` — Active reflexes
- `~/.claude/cortex/evolved/{skills,commands,rules}/` — Evolved artifacts
- `~/.claude/skills/` — Installed skills (for overlap detection)

For each file:
- Read file size
- Estimate token count: `tokens ≈ file_size_bytes / 4`
- Extract metadata (id, trigger, action, confidence, domain)
- Record last_seen / lastFired dates

### Step 2: Token Overhead Analysis

```
TOKEN OVERHEAD ANALYSIS

  ALWAYS-ACTIVE (every session):
  Component                    Count    Tokens
  Laws                         8        ~240
  SessionStart overhead        —        ~550
  ─────────────────────────────────────────────
  Subtotal:                             ~550/session

  PER-TOOL-USE (when matched):
  Instincts (global)           12       ~480 (max 2 injected = ~80)
  Instincts (project)          8        ~320 (max 2 injected = ~80)
  Reflexes                     8        ~160 (max 2 injected = ~40)
  ─────────────────────────────────────────────
  Subtotal per tool use:                ~120 max

  ESTIMATED SESSION TOTAL:              ~1,750 tokens
```

### Step 3: Duplicate Detection

Compare all instincts pairwise:
- **Trigger overlap**: Jaccard similarity > 0.70 on trigger tokens
- **Action overlap**: Jaccard similarity > 0.70 on action tokens
- **Same domain**: both in the same domain

Flag pairs as duplicates if both trigger AND action overlap > 0.70.

### Step 4: Conflict Detection

Look for contradictions:
- Instinct A says "always do X", Instinct B says "never do X"
- Two instincts with same trigger but opposite actions
- Reflex contradicts an instinct in the same domain

### Step 5: Usage Analysis

- Reflexes with `fireCount: 0` — never triggered, candidate for removal
- Instincts with `last_seen` > 60 days ago — stale, candidate for archive
- Instincts with `occurrences: 0` or 1 — weak evidence
- Evolved artifacts not referenced by any active instinct

### Step 6: Present Cleanup Proposal

```
CORTEX AUDIT — Your Installation

  Total components:     N
  Token overhead:       ~T tokens/session

  ════════════════════════════════════════════
  CLEANUP PROPOSAL
  ════════════════════════════════════════════

  DUPLICATES (merge recommended):
  ────────────────────────────────
  1. [instinct-a] ≈ [instinct-b]
     Overlap: 85% trigger, 72% action
     Savings: ~40 tokens
     [M] Merge  [K] Keep both  [S] Skip

  UNUSED (archive recommended):
  ─────────────────────────────
  2. [reflex-id] (0 fires, created 45 days ago)
     [A] Archive  [K] Keep  [S] Skip

  3. [instinct-id] (last seen 90 days ago, conf: 0.25)
     [A] Archive  [K] Keep  [S] Skip

  OVERSIZED (compress recommended):
  ─────────────────────────────────
  4. [evolved-skill] (2.4 KB / ~600 tokens)
     Could extract examples to reduce
     [C] Compress  [K] Keep  [S] Skip

  NO ISSUES:
  ──────────
  - [list of clean components]

  ════════════════════════════════════════════
  SAVINGS SUMMARY
  ════════════════════════════════════════════

  If all recommendations accepted:
    Merge:     -T tokens
    Archive:   -T tokens
    Compress:  -T tokens
    ─────────────────────
    Total:     -T tokens/session

    Before: ~T tokens
    After:  ~T tokens
```

### Step 7: Execute Chosen Actions

- **Merge [M]**: Keep higher-confidence instinct, merge unique info from the other, archive the duplicate
- **Archive [A]**: Move to `instincts/archive/` or disable reflex
- **Compress [C]**: Extract verbose sections, replace with concise version
- **Keep [K]**: No action

### Step 8: Summary

```
AUDIT COMPLETE

  BEFORE                          AFTER
  ──────                          ─────
  N components                    N components
  ~T tokens                       ~T tokens
  N duplicates                    0 duplicates
  N unused                        0 unused

  Changes applied:
  - Merged [a] into [b]
  - Archived [c] (unused 90 days)
```

## Important Notes

- Never delete permanently — always archive
- Show token impact for every proposed action
- Ask permission before merging or archiving
- Respect user choices (keep is always valid)
