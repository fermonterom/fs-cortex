---
name: cx-eod
description: End-of-day summary — saves context for tomorrow and triggers mini-learn
command: true
---

# /cx-eod

## What it does

Generates an end-of-day summary and saves context for the next session. Optionally triggers a quick learning cycle if enough new observations exist.

## Usage

```
/cx-eod              # Full end-of-day summary
/cx-eod --quick      # Summary only, skip mini-learn
/cx-eod --yesterday  # Show the most recent saved summary
```

## Implementation

### Step 1: Gather Context

Scan active projects (auto-detect git repositories from the project registry, or ask the user for project roots):

For each project directory:
```bash
# Commits today
git log --oneline --since="00:00" --author="$(git config user.email)" 2>/dev/null
# Current branch
git branch --show-current 2>/dev/null
# Uncommitted changes
git status -s 2>/dev/null
# Open PRs
gh pr list --state open --author @me 2>/dev/null
```

Only include projects with activity today (commits, changes, or open PRs).

Also gather from Cortex:
- Read `~/.claude/cortex/projects/*/observations.jsonl` — count today's entries
- Read instincts created/updated today (check file modification timestamps)

### Step 2: Generate Summary

Format:

```markdown
# EOD — YYYY-MM-DD

## Project: [name]
Branch: [current branch]

### What was done
- [Summary of commits/changes today]

### Pending
- [Uncommitted files]
- [Open PRs]
- [TODOs found in modified files]

### For tomorrow
- [Next steps, priority items]

---

## Cortex Learning
- New instincts: [count]
- Updated instincts: [count]
- Observations today: [count]
- Promotions pending: [yes/no]

## Notes
- [Any important context to carry over]

## Quick Resume
> "Yesterday I worked on [projects]. In [project1] I was on branch [branch]
> doing [what]. Priority for today: [what to do first]."
```

### Step 3: Save to Disk

Write to `~/.claude/cortex/daily-summaries/YYYY-MM-DD.md`.
Create directory if it does not exist.

### Step 4: Mini-Learn

Check if there are 10+ new observations since the last `/cx-learn` run.
Determine last learn time from `.learn-pending` marker or project registry `last_learned` field.

If 10+ new observations exist and `--quick` was NOT passed:
1. Run a lightweight version of the analyze step from `/cx-learn`
2. Only create new instincts (skip evolve, distill, promote)
3. Show any new instincts detected

If fewer than 10 new observations: skip silently.

### Step 5: Display Summary

Show compact visual format:

```
================================================================
  EOD — YYYY-MM-DD
================================================================

  PROJECTS ACTIVE: N
  ----------------------------------------

  [project-name] (branch: feature/xyz)
    Commits: 5 | Files changed: 12
    Pending: 3 uncommitted files
    PR: #15 "Add auth flow" — checks passing
    Tomorrow: finish API tests, deploy to staging

  [project-name-2] (branch: main)
    Commits: 0 | No pending changes
    Tomorrow: no action needed

  ----------------------------------------
  CORTEX: +3 observations | +1 instinct today
  ----------------------------------------

  Saved: ~/.claude/cortex/daily-summaries/YYYY-MM-DD.md

================================================================
```

## Edge cases

- **No activity today**: display "No activity detected in any project today."
- **Single project**: skip multi-project layout, show only that project
- **No git in directory**: skip silently
- **No gh CLI**: show warning but continue without PR/issue data
- **--yesterday**: read the most recent file in `~/.claude/cortex/daily-summaries/` and display it

## Resuming next day

At the start of a new session, the user can say:

```
Read ~/.claude/cortex/daily-summaries/YYYY-MM-DD.md and resume where I left off
```

Or: `/cx-eod --yesterday`

## What NOT to do

- Do not invent activity that did not happen — use git data only
- Do not run a full /cx-learn — only the mini-learn subset
- Do not delete or modify any project files
