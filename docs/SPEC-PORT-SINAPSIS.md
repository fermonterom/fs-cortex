# SPEC — Port de mecanismos Sinapsis v4.6.1 a Cortex v4

Fuente verificada: `/Users/fmm/github/sinapsis` (v4.6.1). Extraído 2026-07-02. Complementa `DESIGN-V4.md` (el diseño manda; este doc da los valores exactos de referencia).

## 1. Captura output+error (ref: `skills/sinapsis-learning/hooks/observe_v3.py`)

- Caps: `input` 5.000 chars, `output` 10.000 chars (por caracteres, JSON-dumped si dict).
- En `tool_complete`: guardar `output`, y si hay match de error → `is_error: true` + `err_msg` = primera línea que matchea, cap 500 chars, con scrubbing de secretos.
- Patrones de error de Sinapsis (aplicados sobre `output.lower()`):
  ```python
  error_patterns = [
      r"\berror[:\s]", r"\bfailed\b", r"\bexception\b",
      r"\btraceback\b", r"\berrno\b", r"\beperm\b", r"\benoent\b",
      r"exit code [1-9]", r"command not found",
  ]
  ```
- **Mejora Cortex (obligatoria, DESIGN §1)**: Sinapsis es puramente léxico (sin exit code, sin excepciones). Cortex añade guards ANTES de marcar error: `[codex]`, `npm warn`, `npm notice`, `+ pkg@x.y.z` (listados de versión), `===== file =====` (headers de grep -l/awk), `0 errors`, `warning:` sin error. Mantener el scrubbing de secretos existente de observe.py.
- Subagentes NO se observan (filtro por `agent_id`).

## 2. Umbrales y estados (ref: `core/_instinct-activator.sh:178-202`)

- Estados: `draft` (no se inyecta, SÍ trackea occurrences/sessions en silencio) → `confirmed` (se inyecta) → `permanent` (solo manual).
- Auto-promoción draft→confirmed: `occurrences >= 5 && sessions_seen.length >= 3` (sessions_seen dedupeado, cap 20).
- Decay por inactividad: confirmed >60d sin trigger → draft; draft >90d → archived. `permanent` nunca decae. Draft con 0 occurrences y >90d → archived (en maintain).
- Mapeo a Cortex: `draft`≈proposal aceptada provisional / instinct conf<0.70 no inyectable; `confirmed`≈instinct inyectable. Implementar con el campo `status` en el YAML del instinct (default `confirmed` para los legacy ya curados) — los nuevos nacen `draft`.

## 3. EOD acumulativo (ref: `core/_eod-gather.sh`, `commands/eod.md`, `core/_project-context.sh`)

- La acumulación es ESTRUCTURAL: el gather relee TODO `observations.jsonl` del día (filtro por prefijo de fecha en timestamp) en cada invocación → ejecutar a las 15h y a las 19h da superset automáticamente. El summary diario se SOBRESCRIBE (un fichero por fecha).
- Estructura del gather por proyecto: `{hash, name, root, observations_today, tools_used[], files_touched[] (máx 15), errors_today, git:{branch, commits_today, commits_log, uncommitted_files, status}, context}`.
- Recarga next-day: SessionStart inyecta el summary de hoy o, si no existe, el de AYER (solo el más reciente).
- **Eisenhower NO existe en Sinapsis** — diseño nuevo para Cortex: al cargar el EOD de ayer en SessionStart, clasificar los pendientes (uncommitted, "for tomorrow", compromisos) en Q1/Q2/Q3/Q4 según la semántica de la regla `04-priorizar-eisenhower.md` de fersora (urgente = deadline externo 24-48h o bloqueo; importante = mueve objetivo/salud/relaciones clave). Implementación determinista simple: heurística por keywords + edad, con formato de salida Q1/Q2/Q3/Q4 y el resto a backlog. Marcarlo como `[eod-eisenhower]` en el bloque inyectado.

## 4. Inyección (ref: `core/_instinct-activator.sh:100-176`) — parámetros de referencia

- `MAX_INSTINCTS_INJECTED = 8` (sobre el mapa ya dedupeado por domain), `INJECT_MAX_LEN = 500` chars/instinct, `TOKEN_BUDGET = 6000` chars/bloque.
- Orden byte-estable (prompt-cache friendly): permanent > confirmed → más occurrences → tiebreak alfabético por id.
- Guards: anti-ReDoS (cuantificadores anidados), anti prompt-injection (`ignore previous instructions|system:|</system>`), anti path-traversal.
- Cortex mantiene su injector (ya tiene cooldown por sesión y token budget); adoptar: tiebreak byte-estable por id y el guard anti prompt-injection si no existen.
