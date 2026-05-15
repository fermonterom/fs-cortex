# Sprint 8 — Detector Overhaul + Sprint 5/v3.27 Gate Closure

**Status:** ⏳ PLAN (no code changes yet — awaits user OK)
**Author:** sesión de diagnóstico 2026-05-14 (3 agentes Sonnet paralelos)
**Estimated effort:** v3.28 release in ~1 day, Sprint 8 in ~3 days

---

## 1. Resumen ejecutivo

Cortex tiene **TRES sistemas rotos** que producen entre el 90% y el 100% de ruido. No es problema de threshold de confidence — son **bugs estructurales** en el wiring entre los detectores, el sistema de dominios, y la métrica del gate.

| Sistema | Estado | Tipo de bug | Confianza diagnóstico |
|---------|--------|-------------|------------------------|
| Gate 1 (impact_log.py) | métrica no medible | métrica filtra `source!=agent`, pero el único emisor escribe `source=agent` | alta |
| Detectores session-learner | 3 bugs estructurales | dominios huérfanos + trigger malformado + acción no accionable | alta |
| cx-validate-auto pipeline | script fantasma | bulk-rejecta proposals que `distill_engine` HABRÍA aceptado | media (origen del script sin localizar) |

**Lo que SÍ funciona** y mantenemos:
- ✅ Reflexes (Gate 2: trío bash con ratios 14×/4×/20×)
- ✅ TimeOfDay productivity tracking (Gate C)
- ✅ CrossDayBoost (Gate D: 4380 entries, 194 boosts)
- ✅ `detectErrorResolutions` (único detector bien diseñado)
- ✅ Laws + instincts manuales + injector

---

## 2. Tres problemas reales

### 2.1 Gate 1 (Sprint 5) — métrica estructural rota

**Hallazgo (agente debugger, `impact_log.py:329, 386-392` + `session-learner.js:1549-1555`):**

Cortex tiene **dos sistemas paralelos** de contabilidad de feedback:
1. `reflexes.json` — `usefulCount`/`noiseCount` (lifetime totals incrementados por evaluador)
2. `impact.jsonl` — append-only funnel log con eventos `feedback`

Cada fire de reflex con evaluador `tool-substitution` o `error-monitor` escribe AMBOS, pero:
- `reflexes.json` incrementa contador raw
- `impact.jsonl` añade evento con `"source": "agent"` (hard-coded en `session-learner.js:1553`)

Gate 1 lee `useful_ratio_user` (en `impact_log.py:386-392`), que SOLO cuenta eventos con `source != "agent"`. Como **0 reflex events tienen `source=user`**, el ratio siempre es 0/0.

La skill `cx-feedback-auto` confirma esto: "Agent self-rating on tool-choice reflexes — emits feedback with **source=agent**". No existe ningún path que emita reflex feedback con `source=user`.

**Fix recomendado:**
- (a) Cambiar `gate_recommendation` en `impact_log.py:386` → usar agregado (`useful_ratio` / `health_ratio`) en lugar de `_user`. Bajo riesgo, dos cambios de campo.
- (b) Hacer que `correlateReflexFeedback` en `session-learner.js:1295+` emita también un evento `follow` con `source=user` (riesgo medio, doble entrada).

**Decisión:** opción (a). Más simple. Justificado: para reflexes (tool-substitution / error-monitor), la evaluación es objetiva — el agente self-rate sobre evidencia clara, no es opinión. No necesita validación humana.

---

### 2.2 Detectores session-learner — 3 bugs estructurales

**Auditoría agente reviewer (`session-learner.js` 1765 líneas, 9 detectores):**

| Detector | Líneas | Estado | Bug |
|----------|--------|--------|-----|
| `detectErrorResolutions` | 241-303 | ✅ KEEP | (ninguno — único bien diseñado) |
| `detectRepetitions` | 318-355 | 🔴 DISABLE | conf=0.30 estructuralmente abajo del floor 0.50; action descriptivo |
| `detectUserCorrections` | 382-419 | 🟡 FIX | conf=0.40; domain `user-preference` human-gated; action no directivo |
| `detectWorkflowChains` | 425-460 | 🔴 DISABLE | trigger pierde secuencia (solo primer tool); action descriptivo |
| `detectAgentPatterns` | 466-516 | 🟢 TUNE | conf inicial 0.40; subir min items a 4 → conf 0.55 |
| `detectAgentSubtypes` | 522-585 | 🟡 FIX | **domain `agent-quality` no existe en NINGÚN whitelist** → fallthrough silencioso |
| `detectFileCoupling` | 587-642 | 🟡 FIX | **trigger `Edit\|f1\|f2` es regex alternation roto** + domain `coupling` huérfano |
| `detectTimeOfDayPatterns` | 644-750 | ✅ KEEP | (infra-only, no emite proposals) |
| `detectCommandUsage` | 756-785 | ✅ KEEP | (infra-only) |

**Tres bugs críticos confirmados:**

1. **`session-learner.js:628`** — `trigger: 'Edit|baseA|baseB'` es regex alternation. Matchea LITERAL "Edit", "baseA" o "baseB" independientemente. El coupling se pierde. **Fix:** `trigger: 'Edit'` + nuevo campo `condition: '(?:baseA|baseB)'`.

2. **`session-learner.js:576 + distill_engine.py:84`** — domain `agent-quality` (de `detectAgentSubtypes`) no existe en `VALIDATE_AUTO_DOMAINS` ni `VALIDATE_HUMAN_DOMAINS`. Cae en el catch-all `needs-human-judgment` del distill_engine.py:854. **Bug introducido en v3.27.0** — domain nunca registrado en engine.

3. **`session-learner.js:633 + distill_engine.py:84`** — domain `coupling` (de `detectFileCoupling`) mismo bug huérfano.

**Triggers/actions inválidos (vista de pájaro):**
- Triggers con `|` que se interpretan como regex OR en vez de field separator
- Actions que son estadísticas ("Called 8x with similar input") en lugar de imperativos ("Before editing X, check Y")
- Conf=0.30-0.45 sub-floor → nunca llegan a auto-accept y nunca a `/cx-validate`

---

### 2.3 cx-validate-auto — script fantasma

**Hallazgo (agente reviewer, query a proposals.json):**

648 proposals tienen `rejected_by: "cx-validate-auto"` y `rejected_at: 2026-05-05`, con razón `"session-learner noise: frequency counter / repetition"`.

El string `cx-validate-auto` **NO existe en el código del repo**. No hay skill llamada así (la skill `cx-feedback-auto` existe pero hace otra cosa). El instalador no lo escribe. El distill_engine no lo escribe.

**Conclusión:** algún script externo o ya borrado ejecutó un bulk-reject el 2026-05-05. De los 648 rechazos, 9 son `agent-evolution` con conf 0.55-0.70 que **distill_engine HABRÍA aceptado**, pero como ya están en `status=rejected` quedan invisibles al pipeline.

**Fix:**
- Identificar el origen del script (mirar `~/.claude/commands/`, `~/.claude/agents/`, plugins instalados)
- Si es residual de versión antigua: borrar
- Si es legítimo: añadir guard `if domain in VALIDATE_AUTO_DOMAINS and conf >= 0.50: skip` antes de aplicar la heurística de ruido

---

## 3. Plan v3.28 — Patch inmediato (1 día)

Objetivo: parar la sangría de ruido y cerrar los gates. NO refactor profundo.

### 3.1 Cerrar Sprint 5
- Cambiar `gate_recommendation` en `hooks/lib/impact_log.py:386-392` para usar `useful_ratio`/`health_ratio` (agregado, no `_user`). Test: re-correr Gate 1 → PASS.
- Borrar `docs/SPRINT-5-PENDING-GATES.md`
- Quitar referencia de `CLAUDE.md` ("Pending validation" sección)
- CHANGELOG: "Closed Sprint 5 gates — Gate 1 metric now uses aggregate ratio; Gate 2 was already passing at v3.23.4."

### 3.2 Disable detectores ruidosos (env-var gate)
- Nuevo flag `CORTEX_LEGACY_DETECTORS=1` (default `0` = disabled)
- Gate en `hooks/session-learner.js` antes de las llamadas a:
  - `detectRepetitions`
  - `detectWorkflowChains`
  - `detectUserCorrections`
  - `detectFileCoupling`
  - `detectAgentSubtypes`
- Mantener activos:
  - `detectErrorResolutions` (único KEEP)
  - `detectAgentPatterns` (con bump min items 3→4)
  - `detectTimeOfDayPatterns` (infra)
  - `detectCommandUsage` (infra)

### 3.3 Cerrar v3.27 gates parcialmente
- Gate A (detectAgentSubtypes): cerrar como **WONT-FIX-IN-V3.27** — disable detrás del flag. Si Sprint 8 fixa el domain orphan, se reabre.
- Gate B (detectFileCoupling): mismo cierre.
- Gate C: ya PASS — documentar.
- Gate D: ya PASS — documentar.
- Gate E: NA — la baja accept rate era síntoma de los detectores rotos.

### 3.4 Clean state
- Bulk-rechazar las 197 pending de fs-vault con razón `v3.28-detector-disabled`. Justificación: vienen de detectores ahora-disabled.
- Verificar `cx-validate-auto` no existe en `~/.claude/commands/` ni en plugins.
- Renombrar `docs/V3.27-DETECTOR-GATES.md` → `docs/V3.27-GATES-CLOSED.md` con notas de cierre.

### 3.5 Tests v3.28
- `tests/test_impact.sh` — actualizar caso de Gate 1 para nueva métrica
- `tests/test_session_learner.sh` — añadir caso "CORTEX_LEGACY_DETECTORS=0 skips disabled detectors"
- `tests/test_session_learner.sh` — verificar que `detectAgentPatterns` con 4 items emite conf=0.55

### 3.6 Release v3.28
- `install.sh`, `install.ps1`, `CHANGELOG.md`, `docs/FEATURES.md` bump a 3.28.0
- Commit: `feat(detectors): gate noisy detectors behind CORTEX_LEGACY_DETECTORS flag`
- Tag `v3.28.0`

---

## 4. Plan Sprint 8 — Fix profundo (3 días)

Objetivo: rehabilitar los detectores fixables con triggers/actions correctos.

### 4.1 Registrar dominios huérfanos
**File:** `hooks/lib/distill_engine.py:84-85`
- Añadir `coupling` y `agent-quality` a `VALIDATE_AUTO_DOMAINS` (con conf threshold 0.55)
- Test: proposal con domain=`coupling` y conf=0.55 → auto-accept

### 4.2 Fix `detectFileCoupling` (trigger format)
**File:** `hooks/session-learner.js:628`

Cambio actual:
```js
trigger: `Edit|${baseA}|${baseB}`,
```

Cambio propuesto:
```js
trigger: 'Edit',
condition: `(?:${escapeRegex(baseA)}|${escapeRegex(baseB)})`,
```

Y subir conf de 0.40 a 0.55. Action: cambiar de descriptivo a directivo:
```
"When editing X, also check Y — they have been coupled in N+ sessions."
```

### 4.3 Fix `detectUserCorrections`
**File:** `hooks/session-learner.js:382-419`
- Cambiar domain de `user-preference` a `gotcha`
- Subir conf de 0.40 a 0.55
- Reescribir action:
```
"Before editing X, review previous edit history — corrected 3+ times. Pattern likely needs deeper attention."
```

### 4.4 Fix `detectAgentSubtypes`
**File:** `hooks/session-learner.js:546`
- Subir conf de 0.45 a 0.50 (clears auto-validate floor)
- Domain ya está fixed en 4.1

### 4.5 Tune `detectAgentPatterns`
**File:** `hooks/session-learner.js:508`
- Subir min items de 3 a 4 → conf=0.55 en lugar de 0.40

### 4.6 Investigar y restringir `cx-validate-auto`
- Buscar fuente del script (residual install? script externo? plugin?)
- Si encontrado: añadir guard de domain whitelist
- Si no encontrado: limpiar metadata stale y documentar

### 4.7 Tests Sprint 8
- `tests/test_session_learner.sh`: añadir 5 tests (uno por detector fixado)
- `tests/test_distill_engine.sh`: añadir 2 tests para `coupling` y `agent-quality` domains
- `tests/test_impact.sh`: test de fix Gate 1 con la métrica nueva

### 4.8 Release v3.29 (Sprint 8 closure)
- Bump versión
- CHANGELOG: itemizar los 5 detector fixes
- Documentar criterios de éxito (ver §5)

---

## 5. Criterios de éxito post-Sprint 8

| Métrica | Hoy | Objetivo post-v3.29 |
|---------|-----|---------------------|
| Auto-accept rate (whitelist domains) | ~5% | ≥60% |
| `/cx-validate` queue size | 197 | ≤30 |
| Detector rejection rate global | 90-98% | ≤30% |
| Gate 1 status | PENDING (no medible) | PASS (medible y verde) |
| Reflexes Gate 2 status | PASS | PASS (sin cambio) |
| Reflexes auto-disable triggered | nunca | si noise>3, sí |
| Sprint 5 doc | abierto | borrado |
| V3.27 doc | abierto | renombrado a CLOSED |

---

## 6. Decisiones que requieren OK del operador

Estas decisiones NO se ejecutan hasta OK explícito:

1. **¿Disable `detectUserCorrections` también en v3.28?** Pros: 162 proposals todas rechazadas. Contras: signal real (file corregido N veces). Mi recomendación: SÍ disable en v3.28, fixar en Sprint 8.
2. **¿Bulk-rechazar las 197 pending de fs-vault con `v3.28-detector-disabled`?** Mi recomendación: SÍ. Limpia el queue, deja clean slate.
3. **¿Buscar `cx-validate-auto` ahora (v3.28) o en Sprint 8?** Mi recomendación: Sprint 8 (es debugging profundo, no urgente).
4. **¿Splitear Sprint 8 en sub-releases (4.1+4.2 → v3.29, resto → v3.30)?** Mi recomendación: NO, mejor un solo release v3.29 atómico.

---

## 7. Risk register

| Riesgo | Prob | Impact | Mitigación |
|--------|------|--------|------------|
| Disable de detectores rompe tests existentes | media | bajo | Tests en sandbox `mktemp -d` antes de commit |
| Métrica Gate 1 nueva da PASS falso | baja | medio | Validar con datos reales (60/3 ratio confirma señal) |
| `cx-validate-auto` re-aparece y rompe v3.28 | baja | alto | Audit antes de v3.28 release; documentar en gotchas |
| `detectAgentPatterns` tune (3→4) reduce signal demasiado | baja | bajo | Reversible vía env-var en v3.30 si hace falta |

---

## 8. Referencias

- Diagnóstico completo: 3 reportes agentes Sonnet en sesión 2026-05-14
- Files modificados (preview):
  - `hooks/lib/impact_log.py:386-392` (Gate 1 fix)
  - `hooks/session-learner.js` (5 detector changes)
  - `hooks/lib/distill_engine.py:84-85` (domain whitelist)
- Cerrar al final de Sprint 8:
  - `docs/SPRINT-5-PENDING-GATES.md` → DELETE
  - `docs/V3.27-DETECTOR-GATES.md` → rename to `V3.27-GATES-CLOSED.md`
  - `docs/SPRINT-8-DETECTOR-OVERHAUL.md` → DELETE (este fichero)
- CLAUDE.md `## Pending validation` → quitar referencias
