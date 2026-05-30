---
name: cx-backfill
description: Recover legacy session fields and rebuild eligible tracking sessions
command: true
---

# /cx-backfill

## What it does

Runs v3.33.0 recovery for historical `session`/`session_id` drift:
- Normalizes `proposals-history.jsonl` entries with `session` but no `session_id`
- Rebuilds `instinct-tracking.json` `sessions[]` for eligible instincts only
- Creates backups before any write at `~/.claude/cortex/archive/backfill-<timestamp>/`

## Usage

```
/cx-backfill            # Dry run (default, no writes)
/cx-backfill --apply    # Backup + apply changes
```

## Implementation

Execute:

```bash
python3 ~/.claude/hooks/cortex/lib/distill_engine.py backfill         # dry-run
python3 ~/.claude/hooks/cortex/lib/distill_engine.py backfill --apply # write
```

Rules:
- Dry-run is the default and must not modify files.
- `--apply` is required to write.
- Backups are created before any write.
- Operation is idempotent.
