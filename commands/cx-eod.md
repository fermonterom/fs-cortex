---
name: cx-eod
description: End-of-day summary — saves context for tomorrow
command: true
---

# /cx-eod

## What it does

Generates an end-of-day summary and saves context for the next session. Runs a
deterministic multi-project gather (no LLM) over the last 24 hours. Safe to run
multiple times a day: each run **regenerates** the day's file from fresh data
and records a trace of when it ran. Port of Sinapsis' `core/_eod-gather.sh`
(`docs/SPEC-PORT-SINAPSIS.md` §3) — the accumulation is STRUCTURAL: the gather
re-reads ALL of `observations.jsonl` for the local day on every call, so
running it at 15:00, 19:00 and 22:00 each produces a superset, never a diff.

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

`hooks/session-start.py` reinjects the resulting summary next session, and —
new in v4 — classifies yesterday's pending items into an Eisenhower matrix
the first time a NEW day's session starts (see "Resuming next day" below).

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
project root, and outputs (per-project shape matches
`docs/SPEC-PORT-SINAPSIS.md` §3):

```json
{
  "date": "YYYY-MM-DD",
  "project_count": 3,
  "total_observations": 142,
  "projects": [
    {
      "hash": "abc123...",
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
      },
      "context": "## Proyecto: fs-cortex — v4 signal-first rewrite in progress"
    }
  ]
}
```

`git` is `null` for projects whose root is not present on this machine (foreign
roots from a shared observations file). `context` is the first ~300 chars of
that project's `projects/<hash>/context.md` bridge file (same source
`hooks/session-start.py:inject_context_bridge` reinjects at SessionStart);
empty string when the file is missing. Compose the summary from this JSON.

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
- Pending review items — read `~/.claude/cortex/.review-digest.json`
  (written by `/cx-maintain`, consumed by `/cx-review`); if `total_items > 0`
  it means human review is backed up, worth a mention in "For tomorrow".

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
- {Context: context, if non-empty}

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
- Review digest pendiente: {N} item(s) -> /cx-review (only if > 0)

### Notes
- {Any important context to carry over}

## Quick Resume
> "Yesterday I worked on {projects}. In {project1} I was on branch {branch}
> doing {what}. Priority for today: {what to do first}."
```

The `--auto`/`--write` path composes the SAME `## Ejecuciones hoy`,
`### For tomorrow`, `### Cortex Learning` (observations + review-digest line
only — no LLM-derived instinct counts) and `## Quick Resume` sections
deterministically from the gather JSON — no model involvement, see
`core/_cx-eod-gather.sh`'s `composeBody`/`composeTomorrow`/`composeResume`.

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
- **No context.md / expired context.md**: `context` is `""` — omit the
  "Context:" line for that project, do not print an empty bullet.
- **--yesterday**: read the most recent file in `~/.claude/cortex/daily-summaries/`
  (`ls -t …/*.md | head -1`) and display it.

## Resuming next day

`hooks/session-start.py` does TWO independent things with the daily summaries
(v4 — `docs/SPEC-PORT-SINAPSIS.md` §3):

1. **Quick Resume reinjection** (`inject_eod_resume`, unchanged since v3.31.0):
   loads today's summary, or yesterday's if today's does not exist yet, and
   injects the `## Quick Resume` + `### For tomorrow` sections. Gated by
   `.eod-last-read` so the same file is not reshown every SessionStart/compact
   within the same day.
2. **`[eod-eisenhower]` matrix** (new in v4, independent idempotency marker
   `.eod-eisenhower-last-shown`): fires ONLY on the first SessionStart of a
   NEW day when yesterday's summary exists and today's does not yet — i.e.
   exactly the "first session of the day" moment. Classifies yesterday's
   `### For tomorrow` bullets into a compact Q1–Q4 matrix using a deterministic
   keyword heuristic (see `hooks/session-start.py:build_eod_eisenhower`) and
   injects it tagged `[eod-eisenhower]`, capped at 15 lines. This block does
   NOT exist in Sinapsis — it is Cortex-specific, built on top of the ported
   gather.

Or run `/cx-eod --yesterday` manually at any time.

## What NOT to do

- Do not invent activity that did not happen — use gather/git data only.
- Do not delete or modify any project files.
- Do not limit EOD to the current project — the gather scans ALL registered projects.
- Do not use `--since="00:00"` or date-based filters — always 24h rolling.
- Do not append duplicate project sections on re-runs — REGENERATE; only the
  `## Ejecuciones hoy` trace accumulates.
- Do not include secrets (env vars, tokens, passwords) in the summary.
- Do not call `/cx-maintain` or `/cx-review` from inside this command — EOD
  only READS `.review-digest.json` for a one-line mention; generating or
  acting on it is out of scope here.
