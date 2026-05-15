# Sprint 8 — Detector Healing + Autopilot Foundation (FINAL)

**Status:** ✅ PLAN v7 FINAL — post-Día 0 + post-Codex AD round 3. Ready for Día 1 execution.
**Author:** sesión 2026-05-14/15
**Target releases:** v3.29.0 (atomic, 3 días + Día 0 prep) → 7 días observación → v3.30.0 (autopilot real)
**Operator UX goal:** ZERO manual `/cx-*` invocations needed (medido a 14 días POST-release, NO release gate)

---

## 0. Cambios desde plan v4 (correcciones AD round 2 + verificación runtime)

Codex AD round 2 detectó 5 P0 NUEVOS. Todos corregidos en este v5 final:

| P0 | Cambio |
|----|--------|
| Ghost guard auto-autorizaba `cx-validate-auto` | **§4.7**: removido del whitelist. Solo acepta `cx-validate`, `cx-auto-validate`, `cx-cleanup`, `v3.28.9-cleanup`, `None`. La ghost script ahora dispara restauración a pending |
| "REPLANTEAR" sin criterios | **§5.4**: decision table objetiva con 4 ramas de Sinapsis |
| HUMAN→AUTO promotion estadísticamente débil | **§5.3**: gate `n >= 20 reviewed proposals/detector + accept_rate >= 70% + 0 critical rejections` |
| **CRÍTICO: runtime no soporta `condition`** | **§4.2 REDISEÑADO**: file-coupling usa regex puro en `trigger` (`Edit.*(?:f1\|f2)`). VERIFICADO en `injector-engine.js:89` (`matchTarget = toolName + " " + toolInputStr`) — el matcher SÍ ve los file paths, no necesita campo separado |
| `[ACTION]` nag con human-gated | **§4.10**: `session-start.py:215-223` modificado para contar solo `VALIDATE_AUTO_DOMAINS` en el banner. Human-gated visibles solo en `/cx-status --pipeline` |
| P1: tests retire incompletos | **§4.6**: borrar helper local `detectWorkflowChains` de `test_session_learner.sh:80` + asserts de ausencia en módulo real |
| P1: kill switches sin scope claro | **§4.8**: semántica explícita por state file + test isolation por fichero |
| P1: git archaeology no exhaustiva | **§4.7 paso 1 ampliado**: `-S` + `-G` + scan en `~/.claude/commands\|agents\|plugins\|skills/` |
| P1: archive overwrite | **§4.9**: timestamp + SHA-256 checksum + manifest |
| P1: observation schema drift | **§4.11 E2E test**: fixture con paired Pre/Post events |
| Falta de pre-ship gate | **§4.12 NUEVO**: `test_v329_acceptance.sh` — prueba 4 invariantes en sandbox antes de permitir tag |
| Instincts huérfanos de detectores retired | **§4.13 NUEVO**: barrido de YAMLs con `id: repeat-*` y `id: workflow-*` → archive |

---

## 1. Estado actual (post-v3.28.9, 2026-05-15)

**v3.28.9 desplegado (PR #34, tests 363/363):**
- ✅ Sprint 5 + V3.27 gates cerrados (excepto A/B diferidos)
- ✅ 5 detectores ruidosos detrás de `CORTEX_LEGACY_DETECTORS=0`
- ✅ Gate 1 métrica fixed (aggregate ratio)
- ✅ Bulk-cleanup proposals stale

**Lo que funciona y NO se toca:**
- Reflexes (16 healthy)
- TimeOfDay productivity
- CrossDayBoost
- `detectErrorResolutions` (único bien diseñado)
- `auto_validate_proposals()` + `auto_promote_to_law()` + `auto_evolve_detect()` (engine OK, falta cablear analyze)

**Lo que sigue roto:**
- 5 detectores con bugs (a reescribir o retirar en este Sprint)
- 2 dominios huérfanos
- Ghost script `cx-validate-auto` sin localizar
- Sin `analyze_engine.py` (v3.30 scope)
- 933 proposals históricas archivables

---

## 2. Diagnóstico técnico (referencia)

Ver historia git del PR #34 para diagnóstico completo de los 3 bugs estructurales (Gate 1, 5 detectores, ghost script). Resumen aplicable a Sprint 8:

- **Datos verificados en código:**
  - `injector-engine.js:40-53` — `parseInstinctYaml` lee solo `id, trigger, action, confidence, domain, scope, project_id`. NO existe campo `condition`.
  - `injector-engine.js:89` — `matchTarget = toolName + " " + toolInputStr`. **El regex se evalúa contra tool name + JSON-stringified input.** File paths visibles.
  - `injector-engine.js:318` — `safeRegexTest(inst.trigger, matchTarget, ...)`. La función `safeRegexTest` está en `regex-guard.js`, con safety (timeout, complexity caps).
  - `session-start.py:215-223` — emite `[ACTION] N pending proposals` para CUALQUIER `status == 'pending'`. No distingue por domain.
  - `session-learner.js:1553` — feedback de reflexes hard-coded a `source: "agent"`.

---

## 3. Matriz de detectores (decisión final)

| Detector | Líneas | Decisión v3.29.0 | Notas |
|----------|--------|------------------|-------|
| `detectErrorResolutions` | 241-303 | **KEEP active** | Único bien diseñado |
| `detectRepetitions` | 318-355 | **RETIRE (delete code)** | Sin caso de uso reaparecible |
| `detectUserCorrections` | 382-419 | **REWRITE → HUMAN-gated** | Domain `correction` (no `gotcha`); conf 0.55; imperative action |
| `detectWorkflowChains` | 425-460 | **RETIRE (delete code)** | Trigger irrecuperable (pierde secuencia); sin rewrite viable |
| `detectAgentPatterns` | 466-516 | **KEEP active + TUNE** | min items 3 → 4 (conf 0.55) |
| `detectAgentSubtypes` | 522-585 | **REWRITE → HUMAN-gated** | Domain `agent-quality` registrado en HUMAN_DOMAINS; conf 0.50 |
| `detectFileCoupling` | 587-642 | **REWRITE → HUMAN-gated** | Trigger regex puro `Edit.*(?:f1\|f2)` (verificado contra runtime); domain `coupling` en HUMAN_DOMAINS; scope `project` |
| `detectTimeOfDayPatterns` | 644-750 | **KEEP active (infra)** | Sin proposals, solo `productivity-patterns.json` |
| `detectCommandUsage` | 756-785 | **KEEP active (infra)** | Sin proposals, solo `timeline.jsonl` |

**Resultado net v3.29.0:**
- 4 active produciendo proposals: `detectErrorResolutions`, `detectAgentPatterns`, `detectTimeOfDayPatterns`(infra), `detectCommandUsage`(infra)
- 3 reescritos en HUMAN-gated (visibles solo en `/cx-status`, NO en banner [ACTION])
- 2 retired (código borrado, tests asociados borrados)
- Env-var `CORTEX_LEGACY_DETECTORS` eliminada (ya no hay legacy)

**`distill_engine.py:84-85` actualizado:**
```python
VALIDATE_AUTO_DOMAINS  = {'gotcha', 'pattern', 'error-recovery', 'agent-evolution'}
VALIDATE_HUMAN_DOMAINS = {'correction', 'user-preference', 'decision', 'workflow',
                          'coupling', 'agent-quality'}  # ← NEW
```

---

## 4. Plan v3.29.0 — Detector Healing (atomic)

### 4.1 Registrar dominios huérfanos (10 min)

`distill_engine.py:85` añade `coupling` + `agent-quality` a `VALIDATE_HUMAN_DOMAINS`.
**Test:** caso "proposal con domain=coupling queda pending (no auto-accept ni auto-reject)".

### 4.2 Rewrite `detectFileCoupling` con regex puro en trigger (45 min)

**File:** `hooks/session-learner.js:587-642`

```js
function escapeRegex(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Inside detectFileCoupling, when emitting:
const triggerRegex = `Edit.*(?:${escapeRegex(baseA)}|${escapeRegex(baseB)})`;
proposals.push({
  id: `coupling-${shortHash}`,
  status: 'pending',
  trigger: triggerRegex,
  action: `When editing ${baseA}, also check ${baseB} — coupled in ${sessionCount}+ sessions across ${dayCount}+ days (project-scoped).`,
  confidence: 0.55,
  domain: 'coupling',
  scope: 'project',                      // ← critical: NOT global
  project_id: detectedProjectId,
  source: 'session-learner:file-coupling',
});
```

`escapeRegex()` se DEDUPLICA: movido a nuevo módulo `hooks/lib/regex-utils.js`, importado tanto desde `session-learner.js` como desde `cross-day-tracker.js`.

**Tests:**
- file-coupling emite trigger regex válido (matchea `safeRegexTest("Edit.*(?:foo|bar)", "Edit foo.ts", ...)` → true)
- NO matchea `Edit baz.ts` (negative test)
- scope siempre `project`

### 4.3 Rewrite `detectUserCorrections` → HUMAN-gated (30 min)

`hooks/session-learner.js:382-419`:
- `domain`: `'correction'` (NOT `'gotcha'`)
- `confidence`: 0.55
- `action`: `"Before editing ${file}, scan recent commits — corrected ${count}+ times. Pattern likely needs deeper attention."`
- `scope`: `'project'`

### 4.4 Rewrite `detectAgentSubtypes` → HUMAN-gated (20 min)

`hooks/session-learner.js:522-585`:
- `domain`: `'agent-quality'`
- `confidence`: 0.50
- imperative action

### 4.5 Tune `detectAgentPatterns` (15 min)

`hooks/session-learner.js:508`: min items 3 → 4 (asegura conf 0.55 al primer threshold).

### 4.6 Retire detectRepetitions + detectWorkflowChains (30 min)

Borrar:
- `hooks/session-learner.js:318-355` (detectRepetitions function)
- `hooks/session-learner.js:425-460` (detectWorkflowChains function)
- Call sites en `~1628, ~1636`
- Helper local `detectWorkflowChains` en `tests/test_session_learner.sh:80` (P1 fix)
- Env-var `CORTEX_LEGACY_DETECTORS` (eliminada — ya no aplica)

Añadir assertions:
- `test_session_learner.sh` verifica que `detectRepetitions` y `detectWorkflowChains` NO existen como function declarations en el módulo real.

### 4.7 Ghost script: arqueología + guard preventivo (90 min)

**Paso 1 — Arqueología exhaustiva (Día 0):**

```bash
cd /Users/fmm/github/fs-cortex

# 1) String literal search
git log --all --full-history -S "cx-validate-auto" --oneline
git log --all --full-history -p -S "cx-validate-auto"

# 2) Assembled-string search (regex over diffs)
git log --all --full-history -G "cx[-_]validate[-_]auto" --oneline

# 3) Deleted file detection
git log --all --diff-filter=D --summary | grep -i validate

# 4) External scan (outside repo)
grep -rn "cx-validate-auto\|cx_validate_auto" \
  ~/.claude/commands/ ~/.claude/agents/ ~/.claude/plugins/ \
  ~/.claude/skills/ ~/.claude/hooks/ 2>/dev/null

# 5) Settings + plugin manifests
grep -rn "cx-validate-auto" ~/.claude/settings*.json ~/.claude/plugins/*/manifest.json 2>/dev/null
```

Output: `docs/GHOST-CX-VALIDATE-AUTO.md` con:
- Si encuentra script → describir + decidir si revertir o documentar
- Si NO encuentra → "fenómeno externo no reproducible; guard preventivo es la mitigación final"

**Paso 2 — Guard preventivo (`hooks/lib/distill_engine.py`):**

```python
def _detect_unauthorized_rejections(proposals):
    """v3.29.0: restore proposals rejected by unknown sources to pending.
    
    cx-validate-auto bulk-rejected 648 proposals on 2026-05-05 from an
    unknown script. NOT in the whitelist (deliberately excluded).
    """
    AUTHORIZED = {
        'cx-validate',           # manual /cx-validate
        'cx-auto-validate',      # distill_engine.auto_validate_proposals
        'cx-cleanup',            # ops cleanup
        'v3.28.9-cleanup',       # the bulk-reject we did in v3.28.9
        None,                    # legacy: pre-Sprint-7 acceptances
    }
    # NOTE: 'cx-validate-auto' is INTENTIONALLY excluded.
    restored = 0
    for p in proposals:
        if p.get('status') == 'rejected' and p.get('rejected_by') not in AUTHORIZED:
            log(f"[CORTEX SECURITY] unauthorized reject by {p.get('rejected_by')!r} "
                f"on proposal {p.get('id')!r} — restoring to pending")
            p['status'] = 'pending'
            p.pop('rejected_by', None)
            p.pop('rejected_reason', None)
            restored += 1
    return restored
```

Llamar al inicio de `auto_validate_proposals()`.

**Test:** proposal con `rejected_by: "cx-validate-auto"` se restaura a pending, instinct se crea si pasa gates.

### 4.8 Kill switches con semántica explícita por state file (45 min)

```bash
CORTEX_OBSERVE_OFF=1      # observe.py exits early. NO writes a:
                          #   - ~/.claude/cortex/observations.jsonl
                          #   - ~/.claude/cortex/projects/*/observations.jsonl

CORTEX_DETECTORS_OFF=1    # session-learner.js detectors return []. NO writes a:
                          #   - proposals.json
                          # SIGUE escribiendo (para no perder datos esenciales):
                          #   - reflexes.json (counters)
                          #   - impact.jsonl (correlations)
                          #   - timeline.jsonl
                          #   - productivity-patterns.json
                          #   - instinct-tracking.json

CORTEX_AUTODISTILL_OFF=1  # session-start.py run_auto_distill() exits early. NO:
                          #   - decay, archive, auto-validate, auto-promote-to-law,
                          #     auto-evolve. proposals.json + instincts/ no cambian
```

Tests de aislamiento (`test_kill_switches.sh`): por cada env var, fixture observations → ejecutar hooks → verificar que cada state file específico permanece intacto.

### 4.9 Limpieza histórica con timestamp + checksum (15 min)

```bash
# Sin tocar proposals.json activo
ts=$(date +%Y%m%d-%H%M%S)
archive=~/.claude/cortex/archive/proposals-pre-v3.29-${ts}.tar.gz
tar -czf "$archive" ~/.claude/cortex/proposals.json.bak*
sha256sum "$archive" > "${archive}.sha256"
# Solo entonces borrar originales
rm ~/.claude/cortex/proposals.json.bak*
```

### 4.10 Banner [ACTION] excluye HUMAN_DOMAINS (30 min)

**File:** `hooks/session-start.py:215-223`

```python
# v3.29.0: count only auto-domain pending. Human-gated stays silent
# (visible only in /cx-status --pipeline).
AUTO_DOMAINS = {'gotcha', 'pattern', 'error-recovery', 'agent-evolution'}
pending_auto = sum(
    1 for p in proposals
    if p.get('status', 'pending') == 'pending'
    and p.get('domain') in AUTO_DOMAINS
)
if pending_auto > 0:
    reminders.append(f"[ACTION] {pending_auto} pending proposals. Run /cx-validate to review.")
```

`/cx-status --pipeline` mantiene ambos counts (auto + human) en su tabla.

**Test:** session con 50 proposals human-gated + 0 auto → NO emite `[ACTION]` reminder.

### 4.11 Tests Sprint 8 (90 min)

Tests nuevos:
- `tests/test_session_learner.sh` +4 casos: file-coupling regex válido + matches scope; user-corrections domain=correction; agent-subtypes domain=agent-quality; retired detectors absent
- `tests/test_distill_engine.sh` +3 casos: coupling + agent-quality skip con `needs-human-judgment`; ghost guard restaura pending; auto-validate ignora HUMAN_DOMAINS sin alarm
- `tests/test_kill_switches.sh` NEW (3 casos)
- `tests/test_e2e_pipeline.sh` NEW (5 casos): fixture observations + paired Pre/Post tool events → Stop hook → proposals → SessionStart → auto-distill → asserts
- **Total esperado: 363 → 380+ tests PASS**

### 4.12 Pre-ship acceptance gate (NUEVO, 60 min)

`tests/test_v329_acceptance.sh` ejecuta EN SANDBOX (v7 update — añadidos asserts §4.15 y §4.16):

1. Install v3.29 limpia en `SANDBOX=$(mktemp -d) HOME=$SANDBOX bash install.sh`
2. Genera fixture: 30 observations sintéticas con paired Pre/Post events
3. Ejecuta Stop hook → assert: proposals tienen trigger regex válido (compilable + matchea SOLO target intencional)
4. Inyecta proposal con `rejected_by: "cx-validate-auto"` → ejecuta SessionStart → assert: proposal restaurada a pending
5. Crea 50 proposals human-gated + 0 auto → ejecuta SessionStart → assert: NO `[ACTION]` en output
6. Activa cada kill switch sequentially → assert: cada state file específico no cambia
7. **NEW v7 (§4.15)**: dispara PreCompact hook con observations pendientes → assert: observations.jsonl tiene los registros flushed AND hook returns exit 0 en <8s AND `CORTEX_OBSERVE_OFF=1` cancela el flush
8. **NEW v7 (§4.16)**: inyecta instinct con conf=0.95 sustained=14d distinct_sessions=2 → ejecuta auto_promote_to_law → assert: NO promueve, queda como candidate con reason `distinct_sessions < 3`. Luego añade 1 sesión más → assert: promueve

**Si CUALQUIERA de los 8 asserts falla → NO se permite git tag v3.29.0.**

Integrar en `.githooks/pre-push` (existente).

### 4.13 Limpieza instincts huérfanos retired (15 min)

Script `tests/cleanup_retired_instincts.sh`:

```bash
# Move instincts created by retired detectors to archive
INSTINCT_DIR=~/.claude/cortex/projects
ARCHIVE=~/.claude/cortex/archive/retired-instincts-$(date +%Y%m%d)
mkdir -p "$ARCHIVE"

find "$INSTINCT_DIR" -name 'repeat-*.yaml' -exec mv {} "$ARCHIVE/" \; -print
find "$INSTINCT_DIR" -name 'workflow-*.yaml' -exec mv {} "$ARCHIVE/" \; -print

# Same for global instincts
find ~/.claude/cortex/instincts/global -name 'repeat-*.yaml' -exec mv {} "$ARCHIVE/" \; -print
find ~/.claude/cortex/instincts/global -name 'workflow-*.yaml' -exec mv {} "$ARCHIVE/" \; -print
```

Idempotente. Reversible (mover de vuelta desde archive si necesario).

### 4.15 PreCompact hook — HARDENING del hook existente (v7, 60 min)

**CORREGIDO post-AD round 3:** cortex YA TIENE `hooks/precompact.py` registrado en `install.sh:441-445` con timeout 8000ms. NO se crea un fichero nuevo. La tarea es **hardening** del existente:

**Cambios concretos:**
1. **`hooks/precompact.py`** — añadir al inicio:
   ```python
   if os.environ.get('CORTEX_OBSERVE_OFF') == '1' or os.environ.get('CORTEX_DETECTORS_OFF') == '1':
       sys.exit(0)  # kill switches honored
   ```
2. **`hooks/precompact.py`** — verificar que invoca `session-learner.js` con stdin redirigido a `/dev/null` Y exporta `CORTEX_SESSION_ID` desde `hookData.session_id` ANTES del spawn (no perdemos el contexto que el AD señaló)
3. **`hooks/precompact.py`** — wrap en `try/except` con `exit(0)` para garantizar fire-and-forget (nunca bloquea Claude Code aunque crashee)
4. **`tests/test_precompact.sh`** NEW (8 casos):
   - hook fires on PreCompact event (smoke)
   - flushes pending observations to observations.jsonl
   - respects 8s timeout (does not exceed wall-clock cap)
   - fire-and-forget: returns exit 0 even when learner is slow/hung
   - idempotent: no-op if no observations to flush
   - exits clean if learner crashes (exit 0 always)
   - `CORTEX_OBSERVE_OFF=1` → exits immediately, no learner spawn
   - `CORTEX_DETECTORS_OFF=1` → exits immediately, no learner spawn

**Why hardening, not new hook:** crear un segundo hook (`precompact-guard.sh`) duplicaría functionality y arriesgaría doble-fire. El hook actual ya está cableado por el installer; solo le falta kill-switch check + verificación de session-id propagation + test coverage.

**Why now:** real data loss vector confirmado por Sinapsis v4.5 (RFC explícita en su repo). Sin esto, v3.29 detector improvements se enmascaran por observations perdidas en sesiones largas.

### 4.16 Multi-session promotion gate (v7, 45 min)

**Source pattern:** Sinapsis `core/_instinct-activator.sh:43-63`.

**Problem solved:** A single very long session with repeated patterns can artificially boost confidence past the threshold and promote to law/global even though only ONE session of evidence exists.

**Implementación concreta (corregido post-AD round 3):**

```python
# hooks/lib/distill_engine.py
def _count_distinct_sessions(iid, tracking_data):
    """Read distinct session count from instinct-tracking.json.
    
    Defensive: handles missing file, malformed schema, missing 'sessions' field,
    duplicate or empty UUIDs. Returns 0 on any anomaly.
    """
    if not isinstance(tracking_data, dict):
        return 0
    entry = tracking_data.get(iid)
    if not isinstance(entry, dict):
        return 0
    sessions = entry.get('sessions')
    if not isinstance(sessions, list):
        return 0
    # Dedupe + filter empty/None values
    unique = {s for s in sessions if isinstance(s, str) and s.strip()}
    return len(unique)

# In auto_promote_to_law(), BEFORE conf>=0.95 + sustained>=14d check:
distinct_sessions = _count_distinct_sessions(inst['id'], tracking_data)
if distinct_sessions < 3:
    candidates.append({
        'id': inst['id'],
        'reason': f'distinct_sessions < 3 (currently {distinct_sessions})',
    })
    continue
```

**Source of `distinct_sessions`:** `~/.claude/cortex/instinct-tracking.json` already tracks `sessions: [<uuid>]` per instinct id, populated by `injector-engine.js:352-359` (deduped, cap of 20).

**Visibility (AD round 3 fix):** `/cx-status --pipeline` shows `"<id> · sessions 1/3 (need 2 more)"` para instincts bloqueados por este gate — operador SABE por qué un instinct de alta confianza no promueve.

**Grandfather clause (AD round 3 edge case fix):** instincts existentes con `confidence >= 0.95` AND missing `tracking_data[iid]` are auto-grandfathered to `distinct_sessions = 3` to avoid breaking pre-existing high-confidence laws.

**Test:** `test_distill_engine.sh` +3 cases:
- conf=0.95 + sustained=14d + distinct_sessions=2 → candidate (reason "distinct_sessions < 3")
- conf=0.95 + sustained=14d + distinct_sessions=3 → promotes to law
- conf=0.95 + missing tracking entry → grandfathered (promotes)

**Why now:** the v3.29 detector rewrites produce HUMAN-gated proposals. If we promote them to AUTO in v3.30 based on accept-rate alone (without session distribution), single-session noise can leak through. Adding this gate in v3.29 means v3.30 promotion is already protected.

### 4.14 Release v3.29.0

- Bump versión 3.28.9 → 3.29.0 en 4 ficheros
- CHANGELOG itemizado completo
- `docs/V3.27-GATES-CLOSED.md` → DELETE
- `docs/SPRINT-8-DETECTOR-OVERHAUL.md` (este doc) → **mantener** hasta v3.30
- `docs/GHOST-CX-VALIDATE-AUTO.md` → mantener para historia
- `docs/SINAPSIS-COMPARISON.md` → mantener si aporta
- CLAUDE.md "Active sprint" → "v3.29.0 shipped; medición 7d antes de v3.30"
- Tag v3.29.0 + PR a main

---

## 5. Plan v3.30.0 — Autopilot Real (post-medición 7d)

### 5.1 `analyze_engine.py` — Opción C confirmada

`hooks/lib/analyze_engine.py` no-op si no hay Opus 1M activo. Si lo hay, ejecuta la parte determinística (compresión observations, dedup, knowledge summary), escribe a `~/.claude/cortex/analyze-queue/`, dispara fallback `.learn-pending` si Opus no disponible.

### 5.2 Trigger auto-analyze

`session-start.py` step 3e: si `mtime(.last-auto-analyze) > 20h` AND obs nuevas >= 50 AND Opus 1M → ejecutar `analyze_engine.py`. Sino, escribir `.learn-pending`.

### 5.3 Promoción HUMAN → AUTO con gate estadístico + multi-session (v6 update)

Para cada detector reescrito en v3.29 (file-coupling, user-corrections, agent-subtypes):

```python
def can_promote_to_auto(detector_id):
    reviewed = count_proposals(source=detector_id, status='accepted' OR 'rejected')
    accepted = count_proposals(source=detector_id, status='accepted')
    distinct_sessions = count_distinct_sessions(source=detector_id)
    critical_rejections = count_proposals(
        source=detector_id, status='rejected',
        rejected_reason='security|breaking|injection'
    )
    return (
        reviewed >= 20 AND
        (accepted / reviewed) >= 0.70 AND
        distinct_sessions >= 3 AND     # ← NEW v6 (Sinapsis pattern)
        critical_rejections == 0
    )
```

The `distinct_sessions >= 3` clause prevents single-session noise (e.g. one long session generating 25 file-coupling proposals 24 of which are accepted by the operator out of fatigue) from triggering AUTO promotion.

Si pasa gate → mover domain a `VALIDATE_AUTO_DOMAINS`. Si no → mantener HUMAN-gated.

### 5.4 Sinapsis decision table (REEMPLAZA "REPLANTEAR")

Agente Sonnet read-only sobre `~/github/sinapsis-3.2/` con contrato JSON:

```json
{
  "architecture_summary": "string",
  "pipeline_design": "session-start | stop | cron | other",
  "detector_design": "how detectors emit signals",
  "automation_loop": "how knowledge flows automatically",
  "verdict": "identical | inspiring_patterns | superior_architecture | not_applicable"
}
```

| Verdict | Acción Sprint 8 |
|---------|-----------------|
| `identical` | Continuar v3.29 sin cambios |
| `inspiring_patterns` | Importar 1-2 patrones concretos en v3.30 (cherry-pick) |
| `superior_architecture` | **ABORT v3.29 + plan migración cortex → sinapsis** |
| `not_applicable` | Continuar v3.29 sin cambios |

Sinapsis spike en Día 0 (paralelo a arqueología ghost).

### 5.5 Release v3.30.0

Cuando los 4 anteriores estén OK + 7 días de medición sin regresión.

---

## 6. Decisiones del operador (confirmadas 2026-05-15)

| # | Decisión | Respuesta | Aplicado |
|---|----------|-----------|----------|
| 1 | Retire vs disable | **BORRAR** | §4.6 |
| 2 | Nombres kill switches | OK | §4.8 |
| 3 | Ghost: arqueología activa | **SÍ pre-ship** | §4.7 (Día 0) |
| 4 | HUMAN-gated 1 release antes de AUTO | SÍ | §3, §5.3 |
| 5 | `analyze_engine.py` opción | **C** (no-op si no Opus 1M) | §5.1 |
| 6 | Sinapsis cuándo | **Día 0 spike paralelo** | §5.4, §8 |

---

## 7. Risk register (revisado v5)

| Riesgo | Prob | Impact | Mitigación |
|--------|------|--------|------------|
| Retire de 2 detectores rompe tests | media | bajo | §4.6 + §4.11 cubren asserts de ausencia |
| File-coupling regex causa noise por matches inesperados | media | medio | Test E2E §4.11 con negative test; `scope: project` previene contamination |
| Ghost script reaparece silenciosamente | baja | alto | §4.7 guard NO whitelistea + pre-ship test §4.12 |
| Kill switches dejan state file mutación residual | media | medio | §4.8 spec explícita por fichero + test_kill_switches.sh |
| `analyze_engine.py` Opción C no-op deja queue eternamente pending | baja | bajo | `.learn-pending` visible en `/cx-status`; operator decisiones cuándo escalar a A o B |
| Operador abandona el proyecto si v3.29 no entrega valor visible | **media** | crítico | v3.29 entrega: (a) 0 noise post-install, (b) `/cx-status` limpio, (c) banner `[ACTION]` solo cuando hay algo accionable real, (d) tests acceptance gate prueba esto antes del tag |
| Sinapsis spike sin output útil | media | bajo | Time-boxed 30 min; verdict `not_applicable` es válido |

---

## 8. Sequencing v3.29.0 (Día 0 + 3 días)

| Día | Tareas | Output verificable |
|-----|--------|-------------------|
| **Día 0** (2-3h) | **Paralelo**: (a) Sinapsis spike Sonnet read-only → `docs/SINAPSIS-COMPARISON.md`; (b) Ghost arqueología §4.7 paso 1 → `docs/GHOST-CX-VALIDATE-AUTO.md` | 2 docs creados. Si Sinapsis verdict `superior_architecture` → ABORT Día 1 + escribir plan migración. Si no, seguir |
| **Día 1** (4h) | §4.1 dominios + §4.6 retire + §4.7 paso 2 guard + §4.13 limpieza huérfanos + tests asociados | distill_engine + tests verdes |
| **Día 2** (4-5h) | §4.2 file-coupling rewrite + §4.3 user-corrections + §4.4 agent-subtypes + §4.5 agent-patterns tune + §4.8 kill switches + tests asociados | Detectores reescritos en HUMAN-gated; switches funcionales |
| **Día 3** (5h) | §4.10 banner fix + §4.15 PreCompact hardening + §4.16 multi-session gate + §4.11 tests E2E + §4.12 acceptance gate (8 asserts) + §4.9 archive + §4.14 release | **378→390 tests PASS** (363 base + 15 new in §4.11 + 8 in test_precompact.sh + 3 in §4.16 + 1 grandfather test = 390), acceptance gate green, v3.29.0 PR + tag |

**Total: Día 0 + 3 días concentrados = ~16h.**

(v7 update: §4.15 reescrito como hardening del precompact.py existente, no creación nueva. §4.16 con reader defensivo + grandfather clause + visibility. §4.12 acceptance gate ampliado de 6 a 8 asserts. Test math corregido: 378 base+nuevos + 12 v7 = 390 total.)

Post-ship: 7 días observación silenciosa antes de planificar v3.30.

---

## 9. Verificación interna del plan v7 (auto-review pre-código)

Antes de empezar Día 0, checklist mental:

| Pregunta | Respuesta |
|----------|-----------|
| ¿Los 5 P0 de AD round 2 están cerrados con cambios concretos? | SÍ (§0 mapping table) |
| ¿El campo `condition` se evita? | SÍ (§4.2 usa regex en trigger directo; verificado contra `injector-engine.js:89`) |
| ¿Ghost guard ES el guard (no auto-autoriza)? | SÍ (§4.7 whitelist NO incluye `cx-validate-auto`) |
| ¿Banner [ACTION] dejará de molestar con human-gated? | SÍ (§4.10 cuenta solo AUTO_DOMAINS) |
| ¿Hay pre-ship gate que pruebe esto antes del tag? | SÍ (§4.12 con 6 asserts en sandbox) |
| ¿Hay test E2E que prueba el pipeline completo? | SÍ (§4.11 test_e2e_pipeline.sh) |
| ¿Detectores HUMAN-gated requieren validación humana en v3.29? | SÍ (§3 matrix + §5.3 promotion gate estadístico) |
| ¿Las decisiones del operador están reflejadas? | SÍ (§6 confirmation table) |
| ¿Sequencing realista? | SÍ (15h total, dividido en 4 ventanas concretas) |
| ¿Operador puede ignorar Cortex post-ship sin que reaparezca el problema? | SÍ — automatización existe (auto_validate, auto_distill, auto_evolve corren en SessionStart 1×/24h); detectores no emiten noise; banner solo accionable real |

**Veredicto v7 (post-AD round 3):** plan ironclad para v3.29.0. Los 2 P0 nuevos del AD round 3 (precompact.py existente + settings.template.json inexistente) resueltos como hardening. Los P1 (reader distinct_sessions defensivo, grandfather clause, visibility de sessions, acceptance gate expandido) aplicados. v3.30.0 sigue dependiendo de medición real post-v3.29.

---

## 10. Evolución del plan

- v1: 5 detectores + auto-analyze SessionStart. AD round 1 → 4 P0.
- v2/v3: detector matrix completa, auto-analyze diferido, kill switches, ghost guard.
- v4: 6 decisiones operador aplicadas, sequencing Día 0.
- v5: 5 P0 nuevos de AD round 2 cerrados. Runtime verification confirms `matchTarget` incluye tool input → file-coupling con regex puro funciona.
- v6: post-Día 0 (Sinapsis verdict `inspiring_patterns`, ghost archaeology confirma external non-reproducible). 2 patrones Sinapsis añadidos (PreCompact, multi-session gate).
- v7 (FINAL): AD round 3 detectó 2 P0 (precompact.py YA existe, settings.template.json NO existe). §4.15 reescrito como hardening del existente. §4.16 con reader defensivo + grandfather + visibility. Acceptance gate ampliado a 8 asserts. Test math corregido a 390.

**Día 0 COMPLETADO. Plan listo para Día 1.**
