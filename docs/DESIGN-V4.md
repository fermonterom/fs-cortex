# Cortex v4 — "Signal-first, zero-decision"

**Fecha**: 2026-07-02 · **Autor**: Fable 5 (orquestador) con mandato completo de Fer · **Estado**: contrato de implementación para la rama `feat/v4-signal-first`.

## Diagnóstico que motiva v4 (resumen)

Evidencia completa en `audit-cortex-2026-07-02.md` y en el veredicto `fersora/_inbox/20260702-veredicto-cortex-vs-sinapsis.md`:

1. **La señal muere en la captura**: `observe.py` apenas puebla output/err de los tool calls → los detectores generan gotchas-basura (JSON crudo, headers de grep confundidos con errores) → 88,5% de rechazo histórico → gates cada vez más duros → pipeline congelado (última law y skill: 16-may).
2. **Los comandos piden decisiones**: 20+ comandos `cx-*`, la mayoría interactivos (shorthand, confirmaciones). No se pueden automatizar con cron/schedule. Cuando Fer los corre, responden "no hay nada" porque todo murió aguas arriba — la UX transmite "el sistema no hace nada".
3. **Complejidad que se auto-alimenta**: 11.6k líneas, doble runtime; el esfuerzo de 4 meses se fue a mecánica de release y a reparar carreras/bloat del propio diseño.

## Principios v4

- **P1 — La calidad se decide en la captura, no en la validación.** Capturar output+error real (port de Sinapsis) y descartar basura en origen. Ningún artefacto se confirma con 1 evidencia.
- **P2 — Cero decisiones dentro de comandos.** Un comando o es determinista (automatizable con cron) o es de revisión humana pura (digest). Nunca mezcla.
- **P3 — Promoción determinista.** Reglas objetivas sustituyen a flags manuales que nadie pone.
- **P4 — Menos artefactos, mejores.** Laws cap 15 con contenido único (no duplicar CLAUDE.md); instincts con action generalizable o no existen.

## 1. Captura (observe.py) — port de Sinapsis

- PostToolUse guarda además de lo actual: `output` truncado (cap 10.000 chars), `is_error` calculado con patrones word-boundary, `err_msg` (primera línea del error real).
- Guards anti-falso-positivo ANTES de marcar `is_error=true`: prefijos de log de subprocess (`[codex]`, `npm warn`, `npm notice`), listados de versión (`+ pkg@x.y.z`), cabeceras de grep (`===== file =====`), progreso/spinners, exit-code 0.
- Los patrones exactos se toman del spec extraído de `~/github/sinapsis` (documento del agente F2a); si algún patrón no aplica al harness de Claude Code, se adapta y se documenta la divergencia aquí.

## 2. Umbrales de confirmación (session-learner.js + distill_engine.py)

- Un instinct nuevo nace como `draft` y solo pasa a `confirmed` (inyectable) con **≥5 ocurrencias en ≥3 sesiones distintas**. Se elimina todo auto-accept con 1 evidencia.
- `cx-auto-validate` deja de aceptar dominio `error-recovery` automáticamente.
- Detectores `correction` y `file-coupling` permanecen apagados (`noisy_detectors_off`).
- Calidad de action en generación: se rechaza cualquier proposal cuyo action contenga JSON crudo (`{"`, `file_path"`, `old_string"`) o comandos concatenados sin separador. `TRIGGER_STOPWORDS` incluye los nombres de tools (Read, Write, Edit, Bash, Grep, Glob, Agent, AskUserQuestion, prefijos mcp__).
- `project_id`/`project_name` se derivan POR PROPOSAL desde la observación que la respalda, no por ejecución del learner.

## 3. Promoción a law — determinista (sustituye Criteria 8 manual)

`auto_promote_to_law` promueve sin intervención humana cuando TODAS:
- `confidence ≥ 0.95`
- visto en **≥3 proyectos distintos** (`projects_seen`)
- `occurrences ≥ 10` contadas POST-fix de triggers (se resetea el contador inflado histórico: campo `occurrences_v4` empieza en 0; el legacy queda como `occurrences_legacy`)
- sin feedback de ruido en los últimos 14 días (impact log)

Tras promover: el instinct fuente se archiva automáticamente (`.promoted-to-law-<fecha>.yaml`). El derive de la línea de law NUNCA incrusta el regex del trigger (fix del truncado a 40 chars: parafrasear o cortar por palabra). `law_eligible` desaparece como gate (se ignora si existe; `law_eligible: false` se respeta como veto explícito).

Instincts con trigger específico y <3 proyectos NO son candidatos a law por diseño: ya se inyectan on-demand, que es lo correcto. `auto-distill-candidates.md` desaparece (era un buzón que nadie leía); lo que no cumple la regla no es candidato, punto.

## 4. Inyección (injector-engine.js)

- Guard hollow ampliado: action con JSON crudo → no inyectable.
- Dedup por `subtopic` (primeras 2 palabras del id) en vez de por `domain` genérico; se permite 2º instinct del mismo domain si ambos ≥0.85.
- Validación estática de triggers al cargar: patrón `^(Bash|Read|Edit|Write|Grep|Glob|Agent)\|` (alternación degenerada) → warning + skip.
- Reflexes: `bash-polling-loop-stuck` y `ci-polling-gh-sleep` reciben `condition` acotada a su anti-pattern; ambos con `resetAt` backfilled.

## 5. Set de comandos v4 (7 activos, resto deprecado)

| Comando | Tipo | Qué hace |
|---|---|---|
| `/cx-status` | lectura | Dashboard de texto: salud, conteos, últimas promociones, próximo maintain. |
| `/cx-maintain` | **determinista, cron-able** | decay + dedup Jaccard + purga de decaídos + promoción determinista (§3) + rotación storage + health check + reconciliación proposals↔instincts (rechazado ⇒ archivado). CERO preguntas. Idempotente. Reemplaza: distill, dream, validate(auto), promote, backfill. |
| `/cx-review` | **humano, semanal** | ÚNICO comando con juicio: presenta el digest acumulado (proposals human-gated, drafts de evolve, laws propuestas para deprecar) en UNA lista shorthand. 2 minutos. Reemplaza: validate(humano), evolve(confirmación), downvote, retro. |
| `/cx-eod` | determinista | Acumulativo 24h (ejecutable N veces al día, acumula desde el último cierre); al día siguiente SessionStart carga el cierre y genera matriz Eisenhower de pendientes. Port del comportamiento de Sinapsis. |
| `/cx-gotcha` | manual | Captura explícita de un gotcha (la fuente de mayor calidad histórica). Sin cambios de fondo. |
| `/cx-backup` / `/cx-restore` | utilidad | Sin cambios. |

**Deprecados** (stub que imprime aviso + comando sustituto, se retiran en v5): cx-analyze, cx-distill, cx-dream, cx-validate, cx-evolve, cx-promote, cx-backfill, cx-timeline, cx-dashboard, cx-audit, cx-feedback, cx-feedback-auto, cx-downvote, cx-retro, cx-router, cx-export, cx-stop. La auditoría profunda vive como workflow `cortex-audit` (ya existente), no como comando.

## 6. Automatización

- **SessionStart**: maintain-lite diario (decay+rotación, ya existía como auto-distill) + recordatorio de `/cx-review` SOLO si el digest tiene items (badge con conteo). Dream deja de existir como concepto separado: su dedup/staleness va dentro de maintain.
- **Semanal**: `/cx-maintain` completo programable vía cron de Claude Code o launchd (`claude -p "/cx-maintain"`). El installer ofrece registrarlo.
- **EOD**: se mantiene la routine nocturna existente, ahora acumulativa.

## 7. Métricas honestas

- `fireCount`/`usefulCount` se unifican a la misma unidad (por inyección) con `resetAt` global v4; los contadores legacy se archivan. El health check de maintain reporta instincts con ratio ruido>útil para el digest de review.
- `impact.archive/` y `timeline.jsonl` entran en la rotación con techo de retención 90 días.

## 8. Fuera de alcance v4 (decidido, no olvidado)

- Skill-router tipo Sinapsis: el lazy-loading de skills ya es nativo en Claude Code (solo carga name+description); la palanca es acortar descriptions (hecho en fersora), no un router. Se reevalúa solo si tras la dieta el arranque sigue >45k.
- Dashboard HTML: congelado (sin inversión); `/cx-status` en texto es la superficie oficial.
- Cohort nudging complejo: se mantiene el código pero sin nuevas features hasta que las métricas unificadas (§7) demuestren utilidad.

## Criterio de éxito (checkpoint 2026-08-02)

Si el digest semanal de `/cx-review` no ha producido ≥3 instincts útiles nuevos y ≥1 law/skill de valor real en 30 días, se migra a Sinapsis portando los datos curados. Falsifiable y sin apelación.
