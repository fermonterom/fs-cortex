---
name: cx-distill
description: Distill laws from mature instincts, apply decay, check promotions
command: true
---

# /cx-distill

## What it does

Maintenance command that:
1. Auto-distills Laws from instincts with confidence >= 0.90
2. Applies confidence decay (-0.05 per 30 days unused)
3. Checks Jaccard promotions (project → global)
4. Archives decayed instincts (confidence < 0.10)
5. Enforces max 10 active laws

## Usage

```
/cx-distill              # Full maintenance pass
/cx-distill --dry-run    # Show what would change without writing
```

## Implementation

### Step 1: Scan All Instincts

Read all instinct YAML files from:
- `~/.claude/cortex/instincts/global/*.yaml`
- `~/.claude/cortex/projects/*/instincts/*.yaml`

For each, extract: id, trigger, action, confidence, domain, tags, scope, last_seen, occurrences

### Step 2: Apply Confidence Decay

For each instinct:
```
days_unused = (today - last_seen).days
decay_periods = floor(days_unused / 30)
new_confidence = confidence - (0.05 * decay_periods)
```

If new_confidence < 0.10:
- Move YAML file to archive based on scope:
  - Global instincts → `~/.claude/cortex/instincts/archive/`
  - Project instincts → `~/.claude/cortex/projects/{hash}/instincts/archive/`
- Display: "Archived [id] — confidence decayed to [value]"

If confidence changed:
- Update the YAML file with new confidence and add evidence note: "Decay applied: -X on YYYY-MM-DD"

### Step 3: Auto-Distill Laws (with universality gate)

Scan instincts with confidence >= 0.90 that don't have a corresponding law.

#### 3a. Filtro de universalidad

Para cada candidato, evaluar ANTES de proponer:

```
FILTRO DE UNIVERSALIDAD:
- Revisar en cuántos proyectos distintos se ha observado el patrón
- Si solo aparece en 1 proyecto y es tecnología nicho: NO promover a law
- Si aparece en 1 proyecto pero es práctica universal (ej: "test before deploy"): SÍ candidato
- Las laws deben ser el común denominador de TODOS los proyectos
```

Criterios concretos:
1. **Multi-proyecto (3+)**: Promover automaticamente si confidence >= 0.90
2. **Mono-proyecto, stack principal** (Next.js, React, Supabase, TypeScript, Tailwind): Candidato si la practica es generalizable mas alla del proyecto especifico
3. **Mono-proyecto, tecnologia nicho** (SSH, VPS provisioning, herramientas one-off): NO promover a law — mantener como instinct global como maximo

#### 3b. Comparar con laws existentes

Antes de crear una law nueva:
1. Listar todas las laws actuales de `~/.claude/cortex/laws/*.txt` con su contenido
2. Detectar duplicados o solapamientos entre candidatos y laws existentes
3. Si hay 10 laws activas, evaluar si el candidato es MAS importante que alguna existente:
   - Comparar confidence del instinct fuente vs confidence de las laws actuales
   - Si el candidato supera a alguna law existente: proponer reemplazo
   - Si no supera a ninguna: NO proponer (mantener como instinct)

#### 3c. Presentar candidatos con shorthand

Mostrar al usuario en formato rapido:

```
CORTEX DISTILL — Candidatos a law (N encontrados)

Candidatos:
1. {instinct-id} → "{one-liner condensado}"
   Proyectos: {N} | Confidence: {value} | Stack: {principal|nicho}
   ✅ RECOMIENDO — {razon}
   — o —
   ❌ NO RECOMIENDO — {razon: ej "Solo aplica a VPS/PostgreSQL, no al stack principal"}

Duplicados detectados:
N. {instinct-a} ↔ {instinct-b}
   🔀 RECOMIENDO MERGE — {razon: ej "El segundo es superset del primero"}

Laws existentes que serian reemplazadas:
N. {law-id} (confidence: {value}) ← reemplazada por {candidato-id} (confidence: {value})
   🔄 RECOMIENDO REEMPLAZO — {razon}

Shorthand: A=Aceptar  X=Rechazar  M=Merge  S=Skip
Ejemplo: "1A, 2X, 3M"
```

If the user provides invalid shorthand, ask them to repeat with the correct format.

NEVER use AskUserQuestion — always present candidates as plain text.

#### 3d. Ejecutar con confirmacion

**IMPORTANTE**: Despues de presentar candidatos y recoger input del usuario:
1. Mostrar resumen de acciones a ejecutar (que laws se crean, cuales se archivan, que merges se hacen)
2. Esperar confirmacion explicita del usuario
3. Solo entonces ejecutar las escrituras

Para cada candidato aceptado:
1. Condense action into one-liner (max 120 chars)
   Format: "When X, do Y" or "Always X when Y" or "NEVER X"
2. Write to `~/.claude/cortex/laws/{id}.txt`

Para merges: combinar el contenido de ambos instincts en una sola law, archivando el instinct redundante.

Para reemplazos: archivar la law antigua a `~/.claude/cortex/laws/archive/` antes de escribir la nueva.

NUNCA encadenar opinion y ejecucion en un mismo turno.

### Step 4: Check Jaccard Promotions

For each project-scoped instinct with confidence >= 0.80:
1. Compute Jaccard similarity of trigger + action tokens against all instincts in OTHER projects
2. If Jaccard >= 0.70 and pattern exists in 2+ projects:
   - Apply the same universality filter from Step 3a before promoting
   - Create global copy in `~/.claude/cortex/instincts/global/`
   - Set scope: global, confidence: average of matched instincts
   - Mark source instincts with `promoted_to: "{global-id}"`

Jaccard computation:
```
tokens_a = set(trigger_a.split("|") + action_a.lower().split())
tokens_b = set(trigger_b.split("|") + action_b.lower().split())
jaccard = len(tokens_a & tokens_b) / len(tokens_a | tokens_b)
```

Present Jaccard promotion candidates using shorthand format:
```
JACCARD PROMOTIONS (project → global):
1. {instinct-id} — presente en {N} proyectos, Jaccard {value}
   ✅ RECOMIENDO PROMOVER — {razón}
   — o —
   ❌ NO RECOMIENDO — {razón}

Shorthand: A=Promover a global  X=No promover  S=Skip
Ejemplo: "1A, 2X"
```

If the user provides invalid shorthand, ask them to repeat with the correct format.

Wait for user confirmation before executing any promotions. NEVER use AskUserQuestion — always present as plain text.

### Step 5: Summary

```
CORTEX DISTILL — Results
  Instincts scanned: N
  Decay applied: N instincts
  Archived (decayed): N
  Laws distilled: N
  Promotions (project→global): N
  Active laws: N/10
```

### Step 6: Update Maintenance Marker

After completing distillation, update the marker so session-start knows when this last ran:
```bash
touch ~/.claude/cortex/.last-distill
```

## Recommended schedule

Run weekly, or when /cx-status shows mature instincts ready for distillation.
Session-start will remind you after 7+ days without running.
