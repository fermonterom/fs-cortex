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
FILTRO DE UNIVERSALIDAD — Laws cuestan ~40 tokens CADA sesion.
Solo promover si el patron aplica a la MAYORIA de sesiones de trabajo.
Un instinto global con buen trigger ya se inyecta cuando hace falta.
La pregunta NO es "es util?" sino "lo necesito en TODAS las sesiones?"
```

**Proceso de evaluacion (en este orden — si falla un paso, RECHAZAR):**

1. **Duplicado check**: ¿Ya existe una law que cubra esto? → RECHAZAR
2. **Conteo de proyectos**: ¿En cuantos proyectos DISTINTOS se ha observado?
   - Leer el campo `project_id` y cruzar con `projects_seen` si existe
   - Buscar instintos similares (Jaccard >= 0.50) en OTROS proyectos
3. **Test de universalidad**:

| Proyectos | Stack | Veredicto | Razon |
|-----------|-------|-----------|-------|
| 5+ proyectos | cualquier | ✅ PROMOVER | Patron universal demostrado |
| 3-4 proyectos | stack principal | ✅ CANDIDATO | Probable universal |
| 3-4 proyectos | nicho | ⚠️ EVALUAR | Puede ser coincidencia |
| 1-2 proyectos | stack principal | ❌ RECHAZAR | Mejor como instinto global — ya se inyecta por trigger |
| 1-2 proyectos | nicho | ❌ RECHAZAR | Definitivamente instinto, no law |
| 1 proyecto | cualquier | ❌ RECHAZAR | Un proyecto no justifica 40 tok/sesion permanentes |

**Stack principal** = Next.js, React, TypeScript, Supabase, Tailwind, git, testing
**Stack nicho** = SSH, VPS, Docker provisioning, n8n, PostgreSQL restore, herramientas one-off

4. **Test del coste/beneficio**: Si el instinto ya tiene un trigger especifico que
   matchea bien (ej: `Bash|ssh|heredoc`), NO promover a law — como instinto global
   ya se inyecta solo cuando hace falta, sin gastar tokens en sesiones donde no aplica.
   Solo promover a law si el patron no tiene un trigger natural y necesita estar
   siempre presente (ej: "use conventional commits" — no hay trigger especifico).

#### 3b. Comparar con laws existentes

Antes de crear una law nueva:
1. Listar todas las laws actuales de `~/.claude/cortex/laws/*.txt` con su contenido
2. Detectar duplicados o solapamientos entre candidatos y laws existentes
3. Si hay 10 laws activas, evaluar si el candidato es MAS importante que alguna existente:
   - Comparar confidence del instinct fuente vs confidence de las laws actuales
   - Si el candidato supera a alguna law existente: proponer reemplazo
   - Si no supera a ninguna: NO proponer (mantener como instinct)

#### 3c. Presentar candidatos con shorthand

Mostrar al usuario con datos de decision claros:

```
CORTEX DISTILL — Candidatos a law (N encontrados, M recomendados)

Candidatos:
1. {instinct-id} (conf: {value})
   → "{one-liner condensado}"
   Proyectos: {N} de {total} ({lista de nombres})
   Trigger actual: {trigger} — {"ya se inyecta por trigger" | "sin trigger natural"}
   Stack: {principal|nicho}
   Coste: +40 tok/sesion permanente vs inyeccion por trigger actual
   ✅ PROMOVER A LAW — {razon: visto en 5+ proyectos, sin trigger natural}
   — o —
   ❌ MANTENER COMO INSTINTO — {razon: "solo 1 proyecto", "trigger SSH ya funciona", etc}

RESUMEN RAPIDO:
  Recomendados: {ids}
  No recomendados: {ids} (quedan como instintos, siguen funcionando por trigger)
  Duplicados de laws existentes: {ids} (ya cubiertos)
```

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

### Step 4b: Log to Knowledge Timeline

After all changes in Steps 2-4, append one line per action to `~/.claude/cortex/knowledge-log.md`:

For each decayed instinct:
```bash
echo "$(date +%Y-%m-%d) | decayed | {id} | {old_conf}→{new_conf} | cx-distill" >> ~/.claude/cortex/knowledge-log.md
```

For each archived instinct:
```bash
echo "$(date +%Y-%m-%d) | archived | {id} | {final_conf} | cx-distill" >> ~/.claude/cortex/knowledge-log.md
```

For each new law distilled:
```bash
echo "$(date +%Y-%m-%d) | law | {id} | {confidence} | cx-distill" >> ~/.claude/cortex/knowledge-log.md
```

For each Jaccard promotion (project → global):
```bash
echo "$(date +%Y-%m-%d) | global | {id} | {confidence} | cx-distill" >> ~/.claude/cortex/knowledge-log.md
```

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

After completing distillation, update the marker and clear the candidates file
so session-start does not re-trigger the MAINT reminder:

```bash
# Mark distill as run
touch ~/.claude/cortex/.last-distill

# Clear candidates file — session-start checks bool(content.strip())
# so an empty file suppresses the reminder until auto-distill finds new candidates
> ~/.claude/cortex/auto-distill-candidates.md
```

Clearing the file is safe: `distill_engine.py` → `_write_candidates_file()`
repopulates it on the next SessionStart if new candidates emerge. Truncating
here just signals "the user has reviewed what was pending".

## Recommended schedule

Run weekly, or when /cx-status shows mature instincts ready for distillation.
Session-start will remind you after 7+ days without running.
