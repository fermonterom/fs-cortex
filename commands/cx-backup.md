---
name: cx-backup
description: Create portable backup of Cortex knowledge for machine transfer or safekeeping
command: true
---

# /cx-backup

## What it does

Creates a portable `.tar.gz` archive of all valuable Cortex knowledge data. Use this to transfer your learned patterns to a new machine, create a safekeeping copy, or before uninstalling.

## Usage

```
/cx-backup              # Create backup in current directory
/cx-backup ~/Desktop    # Create backup in specific directory
```

## Implementation

### Step 1: Inventory

Count and display what will be backed up:

```
CORTEX BACKUP — Inventory
  Laws:            N files
  Instincts:       N global + N project-specific
  Projects:        N registered
  Reflexes:        N rules
  Daily summaries: N files
  Evolved content: N skills + N commands + N agents
  Memory:          identity + config
```

### Step 2: Create Archive

Gather these paths (relative to `~/.claude/cortex/`):

**INCLUDE (valuable knowledge):**
- `laws/*.txt` — Crystallized wisdom
- `laws/archive/*.txt` — Archived laws
- `instincts/personal/*.yaml` — Global instincts
- `instincts/inherited/*.yaml` — Inherited instincts
- `projects/registry.json` — Project registry
- `projects/*/instincts/personal/*.yaml` — Project-specific instincts
- `projects/*/instincts/inherited/*.yaml` — Project inherited instincts
- `memory.json` — Identity and config
- `reflexes.json` — Custom reflexes
- `evolved/**` — Generated skills, commands, agents
- `daily-summaries/*.md` — EOD summaries
- `exports/*.md` and `exports/*.json` — Previous exports

**EXCLUDE (ephemeral/large):**
- `projects/*/observations.jsonl` — Raw data, too large (can be 10MB+ per project)
- `projects/*/observations.archive/` — Archived observations
- `.obs-count`, `.learn-pending`, `.last-session-date`, `.last-learn-count` — Ephemeral markers
- `catalog.json` — Template data, recreated on install

### Step 3: Build Archive

Use `tar` to create the archive:

```bash
tar -czf cortex-backup-YYYY-MM-DD.tar.gz -C ~/.claude/cortex \
  laws/ \
  instincts/ \
  projects/registry.json \
  projects/*/instincts/ \
  memory.json \
  reflexes.json \
  evolved/ \
  daily-summaries/ \
  exports/
```

Output path: `[target_dir]/cortex-backup-YYYY-MM-DD.tar.gz`

If the file already exists, append a sequence number: `cortex-backup-YYYY-MM-DD-2.tar.gz`

### Step 4: Verify and Display

Verify the archive is valid:

```bash
tar -tzf cortex-backup-YYYY-MM-DD.tar.gz | wc -l
```

Display summary:

```
================================================================
  CORTEX BACKUP — Complete
================================================================

  Archive:     cortex-backup-YYYY-MM-DD.tar.gz
  Size:        X.X MB
  Files:       N files
  Location:    /path/to/archive

  Contents:
    Laws:       N
    Instincts:  N (N global + N project)
    Projects:   N
    Summaries:  N
    Evolved:    N

  To restore on another machine:
    1. Install Cortex: bash install.sh
    2. Run /cx-restore /path/to/cortex-backup-YYYY-MM-DD.tar.gz

================================================================
```

## What NOT to do

- Do not include raw observations (too large, not portable knowledge)
- Do not modify any existing files — this is a read-only command
- Do not create the archive if there is no data to back up
