# DESIGN — v4.2.0 · Laws layer: de-dup, legibility, post-promotion audit

Fecha: 2026-07-05 · Estado: aprobado (Fernando delegó el criterio) · Origen: pregunta de Fer "¿son las laws la mejor forma de hacer esto, o son ruido?"

## Contexto y evidencia (medida, no supuesta)

La capa de leyes son `laws/*.txt` inyectadas SIEMPRE al SessionStart (`session-start.py:load_laws` → `565-568`), sin filtro, ~975 tokens. Investigación de esta sesión + contra-análisis adversarial (3 agentes):

- **Coste real:** 15 leyes, ~975 tokens/sesión = <0.5% de un contexto de 200k. **El coste NO es el problema.**
- **Sin feedback de salida:** la promoción a ley SÍ exige feedback de entrada (DESIGN-V4 §3: conf≥0.95, ≥3 proyectos, ≥10 ocurrencias, 14 días sin ruido). Pero una vez escrita la ley, nada vuelve a medir su valor salvo `_find_least_impactful_law` cuando el cap 15 satura. Feedback congelado post-promoción.
- **Doble inyección (bug confirmado):** `read-instructions-before-executing` (41 inyecciones PreToolUse redundantes medidas en impact.jsonl) y `pref-fix-all-lint-test-issues` (17) existen como ley Y como instinct global activo. `auto_promote_to_law` archiva el instinct fuente, pero las rutas seed + swap manual NO → duplicados.
- **Mezcla de granularidad:** las 15 mezclan principios de conducta (advisor-escalation, deep-work, loop-reorient) con gotchas de herramienta (cat→Read, inline-python) en un solo bloque "follow always", lo que diluye la atención sobre los principios.

## Qué NO se hace (y por qué) — evitar sobre-corrección

El contra-análisis refutó las ideas invasivas:
- **NO encoger a 5-7 curadas a mano:** el contenido actual no es malo; el coste es <0.5%. Sin evidencia que lo justifique.
- **NO demotar los gotchas a instinct:** se promovieron porque son universales Y ya pasaron trigger-gating. Como instinct, un log con formato inesperado no dispara el regex; como ley siempre está. Demotar = perder disparo garantizado.
- **NO parar `auto_promote_to_law`:** ya tiene gates de calidad (no es ciega).
- **NO scoping por dominio:** solo 2-3 leyes son de dominio de proyecto (playwright→testing, api-route→web); el resto de "mecánicas" son universales de tooling. Montar meta-file + detección de dominio en Python para 2 casos que ahorran ~100 tok es abstracción nueva injustificada (viola minimalismo).

## Cambios v4.2.0

### C1 — De-dup + fix de raíz (bug)
- **Data:** archivar `instincts/global/read-instructions-before-executing.yaml` y `pref-fix-all-lint-test-issues.yaml` → `instincts/global/archive/*.dup-of-law-20260705.yaml`.
- **`injector-engine.js`:** al construir candidatos, excluir cualquier instinct cuyo `id` tenga un fichero `laws/{id}.txt` (una ley ya se inyecta al SessionStart; el instinct gemelo es redundante). Leer LAWS_DIR una vez → Set de law-ids → skip. Retrocompatible.
- **`distill_engine.py`:** que `manual_swap_promote` (y cualquier ruta de creación de ley) archive SIEMPRE el instinct fuente si existe, igual que `auto_promote_to_law`.

### C2 — Adelgazar advisor-escalation
- **Data:** `laws/advisor-escalation.txt` de ~1500 chars a ~500 (resumen + los 4 triggers esenciales, sin el detalle expandido). Es un principio válido, solo desproporcionado (26% del presupuesto en una ley; el fix de inyección-completa de v4.1.0 lo destapó).

### C3 — Legibilidad: split de presentación por tier
- **Data:** nuevo `laws/laws-meta.json` (+ seed `core/laws-meta.default.json`) con `{version, laws: {<id>: {tier: "principle"|"tool"}}}`. Clasificación inicial abajo.
- **`session-start.py:load_laws`:** devolver las leyes agrupadas por tier. `565-568` renderiza dos sub-bloques bajo el header:
  ```
  CORTEX LAWS (follow always):
  [principios]
  - ...
  [herramienta]
  - ...
  ```
  Retrocompat: ley sin entrada en meta → tier "principle" (nunca se oculta nada). Sin meta-file → comportamiento actual (un bloque).

### C4 — Auditoría post-promoción (legibilidad periódica)
- **`distill_engine.py`:** nueva función `law_audit()` que devuelve por cada ley activa `{id, tier, age_days, dup_active_instinct: bool, backing_instinct_noise: ratio|null}`, más subcomando CLI `law-audit [--json]` (mismo patrón que los `prune-tracking`/`reap-nudges` de v4.1.0). Escribe también `~/.claude/cortex/.law-audit.json` al correr. NO se toca el heredoc de cx-maintain ni `bin/cx-maintain.sh` (tienen WIP ajeno sin commitear); la integración en el digest se hará cuando ese WIP asiente. Da a Fernando legibilidad periódica para podar a mano — el modelo correcto ahora que las leyes son una constitución curada (humano poda con datos, no auto-feedback falso; medir "ley seguida" es irresoluble sin trigger, confirmado por el adversarial).

## Clasificación tier inicial (laws-meta.json)

**principle** (conducta / cómo trabajar): advisor-escalation · deep-work-to-docs · read-instructions-before-executing · loop-reorient · pref-fix-all-lint-test-issues · gotcha-ad-por-fase-no-sustituye-e2e

**tool** (gotcha de herramienta): build-output-to-log · cat-pipe-head-claudemd-anti · gotcha-inline-python-readability · macos-downloads-read-tool · gotcha-mcp-server-wrong-config-file · gotcha-webfetch-fallback-to-websearch · gotcha-firecrawl-over-tavily-html · e2e-playwright-selectors · gotcha-api-route-error-message-leak

## Verificación
- Test pair + `run_all.sh` verde.
- Smoke `echo '{}' | python3 hooks/session-start.py` con los dos bloques.
- Deploy `install.sh` + verificar dedup (0 instincts gemelos), advisor adelgazada, digest con law_audit.

## v4.2.1 — follow-up AD (Codex GPT-5.5)

Tras mergear v4.2.0 se pasó un AD read-only con Codex GPT-5.5 sobre v4.1 + v4.2 para cazar lo que los enjambres Sonnet y el contra-análisis previo pasaron por alto. Evaluados como reales (no paja) y corregidos:

- **[P1] `load_laws()` crasheaba SessionStart con `laws-meta.json` malformado.** `{k: v.get('tier') for k,v in meta.get('laws',{}).items()}` solo capturaba `FileNotFoundError`/`JSONDecodeError`/`OSError`; un `laws` no-dict o un valor no-dict lanzaba `AttributeError` no capturado → moría toda la inyección de SessionStart. Fix: parseo tolerante (valida dict en cada nivel, `except Exception` de respaldo, degrada a tier `principle`). Test de regresión en `test_session_start.sh` (malformado → exit 0 + bloque presente).
- **[P1] `impact.archive` violaba el contrato "never deleted".** El `keep=5` por conteo (v4.1.0) podía borrar chunks < 90 días, contradiciendo `impact_log.py`/`session-learner.js`/`FEATURES.md`. Pero `DESIGN-V4 §7` sí decide "techo de retención 90 días" — contradicción interna previa. Fix: poda por EDAD de 90 días (`IMPACT_ARCHIVE_KEEP_DAYS`, `_pruneDirByAge`) que implementa la decisión real del diseño; comentarios "never deleted" reconciliados al 90-día.
- **[P2] `FEATURES.md` sin filas v4.1/v4.2 + fecha stale.** Actualizado header, fecha y version-history (v4.1.0/v4.2.0/v4.2.1).
- **[P2] Sin test del split por tier ni de meta corrupto.** Añadidos (Test 5/6/7 en `test_session_start.sh`).

Codex confirmó como correctos (no tocar): el injector no cuela `laws-meta.json` como law-id (filtro `.txt`), el guard no crashea sin `laws/`, ley sin meta → `principle`, `manual_swap_promote` busca instincts de proyecto.
