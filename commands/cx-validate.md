---
name: cx-validate
description: Review and confirm/reject instinct proposals interactively
command: true
---

# /cx-validate

## What it does

Interactive review of pending proposals and weak instincts. Lets the user confirm (+0.20 confidence) or reject (-0.20 or delete) each one.

## Usage

```
/cx-validate             # Review all pending
/cx-validate --accept-all  # Accept all proposals
```

## Implementation

### Step 1: Load Proposals

Read `~/.claude/cortex/proposals.json`. Filter to status: "pending".

If the file does not exist or has zero pending proposals AND there are no weak instincts (Step 2), inform the user: "No hay propuestas pendientes. Ejecuta /cx-analyze primero." and stop.

### Step 2: Load Weak Instincts

Read all instinct YAML files. Filter to confidence < 0.50 (hypotheses needing validation).

### Step 3: Present ALL Proposals with Verdict

Display all proposals and weak instincts as a numbered list in plain text (NEVER use interactive UI elements like AskUserQuestion). For each item, include Claude's recommendation with reasoning.

For each proposal, analyze and emit a verdict:
- **Accept** when the pattern represents a real, non-obvious gotcha or a genuinely useful automation that is not already covered by an existing instinct, law, or skill.
- **Reject** when the pattern is redundant with existing knowledge, too vague to be actionable, project-specific but marked global, or a one-off that is unlikely to recur.

Format for proposals:
```
PROPUESTA 1/N: [id] (conf: [current] -> [current + 0.20])
  Trigger: [trigger regex]
  Action: [action text]
  Scope: [global|project] | Origen: [source]
  [verdict emoji] [RECOMIENDO ACEPTAR|RECHAZAR] -- [one-line reason]
```

Format for weak instincts:
```
HIPOTESIS M/N: [id] (conf: [value])
  Trigger: [trigger]
  Action: [action]
  Ultima vez: [date] | Ocurrencias: [count]
  [verdict emoji] [RECOMIENDO CONFIRMAR|DESCARTAR] -- [one-line reason]
```

After listing ALL items, present the shorthand input prompt:
```
Responde con shorthand: numero + letra
  A = Aceptar    X = Rechazar    S = Skip (revisar despues)

Ejemplo: "1A, 2A, 3X, 4A, 5X, 6A, 7S" o "all-A" para aceptar todas

Tu respuesta:
```

If the user provides invalid shorthand (unknown letters, out-of-range numbers, unparseable format), ask them to repeat with the correct format.

Then STOP and wait for the user's shorthand response. Do NOT proceed until the user replies.

### Step 4: Confirm Before Executing

After receiving the user's shorthand input, parse the response and display a summary of pending actions. Do NOT create, edit, or delete any files yet.

```
RESUMEN DE ACCIONES
  Aceptar:   N propuestas  ([list ids])
  Rechazar:  N propuestas  ([list ids])
  Confirmar: N hipotesis   ([list ids])
  Descartar: N hipotesis   ([list ids])
  Skip:      N items

Procedo? (si/no)
```

Then STOP and wait for explicit user confirmation. Only after the user responds affirmatively (e.g. "si", "dale", "ok", "yes"), proceed to Step 4b.

### Step 4b: Execute Confirmed Choices

This step runs ONLY after the user explicitly confirmed in Step 4.

- Accept proposal: create YAML file with confidence + 0.20. Write path depends on scope:
  - Global scope → `~/.claude/cortex/instincts/global/{id}.yaml`
  - Project scope → `~/.claude/cortex/projects/{project_hash}/instincts/{id}.yaml`
  The YAML file written must follow this exact schema:
  ```yaml
  ---
  id: {proposal.id}
  trigger: "{proposal.trigger}"
  action: "{proposal.action}"
  confidence: {proposal.confidence + 0.20}
  domain: {proposal.domain}
  tags: []
  scope: {proposal.scope}
  project_id: "{proposal.project_id}"
  project_name: "{proposal.project_name}"
  source: "{proposal.source}"
  first_seen: "{proposal.detected}"
  last_seen: "{today}"
  occurrences: 1
  evidence:
    - "{proposal.detected}: Detected by {proposal.source}"
  ---
  ```
  Confidence is clamped to [0.0, 0.95] after adjustment.
- Reject proposal: remove from proposals.json
- Confirm instinct: update confidence + 0.20, update last_seen
- Dismiss instinct: reduce confidence by 0.20, archive if below 0.10

### Step 5: Summary

```
CORTEX VALIDATE — Results
  Proposals accepted: N
  Proposals rejected: N
  Instincts confirmed: N
  Instincts dismissed: N
  Remaining pending: N
```
