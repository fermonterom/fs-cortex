# Contexto: Auditoría completa de 4 sistemas de aprendizaje para Claude Code

## Qué pasó

Audité mi instalación local de Sinapsis v4.1.1 y descubrí por qué no aprende. Después comparé el código fuente real de los 4 sistemas que existen:

1. **Synapis v1.0** (`/Users/fmm/github/synapis`) — el original de Luis Salgado
2. **Cortex v1.0** (`/Users/fmm/github/fs-cortex`) — mi proyecto, 100% mío
3. **Sinapsis v4.1.1** (`/Users/fmm/github/sinapsis-3.2`) — fork de Luis, licencia restrictiva
4. **Everything Claude Code v1.9** (`/Users/fmm/github/everything-claude-code`) — Affaan Mustafa, MIT

## Comparativa visual detallada

Lee `~/.agent/diagrams/sinapsis-triple-comparison.html` — contiene la comparativa completa con código fuente real, pipelines lado a lado, formatos de datos, sistemas de confianza, hooks de cada sistema, y tabla de fortalezas/debilidades.

## Diagnóstico: por qué Sinapsis v4.1.1 no aprende

El pipeline tiene un GAP crítico. Las observaciones se capturan bien (3.268 entradas, 6 hooks funcionando) pero:

- `_session-learner.sh` lee SOLO las últimas 100 líneas de `observations.jsonl`
- Solo detecta 1 patrón: `is_error → mismo tool → éxito en ≤5 eventos`
- `/analyze-session`, `/evolve`, `/promote` NO leen `observations.jsonl` — solo `_instinct-proposals.json` que está casi siempre vacío
- Resultado: 5 instincts genéricas (no hardcodear secrets, conventional commits, read before edit). Cero instincts de mi stack real (Supabase, Stripe, Next.js, E2E, TDD)
- El paso de análisis del historial completo fue diseñado pero nunca implementado

## Por qué Cortex y no Sinapsis

- **Licencia**: Sinapsis tiene licencia restrictiva de Luis (no puedo vender, no puedo meter en cursos/consultoría, contribuciones = derechos transferidos a Luis). Cortex es 100% mío.
- **Arquitectura**: Cortex ya tiene la mejor arquitectura conceptual (pirámide Obs→Instinct→Law, Jaccard promotion, agentes especializados, scrubbing, backup portable). Le falta la implementación que Sinapsis v4.1.1 sí tiene (hooks determinísticos, inyección en tiempo real).
- **Decisión**: Refactorizar Cortex v1.0 → v2.0 incorporando lo mejor de los 4 sistemas.

## Lo mejor de cada sistema (para incorporar a Cortex v2.0)

### De Synapis v1.0 (diseño)
- Observaciones semánticas con `type` (correction|repetition|preference|workaround|rejection|toolchain)
- Confianza 0.0–1.0 con 5 etapas y decay (-0.05/30 días sin ver)
- `/analyze-observations` que lee TODO el historial con clustering 4D
- Self-healing: 3 ocurrencias → instinct automática

### De Cortex v1.0 (ya lo tenemos)
- Pirámide Obs→Instinct→Law (auto-distilación a one-liners ≤120 chars)
- Jaccard promotion ≥0.70 + 2 proyectos + conf≥0.80
- Agentes: cortex-observer (Haiku), cortex-planner (Sonnet)
- Scrubbing completo (API, JWT, PEM, Bearer)
- Backup/restore portable

### De Sinapsis v4.1.1 (implementación)
- 6 hooks determinísticos bash/Node.js (sin LLM, siempre funcionan)
- Inyección en tiempo real vía PreToolUse (instincts + passive rules + context)
- context.md auto-inyectado entre sesiones (14d TTL)
- `is_error` flag determinístico
- Domain dedup (max 3 instincts por tool use)

### De ECC v1.9 (ideas)
- Formato de observación más rico: `tool_input`, `tool_output`, `prompt`, `outcome`
- Project-scoped instincts por defecto, promotion explícita a global
- SQLite state store (futuro)

## Lo que NO queremos repetir

- Synapis v1.0: no tiene hooks — es especificación sin implementación
- Cortex v1.0: instincts no se inyectan en tiempo real, solo Laws al inicio
- Sinapsis v4.1.1: lee 100 de 3.268 observaciones, 1 solo patrón, sin confianza
- ECC: 60 MB, 125 skills, 28 agentes — demasiado para operador individual

## Plan propuesto (en REFACTOR-PROMPT.md)

Hay un `REFACTOR-PROMPT.md` en la raíz del proyecto con la arquitectura detallada: estructura de directorios, formatos de datos, hooks, comandos, pipeline, y plan de 4 fases.

## Atribución

```
Cortex — Continuous Learning Engine for Claude Code
(c) 2026 Fernando Montero / Fersora Solutions

Inspired by:
- Sinapsis by Luis Salgado (salgadoia.com) — hook architecture and injection patterns
- Everything Claude Code by Affaan Mustafa — observation format and project scoping
```

## Qué hacer ahora

Leer este archivo + `REFACTOR-PROMPT.md` + `~/.agent/diagrams/sinapsis-triple-comparison.html`. Después discutir conmigo qué cambiar realmente y qué no antes de tocar código.
