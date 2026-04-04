---
name: cx-bootstrap
description: Seed a new project with instincts from git history or similar projects
command: true
---

# /cx-bootstrap

## What it does

Seeds a new project with initial instincts by analyzing its git history or inheriting from similar projects in the registry.

## Usage

```
/cx-bootstrap            # Auto-detect method
/cx-bootstrap --git      # Force git history analysis
/cx-bootstrap --inherit  # Force inheritance from similar projects
```

## Implementation

### Step 1: Detect Project

- Identify current project via git remote hash
- Check if project has observations (if many, suggest /cx-analyze instead)
- Check if project already has instincts (if yes, confirm before overwriting)

### Step 2a: Git History Analysis (if 50+ commits)

1. Run `git log --oneline -200` to get recent commit history
2. Detect patterns:
   - File change frequency: `git log --pretty=format: --name-only | sort | uniq -c | sort -rn | head -20`
   - Common fix patterns: commits containing "fix", "hotfix", "patch"
   - Tech stack: detect from package.json, Cargo.toml, requirements.txt, etc.
   - Commit conventions: detect conventional commits format
3. Generate initial instincts from detected patterns (confidence 0.30-0.50)
4. Write to project's `instincts/` directory

### Step 2b: Inheritance (if no git history or --inherit)

1. Read `~/.claude/cortex/projects/registry.json`
2. For each registered project, detect tech stack similarity:
   - Read package.json, Cargo.toml, etc. from project root
   - Compare dependencies, frameworks, tools
3. If similar project found (shared framework + 3+ shared dependencies):
   - Copy compatible instincts (matching domain: workflow-general, testing, security)
   - Reduce confidence by 0.10 (inherited, not validated)
   - Set source: "inherited-from-{project-name}"
4. Ask user to confirm inheritance

### Step 3: Summary

```
CORTEX BOOTSTRAP — Results
  Method: git-history | inheritance | both
  Instincts created: N
  Source: [git analysis | inherited from project-name]

  Review with /cx-validate to confirm or reject.
```

## When to use

- Starting a new project
- After cloning a repo with no Cortex data
- When /cx-status shows 0 instincts for current project
