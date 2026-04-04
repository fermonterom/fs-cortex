# Cortex v2.0 — Refactorización Completa

## Contexto

Cortex es el sistema de aprendizaje continuo de Fernando Montero para Claude Code. Versión actual (v1.0) tiene buena arquitectura conceptual (pirámide Obs→Instinct→Law, agentes especializados, Jaccard promotion) pero necesita una refactorización completa para incorporar lo mejor de 3 sistemas analizados + corregir las carencias propias.

## Análisis visual de referencia

Ver `~/.agent/diagrams/sinapsis-triple-comparison.html` para la comparativa detallada con código fuente real de los 4 sistemas.

## Sistemas analizados (código fuente real, no documentación)

### 1. Synapis v1.0 (`/Users/fmm/github/synapis`)
**Fortalezas a incorporar:**
- Formato de observación semántico: `type` (correction|repetition|preference|workaround|rejection|toolchain), `description`, `context`, `relatedInstinct`
- Confianza 0.0–1.0 con 5 etapas: Observation(0.0-0.3) → Hypothesis(0.3-0.5) → Pattern(0.5-0.7) → Instinct(0.7-0.9) → Law(0.9-1.0)
- Confidence decay por obsolescencia (-0.05 si no se ve en 30 días)
- `/analyze-observations` lee TODO el historial, clustering por frecuencia, tiempo, dominio, cadenas de corrección
- Self-healing loop: 3 ocurrencias del mismo error → instinct automática. Confianza ≥0.8 → regla pasiva
- Instinct format rico: trigger, action, tags[], scope, firstSeen, lastSeen, occurrences, project

**Debilidades a NO repetir:**
- No tiene hooks ni scripts de captura. Es una especificación, no una implementación
- El LLM decide qué observar — no determinístico ni fiable

### 2. Cortex v1.0 (`/Users/fmm/github/fs-cortex`) — NOSOTROS
**Lo que ya tenemos bien:**
- Pirámide de 3 niveles: Observations → Instincts (YAML) → Laws (one-liners ≤120 chars)
- Laws auto-distiladas cuando confianza ≥0.90
- Promotion semántica: Jaccard ≥0.70 + 2 proyectos + confianza media ≥0.80
- Agentes especializados: cortex-observer (Haiku), cortex-planner (Sonnet), cortex-reviewer
- Scrubbing de secretos completo (API keys, JWT, PEM, Bearer)
- Backup/restore portable (/cx-backup → .tar.gz)
- 8 dominios explícitos (workflow, web, saas, deployment, automation, documentation, testing, security)
- Max 10 Laws activas (resto archivadas) — eficiente en tokens

**Lo que nos falta (descubierto en el análisis):**
- NO hay inyección de instincts en tiempo real durante la sesión (solo Laws al SessionStart)
- NO hay `is_error` flag en observaciones — cortex-observer debe inferir, ambiguo
- NO hay context.md bridge auto-inyectado entre sesiones
- cortex-observer es LLM agent (no determinístico) — puede fallar si la red cae
- Sampling agresivo (1/3 para Read/Glob/Grep) puede perder signal
- Reflexes son hardcoded, no aprendidos
- Daily summaries no son auto-inyectados (requieren /cx-eod manual)

### 3. Sinapsis v4.1.1 (`/Users/fmm/github/sinapsis-3.2`)
**Fortalezas a incorporar:**
- 6 hooks determinísticos que FUNCIONAN (bash/python, sin LLM, siempre fiable)
- Inyección en tiempo real vía PreToolUse: instincts + passive rules + context.md por cada tool use
- context.md auto-inyectado una vez por sesión (14 días TTL)
- Domain dedup: 1 instinct por dominio, max 3 inyectadas por tool use
- _session-learner.sh al Stop: Node.js puro, sin LLM, siempre ejecuta
- `is_error` flag determinístico en observaciones

**Debilidades a NO repetir:**
- Solo lee últimas 100 líneas de observations.jsonl (ignora 97% del historial)
- Solo detecta 1 patrón: mismo tool falló → mismo tool éxito en ≤5 eventos
- Observaciones sin descripción, sin contexto, sin tipo semántico
- 3 niveles planos (draft/confirmed/permanent) sin confianza acumulada
- /analyze-session, /evolve, /promote NO leen observations.jsonl
- Pipeline diseñado pero incompleto — el paso de análisis nunca se construyó

### 4. Everything Claude Code v1.9 (`/Users/fmm/github/everything-claude-code`)
**Ideas a considerar:**
- Formato de observación más rico: incluye `tool_input`, `tool_output`, `prompt`, `outcome`, `project_name`
- SQLite state store en lugar de archivos JSON (más robusto para queries)
- Project-scoped instincts por defecto, promotion explícita a global
- Manifest-driven selective install para componentes modulares
- Licencia MIT — podemos tomar patrones libremente

**Lo que NO queremos:**
- 60 MB, 125 skills, 28 agentes — demasiado complejo para un operador individual
- Curva de aprendizaje pronunciada
- Mantenimiento alto

---

## Arquitectura Cortex v2.0

### Principios de diseño
1. **Determinístico primero** — hooks en bash/Node.js que siempre funcionan, sin depender del LLM ni de red
2. **LLM como complemento** — cortex-observer (Haiku) para análisis profundo, pero el sistema funciona sin él
3. **Inyección dual** — Laws al inicio de sesión + instincts en tiempo real por PreToolUse
4. **Datos ricos** — observaciones con input/output/is_error/project_name + scrubbing de secretos
5. **Confianza acumulada** — 0.0→1.0 con decay, historial de ocurrencias, auto-distilación a Laws
6. **Project-scoped por defecto** — sin contaminación cross-project, promotion explícita

### Estructura de directorios
```
~/.claude/cortex/
├── memory.json                    # Identidad + config + stats
├── reflexes.json                  # Reglas determinísticas (hardcoded guardrails)
├── laws/                          # Wisdom nivel 3 (one-liners ≤120 chars, max 10)
│   └── {id}.txt
├── instincts/                     # Patrones nivel 2 (YAML con evidencia)
│   ├── global/                    # Promovidas (Jaccard≥0.70 + 2 proyectos)
│   └── project/
│       └── {project-hash}/
├── projects/
│   ├── registry.json              # Registro de proyectos (hash → name, path)
│   └── {project-hash}/
│       ├── observations.jsonl     # Histórico completo
│       ├── context.md             # Puente entre sesiones (14d TTL)
│       └── instincts/             # Instincts project-scoped
├── daily-summaries/               # EOD para continuidad (14d TTL)
├── evolved/                       # Skills/commands/agents generados
├── exports/                       # Skills portables
├── hooks/                         # Scripts de hooks
│   ├── observe.sh                 # PreToolUse/PostToolUse (async)
│   ├── session-start.sh           # SessionStart (sync) — inyecta Laws + EOD resume
│   ├── instinct-activator.sh      # PreToolUse (sync) — inyecta instincts matched
│   ├── passive-activator.sh       # PreToolUse (sync) — inyecta reflexes matched
│   ├── session-learner.js         # Stop (sync) — analiza sesión + escribe context.md
│   └── scrub.sh                   # Shared: regex para secretos
└── log/
    ├── session-learner.log        # Log de detecciones
    └── observer.log               # Log de cortex-observer
```

### Formato de observación (v2.0)
```json
{
  "timestamp": "2026-04-04T14:30:45Z",
  "event": "tool_complete",
  "tool": "Edit",
  "is_error": false,
  "project_id": "0846920a5e13",
  "project_name": "tcuadro",
  "session": "sess_abc123",
  "input_summary": "route.ts:45 — old_string 'SELECT * FROM...' [scrubbed]",
  "output_summary": "success — file updated",
  "error_message": null
}
```
Cambios vs v1.0 Cortex: +`is_error`, +`input_summary` (truncado+scrubbed), +`output_summary`, +`error_message`
Cambios vs v4.1.1: +`project_name`, +`input_summary`, +`output_summary`, +`error_message`, +`session`

### Formato de instinct (v2.0)
```yaml
---
id: supabase-rls-auth-uid
trigger: "rls|policy|supabase|_auth.uid"
action: "Verify _auth.uid() in WHERE clause. Test with both auth and service roles."
confidence: 0.75
domain: database
tags: [supabase, rls, security]
scope: project
project_id: "0846920a5e13"
project_name: "tcuadro"
source: session-observation
first_seen: "2026-03-28"
last_seen: "2026-04-03"
occurrences: 4
evidence:
  - "obs_x1: User corrected missing _auth.uid() — 2026-03-28"
  - "obs_x2: Same pattern in admin routes — 2026-04-01"
evolved_to: null
---
```
Cambios vs v1.0 Cortex: +`occurrences`, +`first_seen`/`last_seen`, +`evidence[]`, +`evolved_to`
Cambios vs v4.1.1: +confianza numérica, +tags, +scope, +evidence, +historial temporal

### Sistema de confianza (v2.0)
```
0.0–0.3  Observation   — 1 sesión, sin validar, no se inyecta
0.3–0.5  Hypothesis    — visto 2+ veces, se inyecta solo si altamente relevante
0.5–0.7  Pattern       — 3+ ocurrencias, se inyecta cuando contexto coincide
0.7–0.9  Instinct      — validado, se inyecta automáticamente, candidato a /evolve
0.9–1.0  Law           — auto-distilado a one-liner, inyectado SIEMPRE al inicio

Subida: +0.1 por ocurrencia (max +0.3), +0.2 validación usuario, +0.2 cross-project
Bajada: -0.2 contradicción usuario, -0.1 aplicación fallida, -0.05/30 días sin ver
```

### Hooks (7 total)
```json
{
  "hooks": {
    "PreToolUse": [
      { "command": "bash ~/.claude/cortex/hooks/observe.sh pre", "timeout": 10000, "async": true },
      { "command": "bash ~/.claude/cortex/hooks/instinct-activator.sh", "timeout": 5000 },
      { "command": "bash ~/.claude/cortex/hooks/passive-activator.sh", "timeout": 2000 }
    ],
    "PostToolUse": [
      { "command": "bash ~/.claude/cortex/hooks/observe.sh post", "timeout": 10000, "async": true }
    ],
    "Stop": [
      { "command": "node ~/.claude/cortex/hooks/session-learner.js", "timeout": 15000 }
    ]
  }
}
```
Nota: SessionStart para Laws + EOD resume se inyecta via _project-context (primer PreToolUse, una vez por sesión).

### Comandos (8)
| Comando | Función |
|---------|---------|
| `/cx-status` | Dashboard: laws, instincts, projects, reflexes, health |
| `/cx-learn` | Full pipeline: analizar histórico completo → proponer instincts |
| `/cx-eod` | EOD summary + mini-learn |
| `/cx-gotcha` | Captura error→fix como instinct high-priority |
| `/cx-export` | Generar skill portable (confidence ≥ 0.70) |
| `/cx-backup` | .tar.gz portable (knowledge + reflexes + memory) |
| `/cx-restore` | Import backup, merge con datos existentes |
| `/cx-evolve` | Evolucionar instincts maduras → skills/commands/rules |

### Pipeline de aprendizaje cerrado
```
1. observe.sh (async)          — captura cada tool use con input/output/is_error + scrubbing
2. instinct-activator.sh       — inyecta instincts matched (conf≥0.5) en cada PreToolUse
3. passive-activator.sh        — inyecta reflexes determinísticos
4. session-learner.js (Stop)   — al cerrar: analiza últimas 200 obs, escribe context.md,
                                  detecta patrones error→fix (ventana 50 eventos),
                                  actualiza confianza de instincts existentes,
                                  propone drafts nuevos
5. /cx-learn (manual)          — análisis profundo: lee TODAS las observaciones del proyecto,
                                  clustering semántico (LLM o heurístico),
                                  propone instincts con evidencia real,
                                  auto-distila Laws si confianza ≥0.90
6. /cx-evolve (manual)         — instincts maduras → skills/commands/passive rules
```

### Atribución
```
Cortex — Continuous Learning Engine for Claude Code
(c) 2026 Fernando Montero / Fersora Solutions

Inspired by:
- Sinapsis by Luis Salgado (salgadoia.com) — hook architecture and injection patterns
- Everything Claude Code by Affaan Mustafa — observation format and project scoping patterns
```

---

## Plan de ejecución

### Fase 1: Infraestructura (hoy)
- [ ] Refactorizar estructura de directorios de Cortex v1.0 → v2.0
- [ ] Implementar `observe.sh` con formato v2.0 (input_summary, is_error, scrubbing)
- [ ] Implementar `instinct-activator.sh` (PreToolUse, domain dedup, max 3)
- [ ] Implementar `passive-activator.sh` (reflexes)
- [ ] Implementar `session-learner.js` (Stop hook, ventana 50 eventos, context.md)
- [ ] Generar `settings.json` con los 7 hooks

### Fase 2: Análisis (esta semana)
- [ ] Implementar `/cx-learn` — lee historial completo, clustering, propone instincts
- [ ] Implementar auto-distilación a Laws (confianza ≥0.90)
- [ ] Implementar decay de confianza (-0.05/30 días)
- [ ] Migrar las 3.268 observaciones existentes de homunculus/ al formato v2.0

### Fase 3: Comandos y polish (próxima semana)
- [ ] Implementar los 8 comandos (/cx-status, /cx-eod, /cx-gotcha, etc.)
- [ ] Implementar Jaccard promotion (project → global)
- [ ] Implementar /cx-backup y /cx-restore
- [ ] Tests básicos
- [ ] Documentación (README.md actualizado)

### Fase 4: Producción
- [ ] Instalar en ~/.claude/ y activar hooks
- [ ] Sembrar 5-7 instincts manuales del stack real (Supabase RLS, Stripe, E2E, TDD, admin panel)
- [ ] Ejecutar /cx-learn sobre el historial migrado
- [ ] Validar que el pipeline completo funciona end-to-end
