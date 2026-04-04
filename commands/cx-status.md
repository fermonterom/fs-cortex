---
name: cx-status
description: Unified Cortex dashboard — laws, instincts, projects, reflexes, system health
command: true
---

# /cx-status

## What it does

Unified dashboard showing the complete state of the Cortex learning system. Replaces the need for separate status, audit, projects, and watchdog commands.

## Implementation

### Step 1: Laws (Level 3 — always active)

Read all files from `~/.claude/cortex/laws/*.txt`.

Display each law (one-liner per file). Show count and estimated total tokens.

```
LAWS (Level 3 — always loaded):
  1. [law-id] — "One-liner content"
  2. [law-id] — "One-liner content"
  Total: N laws | ~T tokens
```

### Step 2: Instincts (Level 2 — on demand)

Scan both locations:
- Global: `~/.claude/cortex/instincts/global/*.yaml`
- Project: `~/.claude/cortex/projects/<hash>/instincts/*.yaml`

Detect current project via git remote hash or cwd.

Group by confidence tier and display:

```
INSTINCTS:

  Project: [name] ([hash])
  ----------------------------------------
  LAWS (0.9-1.0):
    [id]                    [domain]      [confidence]   [last_seen]

  INSTINCTS (0.7-0.9):
    [id]                    [domain]      [confidence]   [last_seen]

  PATTERNS (0.5-0.7):
    [id]                    [domain]      [confidence]   [last_seen]

  HYPOTHESES (0.3-0.5):
    [id]                    [domain]      [confidence]   [last_seen]

  OBSERVATIONS (0.0-0.3):
    [id]                    [domain]      [confidence]   [last_seen]

  Global:
  ----------------------------------------
  [same grouping]
```

### Step 3: Projects

Read `~/.claude/cortex/projects/registry.json`.

Display table:

```
PROJECTS:
  NAME                ROOT                           LAST SEEN     OBS   INST
  my-saas             ~/github/my-saas               2026-03-27    142   8
  landing-page        ~/github/landing               2026-03-25    53    3
```

### Step 4: Reflexes

Read `~/.claude/cortex/reflexes.json`.

Display:

```
REFLEXES:
  ID                        MATCHER              SEVERITY    FIRES  LAST FIRED
  reflex-no-env-commit      *.env*               critical    12     2 days ago
  reflex-test-before-push   pre-push             high        47     today
```

### Step 5: System Health

Check each indicator:

```
SYSTEM HEALTH:
  Hooks active:          [yes/no] (check ~/.claude/settings.json)
  Last observation:      [timestamp or "never"]
  Disk usage:            [size of ~/.claude/cortex/]
  .learn-pending:        [yes/no — run /cx-analyze if yes]
  memory.json:           [populated/empty/missing]
```

### Step 6: Evolved Content

Count files in each evolved directory:

```
EVOLVED:
  Skills:    N files in ~/.claude/cortex/evolved/skills/
  Commands:  N files in ~/.claude/cortex/evolved/commands/
  Rules:     N files in ~/.claude/cortex/evolved/rules/
```

## Output format

Use clean ASCII box format:

```
================================================================
  CORTEX STATUS
  Date: YYYY-MM-DD HH:MM
================================================================

  [Section 1: Laws]
  [Section 2: Instincts]
  [Section 3: Projects]
  [Section 4: Reflexes]
  [Section 5: System Health]
  [Section 6: Evolved]

================================================================
  Total: N laws | N instincts (N project + N global) | N projects
================================================================
```

## What NOT to do

- Do not invent data that does not exist in the files
- Do not modify any files — this is a read-only command
- Do not show raw observations, only processed instincts
- If a directory or file does not exist, show "not found" for that section, do not error out
