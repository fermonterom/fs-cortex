---
name: cx-analyze
description: Analyze observations to detect patterns and propose instincts
command: true
---

# /cx-analyze

## What it does

Reads ALL observations for the current project (or all projects with --global), detects patterns using the cortex-observer agent (Haiku), and writes proposals to `~/.claude/cortex/proposals.json`.

## Usage

```
/cx-analyze              # Current project (observations only)
/cx-analyze --git        # Also mine git history for patterns
/cx-analyze --global     # All projects
/cx-analyze --accept     # Auto-accept all proposals as instincts
/cx-analyze --dry-run    # Show what would be proposed without writing
```

## Implementation

### Step 1: Detect Context

- Identify current project via git remote hash
- Look up in `~/.claude/cortex/projects/registry.json`
- Count observations in project's `observations.jsonl`
- Count existing instincts (project + global)

Display:
```
CORTEX ANALYZE — Context
  Project: [name] ([hash])
  Observations: N
  Instincts: N project + N global
```

### Step 2: Validate

- If < 10 observations AND --git not passed: inform and exit
  "Only N observations found. Need at least 10 for meaningful analysis. Try /cx-analyze --git to mine git history instead."
- If --global: iterate all projects in registry.json

### Step 2b: Mine Git History (--git flag)

If --git is passed, also analyze the project's git history as supplementary data:

```bash
# Recent commits (last 200)
git log --oneline -200

# Most frequently changed files
git log --pretty=format: --name-only -200 | sort | uniq -c | sort -rn | head -20

# Fix/hotfix patterns (error-resolution signal)
git log --oneline -200 --grep="fix" --grep="hotfix" --grep="patch" --grep="bug" --grep-reflog="all"

# Files that change together (coupling)
git log --pretty=format: --name-only -200 | awk '/^$/{if(NR>1)print "---";next}{print}' | head -100

# Tech stack detection
# Read package.json, Cargo.toml, requirements.txt, etc.
```

From git data, detect:
- **Hotspot files**: files changed 5+ times → instinct about careful testing before editing
- **Fix patterns**: repeated "fix:" commits on same area → gotcha instinct candidate
- **File coupling**: files that always change together → workflow instinct
- **Tech stack**: frameworks and dependencies → domain-specific instincts
- **Commit conventions**: detect if conventional commits are used

Git-derived proposals get source: "git-history" and initial confidence 0.30-0.50 (lower than observation-derived since we're inferring, not observing directly).

### Step 3: Analyze Observations

1. Read `observations.jsonl` from the project directory
2. Invoke the `cortex-observer` agent (Haiku):
   - Pass the observations file path
   - Agent detects: error-fix pairs, repeated workflows, tool preferences, correction sequences
   - Agent returns patterns as instinct proposals
3. For each returned pattern:
   - Check for existing instinct with similar trigger (Jaccard >= 0.50)
   - If matches existing: note as "update candidate" (bump confidence)
   - If new: add to proposals

### Step 4: Write Proposals

Write to `~/.claude/cortex/proposals.json`:
```json
[
  {
    "id": "proposal-id",
    "trigger": "regex pattern",
    "action": "what to do",
    "confidence": 0.35,
    "domain": "domain",
    "source": "cx-analyze",
    "detected": "2026-04-04",
    "project_id": "hash",
    "project_name": "name",
    "status": "pending"
  }
]
```

Deduplicate by id (keep most recent).

### Step 5: Summary

```
CORTEX ANALYZE — Results
  Observations analyzed: N
  New proposals: N
  Update candidates: N (existing instincts to bump)

  Review proposals with /cx-validate
  Or accept all with /cx-analyze --accept
```

### --accept flag

If --accept is passed, skip proposals and directly:
1. Create instinct YAML files from proposals
2. Write to project's `instincts/` or `instincts/global/` based on scope
3. Clear accepted proposals from proposals.json

## What NOT to do

- Do not run automatically — only when user invokes /cx-analyze
- Do not delete observations after analysis
- Do not overwrite existing instincts without user review
