---
name: cx-evolve
description: Evolve clusters of mature instincts into skills, commands, rules, or agents
command: true
---

# /cx-evolve

## Auto mode (Sprint 7+)

Most validate/evolve work now runs automatically at SessionStart via
`hooks/lib/distill_engine.py`. The manual command remains for:
- Reviewing the auto-generated drafts at `~/.claude/cortex/evolved/skills/`
- Clusters that were not auto-detected (low Jaccard, cross-domain patterns)
- Installing, merging, or discarding generated draft skills

## What it does

The final step in the learning pipeline. Finds clusters of 3+ mature instincts (confidence >= 0.70) in the same domain, and generates reusable artifacts: skills, commands, or passive rules.

## Usage

```
/cx-evolve               # Scan and propose evolutions
/cx-evolve --dry-run     # Show what would be generated without writing
```

## Implementation

### Step 1: Scan Mature Instincts

Read all instinct YAML files (global + all projects). Filter to confidence >= 0.70.

Group by domain. For each domain with 3+ instincts:
1. Compute pairwise Jaccard similarity on trigger + action tokens
2. Cluster instincts with Jaccard >= 0.50 (related patterns)

### Step 2: Cross-reference with Existing Skills

Before proposing any artifact, check what already exists:

1. List all installed skills: `~/.claude/skills/*/SKILL.md`
2. For each cluster, search for an existing skill whose domain overlaps:
   - Compare cluster domain/keywords against skill name, description, and trigger patterns
   - If a candidate skill is found, read its content and check section-by-section coverage
3. Classify each cluster into one of three outcomes:

| Outcome | Condition | Action |
|---------|-----------|--------|
| **Already covered** | All instincts in the cluster are already present in an existing skill | Discard cluster, report to user |
| **Partially covered** | Some instincts overlap, others are new | Propose MERGE into existing skill |
| **Not covered** | No existing skill covers this domain | Propose new artifact (skill/command/rule) |

### Step 3: Propose Artifacts (Shorthand Input)

For each cluster, determine the best artifact type:

| Pattern | Artifact | Example |
|---------|----------|---------|
| All about same technology/API | Skill (.md) | fs-supabase-rls.md |
| All about same workflow step | Command (.md) | fs-pre-deploy-check.md |
| All simple guard rules | Passive Rule (reflexes.json) | New entries in reflexes.json |
| Recurring Agent patterns | Agent (.md) | fs-code-reviewer.md |

#### 3a: Check for pending evolved skills

Before presenting new clusters, check `~/.claude/cortex/evolved/skills/` for previously generated but not yet installed skills:

```
PENDING INSTALLS (from previous evolve runs):
  1. fs-vps-checklist (generated 2026-04-07)
  2. fs-api-error-handling (generated 2026-04-05)

  I=Install  S=Skip
  Ejemplo: "1I, 2S"
```

Wait for user input before proceeding.

#### 3b: Present new clusters with shorthand

Present ALL clusters in a single consolidated view with recommendations:

```
CLUSTERS:
1. server-provisioning (12 instincts) → Skill: fs-vps-provisioning-checklist
   ✅ RECOMIENDO ACEPTAR — 12 gotchas críticos sin skill existente
2. web-design (4 instincts) → ⚠️ YA CUBIERTO en fs-web-design sección 13 (líneas 789-814)
   ⏭️ OMITIR — Las 4 preferencias ya están en la skill existente
3. supabase-rls (5 instincts) → 🔀 PARCIAL — 3 de 5 ya en fs-supabase-gotchas
   🔀 MERGE RECOMENDADO — Mergear 2 instincts nuevos en fs-supabase-gotchas sección RLS
4. web-dev (3 instincts) → Rules en reflexes.json
   ✅ RECOMIENDO ACEPTAR — Gotchas puntuales, mejor como reflexes

Shorthand: A=Aceptar  X=Rechazar  M=Merge con skill existente  O=Omitir  S=Skip
Ejemplo: "1A, 2O, 3M, 4A"
```

If the user provides invalid shorthand, ask them to repeat with the correct format.

NEVER use AskUserQuestion — always present clusters as plain text.

**CRITICAL**: After collecting user shorthand input, do NOT execute yet. Proceed to Step 3c.

#### 3c: Confirmation gate

After receiving user input, display a summary of ALL actions that will be executed:

```
RESUMEN DE ACCIONES:
  1. GENERAR skill fs-vps-provisioning-checklist (12 instincts)
  2. OMITIR web-design (ya cubierto en fs-web-design)
  3. MERGE 2 instincts en fs-supabase-gotchas sección RLS
  4. GENERAR reflexes.json entries para web-dev (3 instincts)

  Confirmar? (Y/N)
```

**NEVER chain recommendation and execution in the same turn.** Wait for explicit "Y" confirmation before proceeding to Step 4.

### Step 4: Generate Artifacts

Only after explicit user confirmation in Step 3c, generate the approved artifacts:

Use Sonnet to synthesize each approved cluster into a coherent artifact:

For **Skills**: Generate a SKILL.md with:
- Metadata (name, description, triggers)
- Consolidated action instructions
- Evidence from source instincts

For **Commands**: Generate a command .md with:
- Metadata (name, description)
- Step-by-step implementation
- Based on patterns from source instincts

For **Rules**: The canonical output is new entries appended to `~/.claude/cortex/reflexes.json` with:
- matcher, condition, action derived from instinct triggers/actions
- A backup copy of the generated rule entries is also written to `~/.claude/cortex/evolved/rules/` for reference (not authoritative — reflexes.json is the source of truth)

For **Agents**: Generate an agent .md with:
- Metadata (name, description, model recommendation)
- System prompt synthesized from the recurring Agent prompts
- Tool access requirements (which tools the agent needs)
- Invocation example (`Agent tool` with the prompt template)
- Written to `~/.claude/cortex/evolved/agents/` and also to `~/.claude/agents/` for immediate use

Agent detection: session-learner.js detects Agent tool observations with similar
descriptions (Jaccard >= 0.40 on description words, 3+ occurrences). These appear
as proposals with domain `agent-evolution`. When evolving, cx-evolve synthesizes
the common prompt pattern into a reusable agent definition.

For **Merges**: Read the target skill, identify the correct section, and append the new instinct content:
- Show a preview/diff of the proposed changes to the user BEFORE writing (merges modify existing files — this is more invasive than creating new ones)
- Add new content under the most relevant existing section
- If no section fits, create a new section at the end
- Preserve existing content — never overwrite or reorder

### Step 5: Write and Mark Sources

1. Write NEW artifacts to `~/.claude/cortex/evolved/{skills,commands,rules,agents}/`
2. Write AGENTS also to `~/.claude/agents/` for immediate availability
3. Write MERGED content directly into the existing skill file in `~/.claude/skills/`
3. All generated files MUST use `fs-` prefix (e.g., `fs-supabase-rls.md`)
4. Update source instincts: set `evolved_to: "{artifact-id}"` in their YAML

### Step 5b: Log to Knowledge Timeline

After writing artifacts in Step 5, append one line per evolved cluster to `~/.claude/cortex/knowledge-log.md`:

```bash
echo "$(date +%Y-%m-%d) | evolved | {artifact-id} | {N} instincts | cx-evolve" >> ~/.claude/cortex/knowledge-log.md
```

### Step 6: Summary

```
CORTEX EVOLVE — Results
  Clusters found: N
  Already covered (omitted): M
  Artifacts generated:
    - fs-supabase-rls.md (Skill, from 4 instincts)
    - fs-pre-deploy-check.md (Command, from 3 instincts)
  Merged into existing skills:
    - 2 instincts → fs-supabase-gotchas (sección RLS)
  Pending installs installed: K

  Install evolved skills with:
    cp ~/.claude/cortex/evolved/skills/*.md ~/.claude/skills/
```

## Guidelines

- Conservative: only evolve clusters with strong agreement (3+ instincts, conf >= 0.70)
- User approval required for each generation
- Never delete source instincts (they keep accumulating evidence)
- Prefix all artifacts with fs-
