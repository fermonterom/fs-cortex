# Auditoría Cortex — 2026-07-02

Auditoría exhaustiva multi-agente (Workflow `/cortex-audit`, 35 agentes: 7 auditores read-only por dimensión + verificación adversarial 1:1 por hallazgo). Precedente: [`audit-cortex-2026-06-10.md`](audit-cortex-2026-06-10.md).

## Resumen ejecutivo

**Veredicto: deuda técnica seria, rozando crítico en la capa de instincts.** El motor de leyes y el pipeline de aprendizaje siguen operativos, pero un tramo relevante de los instincts activos inyectaba contenido ya invalidado o inútil, y esto se reprodujo en vivo durante la propia auditoría.

25 hallazgos brutos, 25 confirmados por verificación adversarial, 0 refutados. Severidad: P0: 0 · P1: 12 · P2: 9 · P3: 4.

## Inventario (recon)

- Versión: 3.38.2
- Leyes: 12 · Instincts activos: 98 (86 global + ~209 por proyecto antes de la limpieza de hoy)
- Proposals: 6 pending / 6 total
- Observations: 40.929 · `.bak` acumulados: 0
- Tamaño total: 163M (sin bloat de backups; grueso en logs append-only: `impact.jsonl` 16.2M, `observations.jsonl` 2.9M, `cross-day-tracker.jsonl` 1.9M, `proposals-history.jsonl` 1.9M)

## Top 5 riesgos

1. **Zombie instincts** — instincts activos correspondientes a proposals ya *rechazadas* en `/cx-validate` seguían con `.yaml` vivo e inyectando (uno se disparó durante la propia auditoría). El hallazgo original estimaba 128/298 (25%); la reconciliación real contra `proposals-history.jsonl` (último estado por id) dio **27 casos confirmados** (12 en `instincts/global/`, 15 en `instincts/projects/*/instincts/`) — el verificador adversarial ya había marcado la cifra original como inflada. **Corregido hoy**: los 27 se archivaron (no se borraron) con sufijo `.rejected-20260702.yaml`.
2. **Detector de errores roto** (`session-learner.js` / `observe.py`) — sigue confundiendo output normal (grep, npm, codex CLI) con fallos reales. Bug ya señalado y "corregido" el 2026-06-26; sigue generando proposals nuevas idénticas (`gotcha-Bash-12356f70`, `gotcha-Bash-eb585035`, ambas pending). **Pendiente de fix de código** — ver sección Follow-ups.
3. **9 triggers degenerados** (`Tool|patrón` interpretado como alternación, no como secuencia) casaban el 100% de las llamadas de esa tool. Root cause documentado en `session-learner.js:688-696` para otro detector, nunca aplicado retroactivamente a estos 9. **Corregido hoy**: los 9 triggers reescritos a `Tool.*patrón` y validados con PyYAML + node regex.
4. **Dedup por domain oculta candidatos** — el injector solo deja pasar 1 instinct por `domain` (`seenDomains`); "gotcha" (28%) y "error-recovery" (16%) acaparan los slots, silenciando otros de menor confianza aunque su trigger sea cierto. **Pendiente de fix de código.**
5. **Ley corrupta por truncado ciego a 40 caracteres** — `fersora-inbox-staging-only-not-final.txt` tenía el trigger cortado con paréntesis sin cerrar. Además `auto_promote_to_law` nunca archiva el instinct fuente tras promover a ley (mismo conocimiento inyectado dos veces cada sesión, "candidato duplicado" re-logueado 18 días seguidos sin resolver). **Corregido hoy**: ley reescrita en lenguaje natural + los 2 instincts fuente ya promovidos (`fersora-inbox-staging-only-not-final`, `read-instructions-before-executing`) archivados con sufijo `.promoted-to-law-20260702.yaml`.

## Hallazgos confirmados por dimensión

### Laws
- Ley con regex truncado e ilegible (P1) — **corregido hoy**.
- `auto_promote_to_law` no archiva el instinct fuente (P1) — **mitigado hoy** (archivado manual de los 2 casos vivos); fix de código pendiente.
- Solapamiento semántico ley `loop-reorient` / instinct `gotcha-test-fix-rerun-loop` (P2) — pendiente.
- Leyes multilínea (`advisor-escalation.txt`, `delegate-by-model-routing.txt`) solo inyectan la primera línea en SessionStart, el resto nunca llega automáticamente (P2) — pendiente, requiere decisión de convención.

### Instincts
- 14 instincts `gotcha-<Tool>-<hash>` con blobs JSON crudos no generalizables, triggers auto-referenciales (P1) — pendiente de fix de código (guard hollow + TRIGGER_STOPWORDS).
- Dedup por domain colapsa 44% de instincts en 2 cubos (P1) — pendiente.
- Backlog de promoción a ley estancado 6+ semanas, 35 instincts con `at_law_threshold_since` (P2) — pendiente, candidato a `/cx-distill`.
- 3 instincts "parallel-agents" duplicados sin consolidar (P2) — pendiente, ya flagged en auditoría previa.
- Precisión float en `confidence` sin redondear en 3 ficheros (P3) — pendiente, mismo hallazgo que hace 22 días.

### Proposals
- Zombie instincts por rechazo no propagado (P1) — **corregido hoy** (27 archivados).
- Detector error-fix confunde output normal con error (P1) — pendiente de fix de código.
- Todas las proposals etiquetadas con un único `project_id`/`project_name` erróneo (P1) — pendiente.
- Validación por purgas masivas periódicas, ratio de rechazo histórico 88.5% (P1) — pendiente, señal para desactivar detectores legacy.
- `cx-auto-validate` acepta automáticamente proposals sin sentido (P1) — pendiente.

### Storage
- `impact.archive/` crece sin límite, 83MB sin política de purga (P2) — pendiente.
- `log/timeline.jsonl` (5MB) sin rotación ni cap (P2) — pendiente.
- `/cx-dream` manual, 12 días sin ejecutar (P3) — pendiente, candidato a scheduling.
- 1 fichero `.backup` residual de 8KB (P3) — impacto insignificante, no requiere acción.

### Hooks / motor
- Sin hallazgos (healthScore 96/100).

### Reflexes
- `bash-polling-loop-stuck` y `ci-polling-gh-sleep` disparan en cualquier Bash, no solo polling loops (P1) — pendiente.
- `usefulCount` supera a `fireCount` en 4.5x para esos mismos dos reflexes, métrica de calibración corrupta (P1) — pendiente, bloquea el auto-disable.
- `api-auth-check` y `git-push-safety` con baja utilidad (~4%) señalados hace 3 semanas sin acción (P2) — pendiente, requiere decisión explícita.

### Overhead de inyección
- 9 triggers degenerados (P1) — **corregido hoy**.
- El propio instinct anti-ruido `meta-broad-trigger-instinct-noise` genera ruido (P2) — pendiente.
- Presupuesto de tokens por sesión al 78% a mitad de sesión por triggers rotos (P2) — se mitiga parcialmente con el fix de hoy a INJ-01.
- Cooldown por sesión (v3.37.0) funciona correctamente, no requiere acción (P3).

## Huecos de cobertura (no auditados en esta pasada)

1. `impact.jsonl` (18MB) + `impact.archive/` — feed crudo de inject/suppress, mecanismo de archivado sin verificar.
2. `proposals-history.jsonl` completo (solo se auditaron las 6 pending).
3. Capa textual/comportamental: `knowledge-log.md`, `cross-day-tracker.jsonl`, `productivity-patterns.json`, `memory.json`.
4. `evolved/` (pipeline cluster→skill/rule/agent) — drafts repetidos sin promoción clara desde 12-jun.
5. `dashboard.html` estático desde hace 67 días pese a que el sistema sigue generando snapshots.
6. `projects/registry.json` + consistencia registry↔disco.

Menor: 11 marcadores en `.fire-once/` y 3 `.lock` a 0 bytes sin verificar si son residuos de procesos muertos.

## Acciones aplicadas en esta sesión (2026-07-02)

- [x] Reconciliación real de zombie instincts (27 confirmados, no 128) y archivado a `instincts/{global,projects/*/instincts}/archive/*.rejected-20260702.yaml`.
- [x] Reescritura de la ley `fersora-inbox-staging-only-not-final.txt` (trigger en lenguaje natural, sin regex truncado).
- [x] Archivado de los 2 instincts ya promovidos a ley (`fersora-inbox-staging-only-not-final`, `read-instructions-before-executing`) → `*.promoted-to-law-20260702.yaml`.
- [x] Reescritura de los 9 triggers degenerados (`Tool|patrón` → `Tool.*patrón`), validados con PyYAML + regex en vivo.
- [ ] `/cx-validate` sobre las 6 proposals pending — ver turno siguiente.

## Follow-ups de código (fs-cortex, requieren release checklist)

Estos NO son fixes de datos, requieren tocar `hooks/lib/*.py` / `*.js`, tests emparejados y el ciclo de release (`fs-cortex-release-checklist`):

1. `distill_engine.py:966` — truncado ciego a 40 chars del trigger al derivar una ley; aplicar corte por límite de palabra igual que ya hace el bloque `LAW_MAX_CHARS`.
2. `distill_engine.py: auto_promote_to_law` — añadir paso que archive/marque `law_eligible:false` el instinct fuente tras promoción exitosa.
3. `injector-engine.js: parseInstinctYaml` — rechazar `action` con JSON crudo (`{"`, `file_path"`, `old_string"`) igual que ya rechaza `/try:\s*$/`.
4. `session-learner.js` — añadir nombres de tools a `TRIGGER_STOPWORDS` para que no se elijan como "token distintivo" del trigger.
5. `injector-engine.js:372-386` — sustituir dedup por-domain-genérico por dedup por subtopic más fino.
6. `observe.py: detect_is_error` — extender guards a patrones de subprocess habituales en Bash (`[codex]`, `npm warn`, cabeceras de grep) antes de marcar `err=true`.
7. `session-learner.js:501,735,1346,1906` — derivar `project_id`/`project_name` por proposal individual, no por ejecución del learner.
8. `reflexes.json` — añadir `condition` a `bash-polling-loop-stuck` y `ci-polling-gh-sleep` replicando su propio `anti_pattern`.
9. Backfillear `resetAt` en esos mismos 2 reflexes para que el rebuild de `usefulCount` no arrastre historial pre-fix.

## Metadatos

- Dimensiones auditadas: 7 · Hallazgos: 25 brutos / 25 confirmados / 0 refutados.
- Verificadores adversariales por hallazgo: 1.
- Agentes totales: 35 · tokens: 1.940.291 · duración: ~17 min.
