---
name: cx-learn
description: Full learning pipeline — analyze observations, create instincts, distill laws, evolve skills
command: true
---

# /cx-learn

## What it does

Full learning pipeline in one command. Analyzes observations, creates/updates instincts, distills laws, checks promotions, and offers inheritance for new projects.

## Usage

```
/cx-learn                # Full pipeline
/cx-learn --dry-run      # Show what would happen without writing
/cx-learn --global       # Analyze across all projects
/cx-learn --bootstrap    # Force bootstrap from git history
/cx-learn --inherit      # Force inheritance check
```

## Implementation

### Step 1: Detect Context

- Identify current project via git remote hash or cwd
- Look up project in `~/.claude/cortex/projects/registry.json`
- Count observations in project's `observations.jsonl`
- Count existing instincts (project + global)

Display:

```
CORTEX LEARN — Context
  Project: [name] ([hash])
  Observations: N
  Instincts: N project + N global
```

### Step 2: Bootstrap Check (new projects only)

**If project has 0 observations AND git history (50+ commits):**

Ask: "This project has N commits but no Cortex observations. Analyze git history to bootstrap initial instincts? (Y/N)"

If yes:
1. Run `git log --oneline -200` to scan commit patterns
2. Detect: file change frequency, common fix patterns, tech stack, commit conventions
3. Generate initial instincts from detected patterns
4. Write to project's `instincts/personal/`

**If project has 0 observations AND no git history:**

Scan `~/.claude/cortex/projects/registry.json` for similar projects.
Similarity detection:
- Read `package.json`, `Cargo.toml`, `requirements.txt`, etc. to detect stack
- Compare against registered projects' tech stacks

If matches found: "Found similar projects: [list]. Inherit their instincts? (Y/N)"
If yes: copy compatible instincts (matching domain) with confidence reduced by 0.1.

### Step 3: Analyze Observations

**Requires minimum 10 observations.** If fewer, inform user:
"Only N observations found. Need at least 10 for meaningful analysis. Keep working and run /cx-learn again later."

If sufficient observations:

1. Read `observations.jsonl` from the project directory
2. Invoke the `cortex-observer` agent:
   - Pass the observations file path
   - Agent analyzes patterns: repeated tool calls, error→fix sequences, workflow patterns, preference signals
   - Agent returns detected patterns as instinct YAML
3. For each returned pattern:
   - If new: write to project's `instincts/personal/` with initial confidence
   - If matches existing instinct: bump confidence by 0.05 (cap at 0.95)
   - If contradicts existing instinct: reduce confidence of existing by 0.1

### Step 4: Evolve

Review all instincts (project + global) with confidence >= 0.70.

Group related instincts by:
- Same `domain`
- Similar `trigger` keywords (Jaccard similarity >= 0.50)

For each cluster of 3+ related instincts:
1. Analyze if the cluster represents a coherent skill, command, or agent pattern
2. Ask: "These N instincts in [domain] could become a [Skill/Command/Agent]: '[proposed name]'. Generate? (Y/N)"
3. If yes: generate and write to `~/.claude/cortex/evolved/{skills,commands,agents}/`

### Step 5: Distill Laws

Scan all instincts with confidence >= 0.90.

For each that does not already have a corresponding law in `~/.claude/cortex/laws/`:
1. Condense the instinct into a one-liner (max 120 chars)
2. Write to `~/.claude/cortex/laws/{id}.txt`

If more than 10 laws exist after distillation:
- Keep only the top 10 by confidence
- Archive the rest to `~/.claude/cortex/laws/archive/`

### Step 6: Check Promotions

Scan current project's instincts against all other projects' instincts.

Matching criteria:
- Jaccard similarity >= 0.70 on trigger + action keywords
- Same domain or compatible domains

If same pattern found in 2+ projects with average confidence >= 0.80:
1. Create a global version in `~/.claude/cortex/instincts/personal/`
2. Set scope to `global`
3. Set confidence to average of matched instincts
4. Mark source projects in the instinct metadata

### Step 7: Summary

Display what happened:

```
================================================================
  CORTEX LEARN — Summary
================================================================

  New instincts created:       N
  Instincts updated:           N (confidence changes)
  Laws distilled:              N
  Promotions (project->global): N
  Evolution candidates:        N

  Details:
  + [instinct-id] — created (confidence: 0.65)
  ~ [instinct-id] — updated (0.70 -> 0.75)
  ^ [instinct-id] — promoted to global (0.85)
  * [law-id] — distilled from [instinct-id]

================================================================
```

### Step 8: Cleanup

- Delete `.learn-pending` marker if it exists in `~/.claude/cortex/`
- Update project's `last_learned` timestamp in registry.json

## Edge cases

- **No observations file**: create empty one and inform user
- **Corrupted YAML**: skip and warn, do not crash the pipeline
- **Observer agent unavailable**: fall back to simple frequency analysis of observations
- **--dry-run**: run all analysis but prefix every write with "[DRY RUN]" and skip actual file writes
- **--global**: iterate over all projects in registry.json instead of just current

## What NOT to do

- Do not run automatically — only when user invokes /cx-learn
- Do not delete observations after analysis (they are the raw data)
- Do not overwrite instincts without bumping version
- Do not promote instincts that have scope: project-only (user-pinned)
