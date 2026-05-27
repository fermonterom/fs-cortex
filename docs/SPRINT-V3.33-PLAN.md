# Sprint v3.33+ — Post-Sprint-9 Observation Window + Backlog

**Status:** DRAFT — created 2026-05-27 immediately after v3.32.0 ship.
**Author:** sesión post Sprint 9 PR2 (PR #44 review absorbed via 5
quick wins + 4 follow-up issues).
**Target release:** v3.33.0 (minor — exact alcance depende de la data
recogida durante la ventana de observación).
**Goal:** transformar las decisiones diferidas de Sprint 9 (§4.2/§4.3
autopilot) en código testeable + cerrar las 4 follow-ups del review +
canalizar la siguiente ola de mejoras a partir de datos reales en vez
de hipótesis.

---

## 0. Estado al inicio de Sprint v3.33

**Versión productiva:** v3.32.0 (tag `v3.32.0`, PR #44 merge pendiente
del operador en el momento de escribir este plan).

**Tags publicados desde v3.31.x:** v3.31.0 → v3.31.1 → **v3.31.2**
(Sprint 9 PR1) → **v3.32.0** (Sprint 9 PR2).

**Cortex en vivo (snapshot 2026-05-27):**
- 15 active laws cap (subido en v3.32.0 §4.5 — antes 12). Algoritmo
  de deprecación operativo pero NO invocado todavía (cohort joven).
- `~/.claude/cortex/log/auto-validate-skips.jsonl` activo desde el
  2026-05-26 (v3.31.2 §4.1.B). Cosechando data sin interpretar.
- `~/.claude/cortex/log/security-events.jsonl` activo desde v3.32.0
  §4.4. Vacío al inicio de la ventana.
- `.promoted-detectors.json` NO existe todavía (ningún source promovido
  manualmente vía `/cx-promote --auto` hasta la fecha).
- Sprint 8 invariantes intactos: 5 detectores live por defecto, 3
  HUMAN-gated (correction, coupling, agent-quality), ghost guard,
  3 kill switches, multi-session promotion gate con grandfather
  narrow (v3.31.2 §4.1.A).

**Issues PR #44 review (follow-up):**
- [#45](https://github.com/fermonterom/fs-cortex/issues/45)
  LOCK_FILE concurrency wrap.
- [#46](https://github.com/fermonterom/fs-cortex/issues/46)
  Regression test para schema v2 futuro.
- [#47](https://github.com/fermonterom/fs-cortex/issues/47)
  chmod 0o600 en logs nuevos.
- [#48](https://github.com/fermonterom/fs-cortex/issues/48)
  Trust-boundary doc en cx-promote / cx-distill.

**Lo que NO se toca (invariantes Sprint 8 + Sprint 9):**
- Detectores activos (no detectorSignalChange).
- Sinapsis context.md format (v3.31.0).
- 3 kill switches (`CORTEX_OBSERVE_OFF`, `CORTEX_DETECTORS_OFF`,
  `CORTEX_AUTODISTILL_OFF`).
- Ghost guard, multi-session promotion gate, pre-push acceptance gate
  (`test_v332_acceptance.sh`).
- Promotion gate HUMAN→AUTO (v3.32.0 §4.4) — solo se extiende, no se
  rediseña.
- Laws cap 15 + deprecation policy (v3.32.0 §4.5) — solo se hardena.

---

## 1. Ventana de observación silenciosa (7 días)

**Período:** 2026-05-27 → 2026-06-03 (7 días naturales).
**Trabajo activo durante la ventana:** NINGÚN cambio a engine /
detectores / promotion gate / laws cap. Solo permitido:
- Documentación (este plan, FEATURES.md, runbooks).
- Tests adicionales sin tocar código de producción.
- Issues / labels / project board grooming.
- Lecturas exploratorias de los logs.

### 1.a Preguntas a contestar con datos al cerrar la ventana

| # | Pregunta | Fuente de datos | Decisión que desbloquea |
|---|----------|-----------------|--------------------------|
| Q1 | ¿`can_promote_to_auto` recoge señal real para los 3 detectores HUMAN-gated (correction / coupling / agent-quality)? | `proposals-history.jsonl` + `can_promote_to_auto(source)` por cada source. Buscar `reviewed_count >= 10` (visibility tier). | Si ≥ 1 detector llega a 10/20 → sigue siendo válido el diseño de gate. Si ninguno → revisar thresholds o frecuencia de `/cx-validate`. |
| Q2 | ¿Algún detector llega a 20/20 + accept_rate ≥ 70 % + 3 sessions + 0 critical? | Mismo. Filtrar por `eligible == True`. | Si SÍ → ejecutar `/cx-promote --auto X --confirm` manualmente y observar 48 h adicionales antes de declarar el ciclo cerrado. |
| Q3 | ¿La deprecation policy se invoca? ¿Cuántas veces dice `auto-distill-candidates.md` "saturated; would deprecate X"? | `auto-distill-candidates.md` + grep. | Si 0 invocaciones → el cap de 15 es suficiente para el flujo actual. Si > 0 → validar manualmente que el candidato propuesto es razonable. |
| Q4 | ¿Qué skip-reasons dominan los AUTO pending estancados (los 42-44 reportados en el banner SessionStart)? | `auto-validate-skips.jsonl` → agregación por `skip_breakdown` key. | Si dominante = `low-confidence` → subir `VALIDATE_MIN_CONF` o reentrenar detectores. Si dominante = `already-instinct` → dedup en el emitter. Si `needs-human-judgment` → revisar si `rejection_category` ayudaría. |
| Q5 | ¿`security-events.jsonl` registra eventos? | Tail del fichero. | Si vacío → marker fail-closed nunca disparó (esperado). Si > 0 → investigar causa raíz, posible bug en writer. |
| Q6 | ¿El `.promoted-detectors.json` se ha creado vía `/cx-promote --auto`? Si no, ¿por qué? | Existencia del fichero + entrevista al operador. | Si NO se ha usado → la UX puede estar siendo demasiado opaca; añadir banner SessionStart "X detectores listos para promoción". |

### 1.b Cierre de ventana

Día 8 (2026-06-04): script `scripts/v3.33-window-report.sh` (a crear,
ver §3 P0.b) genera un informe JSON con las 6 respuestas y se commitea
en `docs/SPRINT-V3.33-WINDOW-REPORT.md`. Ese informe es el input para
el sprint planning.

---

## 2. Diagnóstico técnico (heredado pre-ventana)

### 2.1 Items diferidos de Sprint 9 (AD P0-2/P0-3 absorbidos)

| § Sprint 9 | Item | Estado | Acción v3.33 |
|------------|------|--------|--------------|
| §4.2 | `hooks/lib/analyze_engine.py` (queue producer) | NO existe — diferido | **Redesign** con env var explícita (ver §3 P0.a). |
| §4.3 | Trigger auto-analyze en `session-start.py` step 3e | NO existe — diferido | Mismo: precondición = §4.2 reescrito + spec del consumer. |
| §4.6 | Sprint 8/9 docs deletion | DIFERIDO | Borrar al cierre del sprint (§3 P6). |

### 2.2 Items del review de PR #44 (resumen rápido)

Detalle completo en los issues #45-#48. Resumen:

| # | Severidad | Resumen | Trabajo |
|---|-----------|---------|---------|
| #45 | low | 2 paths read-modify-write sin LOCK_FILE. | Wrap con `fcntl.flock` (pattern v3.21.0). 3 tests. |
| #46 | low | Sin regression test para schema v2 futuro. | Añadir 1 test. |
| #47 | low | Logs nuevos heredan umask del padre. | `os.chmod(path, 0o600)` + audit `_atomic_write` callsites. 2 tests. |
| #48 | low | Trust boundary implícita en cx-promote/cx-distill. | Doc-only. Sección "Trust boundary" en ambos comandos. |

---

## 3. Backlog ordenado v3.33+

Cada item lleva prioridad (P0-P6), estimación, dependencias.

### P0 — Resume §4.2/§4.3 autopilot (Sprint 9 deferred)

**Trigger:** ventana de observación cerrada + Q1-Q6 contestadas.
**Estimación:** ~8 h en 2 días.
**Dependencias:** ninguna técnica; sí decisión operador post-ventana.

#### P0.a — Opus 1M detection vía env var explícita

- Nueva env var `CORTEX_OPUS_1M=1` que el operador configura una vez en
  `.zshrc` (o equivalente).
- `analyze_engine.py:_is_opus_1m_active()` lee la env var, NO infiere
  del hook context (que era el camino bloqueado por AD P0-3).
- Test: 2 casos (var set → True; var unset → False).
- Doc: `docs/SETUP-OPUS-1M.md` con copy-paste para `.zshrc` /
  `~/.bash_profile` / Windows env vars.

#### P0.b — `analyze_engine.py` queue producer

- Función `enqueue_analyze_request(reason: str)` que escribe a
  `~/.claude/cortex/.analyze-queue.jsonl`.
- Trigger: invocado desde `session-start.py` step 3e cuando
  `_is_opus_1m_active()` AND `_should_auto_analyze()` (cadencia 20h
  fixed + 50 obs floor, AD-validated en Sprint 8 D2).
- Spec del consumer DEBE estar definida antes (P0.c).
- Test: 3 casos (enqueue válido, dedup en mismo session, queue limit).

#### P0.c — Spec del consumer (`/cx-analyze` queue draining)

- `/cx-analyze` checkea `.analyze-queue.jsonl` al inicio; si hay
  entries pendientes, dropea las > 7 días (stale), procesa las
  restantes en orden FIFO.
- Test e2e: queue con 3 entries → 3 análisis seriales con resultado
  consolidado.

#### P0.d — `session-start.py` step 3e trigger

- Después de `inject_context_bridge`, antes de `inject_eod_resume`:
  llamar `analyze_engine.maybe_enqueue()`.
- Test: si Opus 1M off → no enqueue. Si on + cadencia cumple →
  enqueue + log.

#### P0.e — Reporte semanal

- `scripts/v3.33-window-report.sh` (creado al cierre de Sprint v3.33,
  reutilizable para v3.34+) que agrega `auto-validate-skips.jsonl`,
  `security-events.jsonl`, conteo de proposals, conteo de promotions
  HUMAN→AUTO. Output JSON + Markdown para commit.

### P1 — PR #44 review follow-ups

**Trigger:** post-merge de v3.32.0 (PR #44).
**Estimación:** ~4 h total.

- **P1.a** Issue [#45](https://github.com/fermonterom/fs-cortex/issues/45)
  LOCK_FILE concurrency. ~2 h.
- **P1.b** Issue [#46](https://github.com/fermonterom/fs-cortex/issues/46)
  Regression schema v2. ~30 min.
- **P1.c** Issue [#47](https://github.com/fermonterom/fs-cortex/issues/47)
  chmod 0o600 + audit. ~1 h.
- **P1.d** Issue [#48](https://github.com/fermonterom/fs-cortex/issues/48)
  Trust boundary doc. ~30 min.

### P2 — AUTO pending root cause investigation

**Trigger:** Q4 de la ventana de observación contestada con datos.
**Estimación:** ~3 h.

- Leer `auto-validate-skips.jsonl` con un agregador (Python script).
- Identificar skip reason dominante (esperado: `low-confidence` o
  `already-instinct`).
- Fix dirigido + test que demuestra el unblock.

### P3 — `/cx-evolve` automation

**Trigger:** 5+ instincts maduros del mismo domain disponibles.
**Estimación:** ~4 h.

- Extender `auto_evolve_detect` con thresholds finos.
- Generar skill draft automático cuando se cumplen.
- Test: cluster sintético → skill draft válido.

### P4 — Cross-project promotion gate

**Trigger:** instinct project-scoped detectado en ≥ 2 proyectos no-fs.
**Estimación:** ~3 h.

- Project-scoped instincts de fs-cortex que también aparezcan en
  fersora / LinkedIn → autopromote a global.
- Extiende el flujo existente de `/cx-promote` (NO el sub-mode
  `--auto`, que es otra cosa).
- Test e2e: 2 sandboxes con mismo instinct → promovido a global.

### P5 — Telemetry export

**Trigger:** opcional, baja prioridad.
**Estimación:** ~6 h.

- Panel HTML extendido con cohort analysis:
  - Instincts firing rate por proyecto.
  - Decay velocity.
  - Ratio histórico useful/noise.
- Sirve para futuras decisiones de optimización.

### P6 — Sprint 8/9 docs cleanup (instinct `gotcha-sprint-doc-cleanup-after-ship`)

**Trigger:** último commit del Sprint v3.33.
**Estimación:** ~15 min.

- Borrar:
  - `docs/SPRINT-8-DETECTOR-OVERHAUL.md`
  - `docs/GHOST-CX-VALIDATE-AUTO.md`
  - `docs/SINAPSIS-COMPARISON.md`
  - `docs/SPRINT-9-AUTOPILOT.md`
  - `docs/SPRINT-V3.33-PLAN.md` (este propio doc)
- Eliminar el whitelist correspondiente en `.gitignore`.
- Pre-condición: `docs/SPRINT-V3.33-WINDOW-REPORT.md` ya commiteado
  con las 6 respuestas — esa es la memoria persistente del ciclo,
  no este plan vivo.

---

## 4. Sequencing v3.33.0

| Día | Bloque | Trabajo | Output |
|-----|--------|---------|--------|
| 1-7 | Observation window | Read-only. Cosechar logs. | `docs/SPRINT-V3.33-WINDOW-REPORT.md` |
| 8 | Sprint planning | Contestar Q1-Q6 con datos. Confirmar / re-ordenar P0-P6. | Updated plan + tags. |
| 9-10 | PR1 v3.32.1 (patch) | P1 follow-ups (#45-#48). ~4 h. | Tag `v3.32.1`. |
| 11-13 | PR2 v3.33.0 (minor) | P0 autopilot + selección de P2-P5 según datos. ~8-16 h. | Tag `v3.33.0`. |
| 14 | Cierre | P6 docs cleanup. | Sprint v3.33 retrospective. |

**Sub-decisión D1 (Día 8 sprint planning):** ¿partir v3.33 en 2 PRs
(v3.32.1 patch + v3.33.0 minor) o 1 PR único (v3.33.0)? Decisión
depende de cuántos issues P0-P5 entran.

---

## 5. Risk register

| Riesgo | Prob | Impact | Mitigación |
|--------|------|--------|------------|
| Ningún detector llega a 10/20 reviewed en 7 días → P0 sigue siendo difícil de evaluar | media | bajo | Extender ventana 7d más o reducir thresholds para visibility. |
| `CORTEX_OPUS_1M=1` env var olvidado por el operador en máquina nueva | media | bajo | `INSTALACION.md` + bin/cortex-doctor check; banner SessionStart si no detectado en sesión Opus reciente. |
| Sprint v3.33 acumula scope creep como Sprint 9 | media | medio | Priorizar P0 + P1 estrictamente. P2-P5 son explícitamente "según datos". |
| `analyze_engine.py` queue se llena sin consumer (orphan markers) | baja | medio | TTL 7d explícito en queue reader + log de drops. |
| AD round 2 emerge con nuevos P0 | baja | bajo | Plan ya prevé Día 8 como buffer; round 2 opcional sobre el plan que salga ese día. |

---

## 6. Sprint 9 retrospective (apuntes para Día 14)

Material en bruto a procesar al cierre. NO es la retro final, solo
notas para no perder contexto.

### Lo que funcionó

- **AD Codex GPT-5.5 round 1 antes de PR1** evitó 4 P0 + 7 P1 que
  hubieran salido en producción. Validar pre-implementación con
  modelo distinto sigue siendo la mejor inversión por hora de Sprint.
- **E2E gate `test_v332_acceptance.sh`** cazó el bug del segundo
  `needs-human-judgment` skip que los 8 + 6 unit tests no vieron.
  Concreta validación del instinct
  `gotcha-ad-por-fase-no-sustituye-e2e`.
- **2 PRs (PR1 cleanup + PR2 features)** mantuvo el review manejable.
  El operador pudo aprobar v3.31.2 sin estar bloqueado por v3.32.0.
- **Quick wins después del review** (5 inline + 4 follow-up issues)
  cerraron los gaps obvios sin retrasar v3.32.0.

### Lo que mejorar

- **`git add` falló silenciosamente** en el commit del rename del
  test_v329 (commit `86f61c7` solo registró el rename, contenido en
  unstaged; corregido en `3ca1b62`). Trigger:
  `tests/test_v329_acceptance.sh` (que ya no existía tras `git mv`)
  pasado como pathspec. Lección: separar `git mv` de los edits
  posteriores en commits distintos OR releer status después de cada
  `git add`.
- **Read-before-edit reset** entre turnos de sistema-reminder. Tuve
  que releer ficheros varias veces en sesión cuando ya los había
  leído. Lección: hooks `read-before-edit` son advisory pero el
  harness sí olvida el cache cuando hay mucho tool use.
- **Baseline test count "433" del plan estaba TBD** y resultó ser 447
  → 472 → 476 real. La AD P2-1 ya lo advertía. Lección útil:
  *medir* el baseline antes de citar números en planes.

### Acciones derivadas para v3.33+

- Cuando rename + edit: 2 commits separados.
- Verificar `git status` después de cada `git add` grupo.
- Plan v3.33 cita números REALES (extraidos del baseline) en vez de
  números heredados del plan original.

---

## 7. Evolución del plan

- **DRAFT (2026-05-27 mañana):** post-merge de v3.32.0 (pendiente),
  scope inicial inspirado en Sprint 9 §5 (futuros candidatos) +
  follow-ups del review de PR #44.

---

**Plan v3.33+ DRAFT — observación inicia 2026-05-27, planning ejecuta
2026-06-04 con datos reales.**
