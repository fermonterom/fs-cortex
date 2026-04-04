---
name: cx-evolve
description: Evolve clusters of mature instincts into skills, commands, or rules
command: true
---

# /cx-evolve

## What it does

The final step in the learning pipeline. Finds clusters of 3+ mature instincts (confidence >= 0.70) in the same domain, and generates reusable artifacts: skills, commands, or passive rules.

## Usage

```
/cx-evolve               # Scan and propose evolutions
/cx-evolve --dry-run     # Show what would be generated without writing
```

## Implementation

### Step 1: Scan Mature Instincts

Read all instinct YAML files (global + all projects). Filter to confidence >= 0.70.

Group by domain. For each domain with 3+ instincts:
1. Compute pairwise Jaccard similarity on trigger + action tokens
2. Cluster instincts with Jaccard >= 0.50 (related patterns)

### Step 2: Propose Artifact Type

For each cluster of 3+ related instincts, determine the best artifact type:

| Pattern | Artifact | Example |
|---------|----------|---------|
| All about same technology/API | Skill (.md) | fs-supabase-rls.md |
| All about same workflow step | Command (.md) | fs-pre-deploy-check.md |
| All simple guard rules | Passive Rule (reflexes.json) | New entries in reflexes.json |

Present to user:
```
EVOLUTION CANDIDATE: [domain]
  Instincts in cluster:
    1. [id] (conf: [value]) — [action summary]
    2. [id] (conf: [value]) — [action summary]
    3. [id] (conf: [value]) — [action summary]

  Proposed artifact: [Skill | Command | Rule]
  Proposed name: fs-[descriptive-name]

  [G] Generate  [S] Skip  [C] Change type
```

### Step 3: Generate Artifact

Use Sonnet to synthesize the cluster into a coherent artifact:

For **Skills**: Generate a SKILL.md with:
- Metadata (name, description, triggers)
- Consolidated action instructions
- Evidence from source instincts

For **Commands**: Generate a command .md with:
- Metadata (name, description)
- Step-by-step implementation
- Based on patterns from source instincts

For **Rules**: The canonical output is new entries appended to `~/.claude/cortex/reflexes.json` with:
- matcher, condition, action derived from instinct triggers/actions
- A backup copy of the generated rule entries is also written to `~/.claude/cortex/evolved/rules/` for reference (not authoritative — reflexes.json is the source of truth)

### Step 4: Write and Mark Sources

1. Write artifact to `~/.claude/cortex/evolved/{skills,commands,rules}/`
2. All generated files MUST use `fs-` prefix (e.g., `fs-supabase-rls.md`)
3. Update source instincts: set `evolved_to: "{artifact-id}"` in their YAML

### Step 5: Summary

```
CORTEX EVOLVE — Results
  Clusters found: N
  Artifacts generated:
    - fs-supabase-rls.md (Skill, from 4 instincts)
    - fs-pre-deploy-check.md (Command, from 3 instincts)

  Install evolved skills with:
    cp ~/.claude/cortex/evolved/skills/*.md ~/.claude/skills/
```

## Guidelines

- Conservative: only evolve clusters with strong agreement (3+ instincts, conf >= 0.70)
- User approval required for each generation
- Never delete source instincts (they keep accumulating evidence)
- Prefix all artifacts with fs-
