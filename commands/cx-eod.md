---
name: cx-eod
description: End-of-day summary — saves context for tomorrow
command: true
---

# /cx-eod

## What it does

Generates an end-of-day summary and saves context for the next session. Runs a
deterministic multi-project gather (no LLM) over the last 24 hours. Safe to run
multiple times a day: each run **regenerates** the day's file from fresh data and
records a trace of when it ran.

Two paths:
- **Interactive (`/cx-eod`)** — Claude composes the summary with judgment
  (prioritized "For tomorrow", prose "Quick Resume") from the gather JSON.
- **`--auto` (cron)** — the gather script composes and writes the summary
  **deterministically itself** (`--write`), with **no model call**. This is what
  a scheduler runs, so it costs **zero model quota** and needs no `claude -p`.

## Usage

```
/cx-eod              # Full interactive summary (Claude composes with judgment)
/cx-eod --auto       # Deterministic, no LLM — delegates to the gather --write mode
/cx-eod --yesterday  # Show the most recent saved summary
```

### Cron / scheduled use — call the script directly, NOT `claude -p`

Because `--auto` is fully deterministic, automate it by calling the script
**directly** — do not spend model quota launching a headless `claude`:

```cron
0 15,19,22 * * * bash ~/.claude/cortex/core/_cx-eod-gather.sh --write >> ~/.claude/cortex/log/cx-eod-cron.log 2>&1
```

`hooks/session-start.py` reinjects the resulting summary next session.

## Implementation

### --auto path (deterministic — what cron uses)

Run `bash ~/.claude/cortex/core/_cx-eod-gather.sh --write`. The script composes
the markdown, merges the `## Ejecuciones hoy` trace, and writes
`~/.claude/cortex/daily-summaries/<date>.md` — no model involvement. Report the
one-line confirmation it prints. Stop here; the steps below are for the
interactive path only.

### Step 1: Gather Context (interactive — deterministic, no LLM)

Run the gather script and parse its JSON. It scans ALL registered projects, not
just the current one:

```bash
bash ~/.claude/cortex/core/_cx-eod-gather.sh
```

The script reads `~/.claude/cortex/projects/registry.json` plus each
`projects/<hash>/observations.jsonl` and the root `observations.jsonl`
(non-git "global" projects), filters to the **last 24 hours**, runs git per
project root, and outputs:

```json
{
  "date": "YYYY-MM-DD",
  "project_count": 3,
  "total_observations": 142,
  "projects": [
    {
      "name": "fs-cortex",
      "root": "/Users/fmm/github/fs-cortex",
      "observations_today": 25,
      "tools_used": ["Edit", "Bash", "Read"],
      "files_touched": ["install.sh", "cx-eod.md"],
      "errors_today": 0,
      "git": {
        "branch": "main",
        "commits_today": 2,
        "commits_log": "abc123 fix: ...\ndef456 feat: ...",
        "uncommitted_files": 1,
        "status": " M install.sh"
      }
    }
  ]
}
```

`git` is `null` for projects whose root is not present on this machine (foreign
roots from a shared observations file). Compose the summary from this JSON.

**Why a 24h rolling window** (not `--since="00:00"`): captures the full work
session regardless of when EOD runs (15:00, 22:00, or 02:00 after midnight),
avoiding UTC/local mismatch. The `date` field is the LOCAL day, matching how
`hooks/session-start.py` looks up the file to reinject next session.

**Fallback (legacy mode)**: if the script is missing, errors, or returns
`project_count: 0`, scan the current project directory only:

```bash
AUTHOR=$(git config user.email 2>/dev/null)
if [ -n "$AUTHOR" ]; then
  git log --oneline --since="24 hours ago" --author="$AUTHOR"
else
  git log --oneline --since="24 hours ago"
fi
git branch --show-current 2>/dev/null
git status -s 2>/dev/null
```

Also gather Cortex learning state (file mtimes in the last 24h):
- New/updated instincts under `~/.claude/cortex/instincts/`
- Promotions pending (check `/cx-distill` candidates if cheap)

### Step 2: Generate Summary

Compose in this format. `{HH:MM}` is the current local time from `date +%H:%M`.

```markdown
# EOD — {YYYY-MM-DD}

## Ejecuciones hoy
- {HH:MM} — {project_count} proyectos, {total_observations} observaciones

## Projects Worked Today: {project_count}

### {project-name}
Branch: {git.branch}
Observations: {observations_today} | Errors: {errors_today}

**What was done**
- {Summary of commits (git.commits_log), grouped by theme}
- {Files touched: files_touched}

**Pending**
- {git.uncommitted_files uncommitted files}

---

(repeat per project)

---

## Cross-Project Summary

### For tomorrow
- {Priority 1 — from uncommitted files, open PRs, recent patterns}
- {Priority 2}

### Cortex Learning
- New instincts: {count}
- Updated instincts: {count}
- Observations today: {total_observations}
- Promotions pending: {yes/no}

### Notes
- {Any important context to carry over}

## Quick Resume
> "Yesterday I worked on {projects}. In {project1} I was on branch {branch}
> doing {what}. Priority for today: {what to do first}."
```

### Step 3: Save to Disk — idempotent intraday regeneration

Write to `~/.claude/cortex/daily-summaries/{date}.md` (create the dir if needed).

**Intraday rule — REGENERATE, do not append.** Because the gather looks back 24h,
each run already includes everything from earlier today. So:

1. If `{date}.md` already exists, read its `## Ejecuciones hoy` block and keep
   every prior `- {HH:MM} — …` line.
2. Append one new line for THIS run (`date +%H:%M` + current counts).
3. Rewrite the WHOLE file with the merged `## Ejecuciones hoy` block at top and
   freshly composed sections below. This avoids duplicating project content while
   leaving a visible trace that EOD ran at 15:02 / 19:01 / 22:03.

Example trace after three cron runs:

```markdown
## Ejecuciones hoy
- 15:02 — 4 proyectos, 88 observaciones
- 19:01 — 5 proyectos, 201 observaciones
- 22:03 — 5 proyectos, 269 observaciones
```

### Step 3b: Overwrite behavior

- `--auto` flag OR non-TTY (cron): regenerate silently, never prompt.
- Interactive with an existing file: regeneration is the default and expected
  behavior, so do NOT ask "overwrite?" — just regenerate and report that the
  trace now has N entries.

### Step 4: Display Summary

Show a compact visual format:

```
================================================================
  EOD — {YYYY-MM-DD}   (run #{N} today at {HH:MM})
================================================================

  PROJECTS ACTIVE: {project_count}
  ----------------------------------------

  {project-name} (branch: {branch})
    Commits: {commits_today} | Files: {files_touched count}
    Pending: {uncommitted_files} uncommitted
    Tomorrow: {next step}

  ----------------------------------------
  CORTEX: +{total_observations} observations | +{N} instincts today
  ----------------------------------------

  Saved: ~/.claude/cortex/daily-summaries/{date}.md

================================================================
```

In `--auto` mode keep output terse (one or two lines): file path + run count.

## Edge cases

- **No activity today**: display "No activity detected in any project today." and
  still write the file with the execution trace (so cron leaves a record).
- **Single project**: skip multi-project layout, show only that project.
- **No git in directory / foreign root**: `git` is `null` — show observation data
  only, skip git fields.
- **No gh CLI**: skip PR data silently.
- **--yesterday**: read the most recent file in `~/.claude/cortex/daily-summaries/`
  (`ls -t …/*.md | head -1`) and display it.

## Resuming next day

`hooks/session-start.py` reads today's (or yesterday's) summary at session start
and injects the Quick Resume + "For tomorrow" priorities automatically. Or run
`/cx-eod --yesterday`.

## What NOT to do

- Do not invent activity that did not happen — use gather/git data only.
- Do not delete or modify any project files.
- Do not limit EOD to the current project — the gather scans ALL registered projects.
- Do not use `--since="00:00"` or date-based filters — always 24h rolling.
- Do not append duplicate project sections on re-runs — REGENERATE; only the
  `## Ejecuciones hoy` trace accumulates.
- Do not include secrets (env vars, tokens, passwords) in the summary.
