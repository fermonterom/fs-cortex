---
name: cx-dream
description: Run Dream Cycle — dedup, contradictions, staleness, regex, health, cleanup
command: true
---

# /cx-dream

## What it does

Knowledge maintenance cycle that runs 6 modules in sequence:
1. **Jaccard dedup** — removes duplicate instincts (threshold 0.80)
2. **Contradiction detection** — finds conflicting instincts in the same domain
3. **Staleness scoring + auto-archive** — decays confidence, archives stale instincts (score >= 90)
4. **Regex validation** — checks all instinct triggers for safety (ReDoS, length, syntax)
5. **Health score** — calculates overall knowledge health 0-100
6. **Cleanup** — detects orphan projects, expired context.md, old observation archives

## Usage

```
/cx-dream              # Full dream cycle
/cx-dream --dry-run    # Show what would change without writing
```

## Implementation

### Step 1: Load All Instincts

Read all instinct YAML files from:
- `~/.claude/cortex/instincts/global/*.yaml`
- `~/.claude/cortex/projects/*/instincts/*.yaml`

Parse each into a dict with: id, trigger, action, confidence, domain, last_seen, created.

### Step 2: Run Dream Cycle Modules

Use the Python module at `hooks/lib/dream_cycle.py`:

```python
import sys
sys.path.insert(0, os.path.expanduser("~/.claude/hooks/cortex/lib"))
from dream_cycle import (
    dedup_instincts,
    detect_contradictions,
    apply_staleness_decay,
    validate_trigger_regex,
    calculate_health_score,
    detect_orphan_projects,
    cleanup_expired_context,
    consolidate_old_archives,
    cleanup_corrupted_context_files,  # v3.31.0
)
```

Execute in order:

1. **Dedup**: `dedup_instincts(all_instincts, threshold=0.80)`
   - Report removed duplicates with their Jaccard similarity scores
   - Keep the instinct with higher confidence

2. **Contradictions**: `detect_contradictions(all_instincts)`
   - Report contradiction pairs with their IDs and conflicting keywords
   - Ask user which to keep/remove/modify

3. **Staleness**: `apply_staleness_decay(all_instincts, archive_threshold=90)`
   - Report decayed instincts with old → new confidence
   - Move archived instincts to `~/.claude/cortex/instincts/archive/`

4. **Regex validation**: `validate_trigger_regex(trigger)` for each instinct
   - Report invalid triggers and ask user to fix or remove

5. **Health score**: `calculate_health_score(stats)`
   - Display score with breakdown
   - **Maintenance bonus/penalty** (from `~/.claude/cortex/log/timeline.jsonl`): +5 if cx-dream or cx-distill run in last 14 days, -5 if no maintenance command run in 30 days. Skip if timeline.jsonl missing.

### Step 3: Apply Changes

If not `--dry-run`:
- Delete duplicate YAML files (keep the winner)
- Update confidence values in YAML frontmatter for decayed instincts
- Move archived instincts to archive directory
- Update `~/.claude/cortex/.last-dream` timestamp

### Step 3b: Log to Knowledge Timeline

After applying changes in Step 3, append one line per action to `~/.claude/cortex/knowledge-log.md`:

For each deduplicated instinct (the removed one):
```bash
echo "$(date +%Y-%m-%d) | deduped | {removed_id} | merged-with:{kept_id} | cx-dream" >> ~/.claude/cortex/knowledge-log.md
```

For each decayed instinct:
```bash
echo "$(date +%Y-%m-%d) | decayed | {id} | {old_conf}→{new_conf} | cx-dream" >> ~/.claude/cortex/knowledge-log.md
```

For each archived instinct:
```bash
echo "$(date +%Y-%m-%d) | archived | {id} | {final_conf} | cx-dream" >> ~/.claude/cortex/knowledge-log.md
```

### Step 3c: Cleanup (Module 6)

Run the 3 cleanup functions against `~/.claude/cortex/`:

```python
CORTEX_DIR = os.path.expanduser("~/.claude/cortex")

orphans = detect_orphan_projects(CORTEX_DIR)
expired = cleanup_expired_context(CORTEX_DIR, ttl_days=14)
old_archives = consolidate_old_archives(CORTEX_DIR, days=90)
legacy_contexts = cleanup_corrupted_context_files(os.path.join(CORTEX_DIR, "projects"))  # v3.31.0
```

**Display results:**

```
=== Cleanup ===

Orphan projects: 2
  - 21c71e44e035 (fs-vps-playbook) — dead_entry: Registry entry but directory missing
  - a1b2c3d4e5f6 (unknown) — orphan_dir: Directory exists but not in registry

Expired context.md: 3
  - 0846920a5e13 — 23 days old
  - b34a69eb49b4 — 18 days old

Old archives (>90d): 1
  - f1a2b3c4d5e6 — 4 files, 12.3 MB
```

**If not `--dry-run`, ask confirmation then apply:**

- **dead_entry**: Remove entry from `registry.json` (atomic write)
- **orphan_dir**: Remove directory from `projects/` (after user confirms)
- **stale_project**: Offer to archive project instincts and remove observations
- **expired context.md**: Delete the file
- **old archives**: Delete archive files older than 90 days

**Log to knowledge-log.md:**

```bash
echo "$(date +%Y-%m-%d) | orphan-removed | {id} | {type}:{name} | cx-dream" >> ~/.claude/cortex/knowledge-log.md
echo "$(date +%Y-%m-%d) | context-cleaned | {project_id} | {age_days}d-expired | cx-dream" >> ~/.claude/cortex/knowledge-log.md
echo "$(date +%Y-%m-%d) | archive-purged | {project_id} | {file_count}-files-{mb}MB | cx-dream" >> ~/.claude/cortex/knowledge-log.md
```

### Step 3d: Archive proposals.json backups (v3.31.2 §4.1.C)

Invoke the weekly archive of `proposals.json.bak*` files left in
`~/.claude/cortex/`. The helper is cooldown-gated via the
`.last-proposals-archive` marker (7-day default) so calling it on every
`/cx-dream` is safe — it no-ops when the cooldown is active or when the
shell script is not reachable in the installed setup.

```python
from dream_cycle import archive_proposals_backups_if_due

archive_result = archive_proposals_backups_if_due(CORTEX_DIR)
# archive_result keys: invoked, reason, returncode, stdout, marker_touched
```

Display under the Cleanup section:

```
Proposals backups:
  Invoked: True | RC: 0
  3 file(s) archived to archive/proposals-pre-v3.29-20260526-153100.tar.gz
```

If `reason` is `cooldown:Xd-of-7` show `Skipped (cooldown).` instead; if
`script-not-installed`, show `Skipped (script not in this install).`.

### Step 4: Report

Display a summary:

```
=== Dream Cycle Report ===

Duplicates removed: 3
Contradictions found: 1
  - gotcha-always-mock vs gotcha-never-mock (always/never)
Instincts decayed: 5
Instincts archived: 2
Invalid triggers: 0

Cleanup:
  Orphan projects: 2 (1 dead entry, 1 orphan dir)
  Expired context.md: 3 (deleted)
  Old archives purged: 4 files, 12.3 MB

Health Score: 82/100
  Staleness: -4
  Contradictions: -10
  Duplicates: 0
  Laws bonus: +6
  Confidence bonus: +5

Last dream: 2026-04-09
Next recommended: 2026-04-16
```

### Confirmation

Before applying destructive changes (archive, delete), ask the user for confirmation:
- Show each duplicate pair and which will be kept
- Show each contradiction and ask for resolution
- Show each instinct to be archived

Only write changes after user confirms.
