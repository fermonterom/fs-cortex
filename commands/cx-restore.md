---
name: cx-restore
description: Restore Cortex knowledge from a backup archive, merging with existing data
command: true
---

# /cx-restore

## What it does

Restores Cortex knowledge from a `.tar.gz` backup archive created by `/cx-backup`. Intelligently merges with any existing data rather than overwriting.

## Usage

```
/cx-restore /path/to/cortex-backup-YYYY-MM-DD.tar.gz
/cx-restore --preview /path/to/backup.tar.gz    # Show what would be imported without doing it
```

## Implementation

### Step 1: Validate Archive

Check the file exists and is a valid tar.gz:

```bash
tar -tzf /path/to/backup.tar.gz > /dev/null 2>&1
```

If invalid, show error and exit.

List contents and display preview:

```
CORTEX RESTORE — Preview
  Archive:     cortex-backup-YYYY-MM-DD.tar.gz
  Laws:        N files
  Instincts:   N files
  Projects:    N entries
  Summaries:   N files
  Evolved:     N files
```

### Step 2: Extract to Temp Directory

```bash
TEMP_DIR=$(mktemp -d)
tar -xzf /path/to/backup.tar.gz -C "$TEMP_DIR"
```

### Step 3: Merge Data

For each category, merge intelligently:

**Laws** (`laws/*.txt`):
- For each law file in backup:
  - If same filename exists locally: keep local (user may have updated it)
  - If new: copy to `~/.claude/cortex/laws/`

**Instincts** (`instincts/global/*.yaml`, `projects/*/instincts/*.yaml`):
- For each instinct in backup:
  - If same filename exists locally: compare confidence scores, keep the higher one
  - If new: copy to appropriate location
  - Handle backward compatibility: if backup uses old `instincts/personal/` path, map to `instincts/global/`; if backup uses `projects/*/instincts/personal/`, map to `projects/*/instincts/`

**Projects** (`projects/registry.json`):
- Merge registries: for each project in backup registry:
  - If same project ID exists locally: keep local entry (more recent)
  - If new: add to local registry
- Create project directory structure for new projects

**Memory** (`memory.json`):
- Merge identity: keep local values if populated, use backup for empty fields
- Merge stats: use MAX of each stat value
- Merge config: keep local config (user may have customized)

**Reflexes** (`reflexes.json`):
- Merge reflexes array: add any reflexes from backup that don't exist locally (match by `id`)
- Keep local versions of existing reflexes

**Evolved content** (`evolved/**`):
- Copy any files that don't exist locally

**Daily summaries** (`daily-summaries/*.md`):
- Copy any summaries that don't exist locally (they're date-stamped, no conflicts)

**Exports** (`exports/*`):
- Copy any files that don't exist locally

### Step 4: Cleanup and Summary

Remove temp directory.

Display:

```
================================================================
  CORTEX RESTORE — Complete
================================================================

  Imported from: cortex-backup-YYYY-MM-DD.tar.gz

  Laws:        +N new, N kept local
  Instincts:   +N new, N merged (higher confidence), N kept local
  Projects:    +N new, N kept local
  Reflexes:    +N new, N kept local
  Summaries:   +N new
  Evolved:     +N new

  Total new items: N

================================================================
```

### Step 5: Update Stats

Update `~/.claude/cortex/memory.json` stats to reflect the current state after merge.

## Edge cases

- **No existing Cortex installation**: inform user to run `bash install.sh` first
- **Empty backup**: show "Backup contains no data" and exit
- **--preview flag**: show what would be imported without writing anything
- **Corrupted YAML in backup**: skip and warn, continue with other files
- **Duplicate instinct IDs with different filenames**: compare confidence, keep higher

## What NOT to do

- Never overwrite existing data without comparing first
- Never delete local data that's not in the backup
- Never modify the backup archive file itself
