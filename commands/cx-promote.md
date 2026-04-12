---
name: cx-promote
description: Promote project-scoped instincts to global when detected in multiple projects
command: true
---

# /cx-promote

## What it does

Detects instincts that exist in multiple projects (via Jaccard similarity) and offers to promote them to global scope. This crystallizes cross-project patterns into reusable knowledge.

## Usage

```
/cx-promote              # Scan all projects for promotion candidates
/cx-promote --dry-run    # Show candidates without applying changes
```

## Implementation

### Step 1: Collect All Project Instincts

Scan `~/.claude/cortex/projects/*/instincts/*.yaml` to collect all project-scoped instincts.

For each instinct, parse: id, trigger, action, confidence, domain, last_seen.

### Step 2: Find Cross-Project Matches

Compare each project instinct against instincts in OTHER projects using Jaccard similarity:

```python
import sys
sys.path.insert(0, os.path.expanduser("~/.claude/hooks/cortex/lib"))
from dream_cycle import jaccard_similarity
```

Promotion criteria (all must be met):
- Jaccard similarity >= 0.70 with instinct in another project
- Present in >= 2 different projects
- Average confidence >= 0.60 across projects
- NOT already in `~/.claude/cortex/instincts/global/`

### Step 3: Present Candidates

For each candidate, show:
```
PROMOTION CANDIDATE #1:
  Action: "Always run tests before committing changes"
  Found in: project-a (conf: 0.75), project-b (conf: 0.80), project-c (conf: 0.65)
  Similarity: 0.82 (Jaccard)
  Avg confidence: 0.73
  Recommendation: PROMOTE (3 projects, high confidence)

  [A] Accept (promote to global)
  [X] Reject (keep project-scoped)
  [S] Skip (decide later)
```

### Step 4: Apply Promotions

For accepted candidates:
1. Create new YAML file in `~/.claude/cortex/instincts/global/` with:
   - Merged action text (from highest-confidence version)
   - Confidence = average across projects (capped at 0.85)
   - Domain = most common domain across matches
   - `promoted_from` field listing source projects
   - `promoted_date` field with current date
2. Do NOT delete the project-scoped originals (they may have project-specific trigger patterns)

### Step 4b: Log to Knowledge Timeline

After applying promotions in Step 4, append one line per promoted instinct to `~/.claude/cortex/knowledge-log.md`:

```bash
echo "$(date +%Y-%m-%d) | global | {id} | {confidence} | cx-promote" >> ~/.claude/cortex/knowledge-log.md
```

### Step 5: Report

```
PROMOTION SUMMARY:
  Candidates found: N
  Promoted: M
  Skipped: K
  Rejected: J

  Promoted instincts are now in ~/.claude/cortex/instincts/global/
  They will be injected in ALL projects going forward.
```
