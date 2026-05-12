---
name: cx-analyze
description: Analyze observations to detect patterns and propose instincts
command: true
---

# /cx-analyze

## What it does

Reads ALL observations for the current project (or all projects with --global), pre-processes them for context efficiency, then detects patterns using a single Opus 1M agent with full cross-project visibility. Writes proposals to `~/.claude/cortex/proposals.json`.

## Usage

```
/cx-analyze              # Current project (observations only)
/cx-analyze --deep       # Include observations.archive/*.jsonl (slower, more historical)
/cx-analyze --git        # Also mine git history for patterns
/cx-analyze --global     # All projects
/cx-analyze --accept     # Auto-accept all proposals as instincts
/cx-analyze --dry-run    # Show what would be proposed without writing
```

## Implementation

### Step 0: Preflight — MUST run on Opus 1M

This command analyzes up to 3 MB of compressed observations in a single context
window. Sonnet 4.x (200K) and Haiku (200K) cannot fit the full payload and will
either silently sample, fail mid-analysis, or spawn a sub-Agent which defeats
the purpose of inline cross-project visibility.

**Before doing ANYTHING else, check the model declaration in the system prompt:**

- The system prompt contains a line like:
  `You are powered by the model named <NAME>. The exact model ID is <ID>.`
- The model ID MUST be `claude-opus-4-7` (or newer Opus) AND the active session
  MUST have the 1M context flag (the user toggles this via `/model claude-opus-4-7[1m]`
  or the runtime status line displays `[1m]`).

**If the active model is NOT Opus with 1M context, STOP IMMEDIATELY and reply:**

```
/cx-analyze requiere Opus 1M (claude-opus-4-7[1m] o superior).
Modelo actual: <model_name> — no tiene contexto suficiente para el análisis completo.

Cambia con:  /model claude-opus-4-7[1m]
Luego vuelve a ejecutar:  /cx-analyze
```

Do NOT proceed to Step 1. Do NOT compress observations. Do NOT spawn a sub-Agent
as a workaround — this command is designed for direct inline analysis on Opus 1M.

If unsure whether 1M is active, ask the user to confirm: "¿Confirmas que estás
en Opus 1M? Tu line/status debería mostrar `[1m]`." Wait for confirmation before
proceeding.

### Step 1: Detect Context

- Identify current project via git remote hash
- Look up in `~/.claude/cortex/projects/registry.json`
- Count observations in project's `observations.jsonl`
- Count existing instincts (project + global)

Display:
```
CORTEX ANALYZE — Context
  Project: [name] ([hash])
  Observations: N
  Instincts: N project + N global
```

### Step 2: Validate

- If < 10 observations AND --git not passed: inform and exit
  "Only N observations found. Need at least 10 for meaningful analysis. Try /cx-analyze --git to mine git history instead."
- If --global: iterate all projects in registry.json

### Step 2b: Mine Git History (--git flag)

If --git is passed, also analyze the project's git history as supplementary data:

```bash
# Recent commits (last 200)
git log --oneline -200

# Most frequently changed files
git log --pretty=format: --name-only -200 | sort | uniq -c | sort -rn | head -20

# Fix/hotfix patterns (error-resolution signal)
git log --oneline -200 --grep="fix" --grep="hotfix" --grep="patch" --grep="bug"

# Files that change together (coupling)
git log --pretty=format: --name-only -200 | awk '/^$/{if(NR>1)print "---";next}{print}' | head -100

# Tech stack detection
# Read package.json, Cargo.toml, requirements.txt, etc.
```

From git data, detect:
- **Hotspot files**: files changed 5+ times → instinct about careful testing before editing
- **Fix patterns**: repeated "fix:" commits on same area → gotcha instinct candidate
- **File coupling**: files that always change together → workflow instinct
- **Tech stack**: frameworks and dependencies → domain-specific instincts
- **Commit conventions**: detect if conventional commits are used

Git-derived proposals get source: "git-history" and initial confidence 0.30-0.50 (lower than observation-derived since we're inferring, not observing directly).

### Step 3: Pre-process Observations

Observations JSONL files can be very large (up to 10MB). Most of the weight comes from tool output (full file contents from Read, command output from Bash) which is not needed for pattern detection. Pre-process to reduce size while preserving ALL signal.

**`--deep` flag**: if `--deep` is passed, before running the compressor:
1. Locate `observations.archive/` directory in current project (path: `~/.claude/cortex/projects/<hash>/observations.archive/`).
2. List all `.jsonl` files inside, sorted chronologically by filename.
3. Concatenate them with the active `observations.jsonl` for processing (archives first in chronological order, active last).
4. Compute total size in MB across all files. If >5MB, print warning: "Deep mode: analyzing N archived files (X MB total) + active. This may use significant Opus tokens."
5. Inform user: "Deep mode: analyzing N archived files (X MB total) + active observations".

Without `--deep`, only the active `observations.jsonl` is processed (current behavior unchanged).

Run a Python script to create a compressed JSONL file.

The real JSONL schema written by `observe.py` is:
- `ts` — timestamp (not `timestamp`)
- `ev` — event type: `"ts"` (tool start) or `"tc"` (tool complete)
- `tool` — tool name
- `err` — boolean error flag (not `status`)
- `input` — serialized JSON string containing `command`, `file_path`, `description`, etc. (not `args` object)
- `output` — present only on `tc` events, contains tool result

```python
import json, sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    obs = json.loads(line)
    ev = obs.get('ev', '')
    out = {
        'ts': obs.get('ts', '')[:16],
        'ev': ev,
        'tool': obs.get('tool', ''),
        'err': obs.get('err', False),
        'sid': obs.get('sid', '')[:8],
        'pname': obs.get('pname', ''),
    }

    if ev == 'ts':
        raw_input = obs.get('input', '')
        if raw_input:
            try:
                inp = json.loads(raw_input)
                for key in ('command', 'file_path', 'pattern', 'description', 'query', 'url'):
                    if key in inp:
                        out[key] = str(inp[key])[:200]
            except Exception:
                out['input_raw'] = str(raw_input)[:200]

    elif ev == 'tc' and obs.get('err'):
        raw_output = obs.get('output', '')
        if raw_output:
            out['output'] = str(raw_output)[:300]

    print(json.dumps(out))
```

This typically reduces 10MB → 0.5-1MB without losing any error messages, tool sequences, or file paths. The agent sees WHAT was done (tool + key args) and WHETHER it failed (`err`), but not full output content.

Write the compressed file to a temporary location within the project directory.

**Context budget**: Opus 1M can handle ~3-3.5MB of JSONL in a single context. If the compressed file exceeds 3MB, sample up to 250 most recent observations per project, prioritizing recent activity.

### Step 3b: Analyze with Opus 1M Agent

Generate a knowledge summary file with ALL existing knowledge to avoid duplicates:
- **Laws**: read all `~/.claude/cortex/laws/*.txt` — one line each
- **Global instincts**: read all `~/.claude/cortex/instincts/global/*.yaml` — extract id + trigger + action per file
- **Project instincts**: read all `~/.claude/cortex/projects/*/instincts/*.yaml` — extract id + trigger + action per file
- **Reflexes**: read `~/.claude/cortex/reflexes.json` — extract matcher + action per reflex

Format as a compact text file:
```
=== EXISTING KNOWLEDGE (DO NOT DUPLICATE) ===
LAWS:
- Use conventional commits: feat/fix/chore/docs/refactor/test...
- Always read before editing any file...
INSTINCTS (global):
- [global] gotcha-rls-silent-fail | Edit|supabase | RLS policies fail silently...
- [global] gotcha-gh-cli-path | Bash|gh | gh not in default PATH...
INSTINCTS (project):
- [87efd285c5fd] linkedin-oauth-scope | Edit|oauth | OAuth scope alignment...
REFLEXES:
- read-before-edit | Edit/Write → Verify file was Read first
```

Launch a SINGLE Opus 1M agent (`model: opus`) with:
1. The compressed observations file (ALL projects in one file for cross-project visibility)
2. The knowledge summary file (laws + instincts + reflexes) to avoid duplicates
3. The analysis prompt (see below)

**Why one agent, not many**: A single agent with full visibility detects cross-project patterns (e.g., "this error happens in 4 projects") that isolated per-project agents cannot see. Opus 1M has enough context for ~3MB of observations.

**Agent prompt must instruct**:
- Focus on NON-OBVIOUS patterns — not generic sequences like "Read before Edit"
- Prioritize: error→fix pairs, gotchas with silent failures, user corrections, cross-project patterns
- Do NOT propose patterns already covered by existing instincts
- Include evidence: how many times seen, which projects, what the actual error was
- Maximum 15 proposals, quality over quantity
- Output YAML instinct blocks with: id, trigger, action, confidence, domain, scope, projects_seen, tags
- **YAML quoting rule**: wrap `trigger`, `condition`, `matcher` and `action` in **single quotes** (`'...'`), NOT double quotes. Regex escapes like `\.`, `\s`, `\(` break double-quoted YAML strings but are literal in single-quoted strings. If the value itself contains `'`, use a block scalar `|-`.

### Step 3c: Translate agent output → proposals.json format

For each YAML instinct returned by the agent, create a JSON proposal:
- Include ALL agent fields
- Add: `detected` (today), `project_id`, `project_name`, `status: "pending"`, `source: "cx-analyze"`
- For cross-project patterns: set `project_id: "global"`, `project_name: "cross-project"`

Example:
```
# Agent returns (single quotes for regex-like fields):
id: gotcha-husky-hook-not-executable
trigger: 'Write|\.husky/'
action: 'After writing .husky/* files, run chmod +x — hooks fail silently'
confidence: 0.50
scope: global
projects_seen: ['claude-testing-kit', 'storyweaver', 'LinkedIn']

# cx-analyze writes:
{
  "id": "gotcha-husky-hook-not-executable",
  "trigger": "Write|.husky/",
  "action": "After writing .husky/* files, run chmod +x — hooks fail silently",
  "confidence": 0.50,
  "domain": "gotcha",
  "scope": "global",
  "source": "cx-analyze",
  "detected": "2026-04-08",
  "project_id": "global",
  "project_name": "cross-project",
  "projects_seen": ["claude-testing-kit", "storyweaver", "LinkedIn"],
  "status": "pending"
}
```

For each converted proposal:
- Check for existing instinct with similar trigger (Jaccard >= 0.50)
- If matches existing: note as "update candidate" (bump confidence)
- If new: add to proposals

Clean up the temporary compressed file after analysis.

### Step 4: Write Proposals

Write to `~/.claude/cortex/proposals.json`:
```json
[
  {
    "id": "proposal-id",
    "trigger": "regex pattern",
    "action": "what to do",
    "confidence": 0.35,
    "domain": "domain",
    "source": "cx-analyze",
    "detected": "2026-04-04",
    "project_id": "hash",
    "project_name": "name",
    "status": "pending"
  }
]
```

Deduplicate by id (keep most recent).

### Step 5: Summary

Display each proposal with its confidence emoji, score, id, scope, AND a short description (~60 chars) summarizing the instinct action. Format:

```
CORTEX ANALYZE — Results
  Observations analyzed: N
  New proposals: N
  Update candidates: N (existing instincts to bump)

  Proposals:
  🔴 0.88  gotcha-ssh-hardening-last (vps) — SSH hardening debe ser ultimo en Phase 1
  🟡 0.55  workflow-read-before-edit (global) — Always read file before editing
  🟢 0.35  tool-pref-glob-over-find (project) — Prefer Glob tool instead of find command

  Review proposals with /cx-validate
  Or accept all with /cx-analyze --accept
```

Each line MUST include `— short description` after the scope. The description is derived from the proposal's `action` field, truncated to ~60 chars if needed. This gives the user immediate context without having to open each proposal.

**CONFIRMAR ANTES DE EJECUTAR**: After presenting results, STOP. NEVER chain opinion or execution in the same turn. Wait for the user to decide what to do next (`/cx-validate`, `--accept`, or dismiss). The summary is informational only.

### Step 6: Cleanup state flags

After displaying the summary, clean up the trigger files so session-start
does not fire the learn-pending reminder again until new observations accumulate:

```bash
# Remove the .learn-pending flag (takes priority over count-based check)
rm -f ~/.claude/cortex/.learn-pending

# Update the observation count baseline so the count-based check
# won't re-trigger until 50+ NEW observations accumulate
python3 - <<'EOF'
import json
from pathlib import Path

PROJECTS_DIR = Path.home() / '.claude' / 'cortex' / 'projects'
total = 0
for obs_file in PROJECTS_DIR.glob('*/observations.jsonl'):
    try:
        with open(obs_file) as f:
            total += sum(1 for _ in f)
    except Exception:
        pass
(Path.home() / '.claude' / 'cortex' / '.last-learn-count').write_text(str(total))
EOF
```

This ensures the next session-start sees a clean baseline and only re-triggers
when ≥50 genuinely new observations have been recorded since this run.

### --accept flag

If --accept is passed, skip proposals and directly:
1. Create instinct YAML files from proposals
2. Write to the appropriate path based on scope:
   - Global scope → `~/.claude/cortex/instincts/global/{id}.yaml`
   - Project scope → `~/.claude/cortex/projects/{hash}/instincts/{id}.yaml`
3. Clear accepted proposals from proposals.json

## What NOT to do

- Do not run automatically — only when user invokes /cx-analyze
- Do not delete observations after analysis
- Do not overwrite existing instincts without user review
