# Diseño B — Rediseño de la inyección de leyes (Core / Domain)

> **Estado:** DRAFT · 2026-05-31 · informa a `docs/SPRINT-V3.34-PLAN.md`
> **Origen:** sesión de curación manual del Cortex vivo del operador
> (`~/.claude/cortex/`) + inspección comparativa de Sinapsis v4.5
> (`/Users/fmm/github/sinapsis`, repo de Luis Salgado).
> **Decisión de producto pendiente de Fer:** ejecutar la Fase 2 (split
> Core/Domain) en v3.34 o diferir.

---

## 0. Resumen ejecutivo (30 s)

El "cuello de botella de las 50 leyes que no caben en 15" **no es un problema
de capacidad: es un problema de categorización.** Hoy `laws/` mezcla dos cosas
con coste de inyección muy distinto:

1. **Leyes universales** (~6-8): deben inyectarse SIEMPRE, en cada SessionStart.
   Ej. `read-instructions-before-executing`, `never-hardcode-secrets`.
2. **"Leyes" contextuales** (~40 candidatas atascadas): solo aplican en un
   contexto concreto (release, edición de changelog, onboarding, research).
   Promocionarlas a ley las fuerza a inyectarse siempre → ruido de tokens.

La solución NO es subir el cap a 50 (= ~2000 tok de ruido fijo por sesión, la
mayoría irrelevante). Es **separar la capa Core (siempre-on, cap bajo) de la
capa Domain (inyectada por relevancia, como ya hacen los instintos vía el
injector PreToolUse).** Las contextuales no necesitan ser leyes: necesitan un
buen `trigger` y confianza alta, y el injector ya las mete cuando aplican.

Sinapsis confirma que este es el diseño correcto: **no tiene leyes-siempre-on**.
Todo su conocimiento aprendido es contextual (regex en PreToolUse); su capa
`permanent` es un instinto que no decae pero sigue siendo contextual.

---

## 1. Datos reales del Cortex vivo (2026-05-31)

Curación manual sobre `~/.claude/cortex/` (no backfill):

| Métrica | Valor | Lectura |
|---|---|---|
| `proposals-history.jsonl` | 1714 (1570 rejected / 144 accepted) | 92 % rechazo |
| `proposals.json` pending | 316 (correction 138, coupling 124, error-recovery 51) | colgados |
| accept_rate por source: `workflow/file-coupling/correction/repetition` | **0 %** (0/1520) | ruido estructural, gate correcto |
| accept_rate `cx-analyze` / `agent-pattern` / `error-fix` | 92 % / 100 % / 58 % | señal buena |
| Instintos en `instinct-tracking.json` | 300 keys | — |
| Instintos sin `.yaml` (huérfanos de tracking) | **170** | señal viva no inyectable (TAREA A) |
| Leyes activas | 15 / cap 15 | saturado |
| `max_instincts_per_injection` (memory.json) | **3** | cuello del lado Domain |

**Hallazgos clave:**

- El 90 % de rejected/pending es ruido de detectores genéricos (`coupling`
  "files edited together", `correction`, `repeat-X` "called N times"). El gate
  los rechazó **bien**. No hay tesoro de instintos perdidos.
- El `distinct_sessions=20` clavado en decenas de instintos **no es bug**:
  `session-learner.js:899` trunca `sessions[]` a las últimas 20 (FIFO sano).
  Implica que esos instintos cumplen `distinct_sessions ≥ 3` del gate AUTO de
  sobra → el gate de promoción NO es el bloqueo.
- El bloqueo es el **cap de 15 leyes** + la **mala categorización** (leyes
  contextuales ocupando plazas Core).
- Instintos universales reforzados miles de veces que NO eran ley:
  `read-instructions-before-executing` (count **9311**, conf 0.99),
  `cat-pipe-head-claudemd-anti` (4906), `gotcha-ad-por-fase-no-sustituye-e2e`
  (4259), `pattern-test-after-change` (3471).

---

## 2. Mecanismo actual (verificado)

- `hooks/session-start.py:load_laws()` (`:51-64`): lee TODAS las leyes activas
  de `laws/*.txt`, orden alfabético.
- `:408-412`: las vuelca enteras SIEMPRE bajo `CORTEX LAWS (follow always):`
  — **sin relevancia, sin dominio, sin contexto.**
- Cap = `LAW_MAX_ACTIVE = 15` (`hooks/lib/distill_engine.py:92`).
- Coste: ~40 tok/ley × 15 ≈ ~600 tok/sesión fijos.
- Capa Domain ya existente: el injector PreToolUse inyecta instintos por regex
  `trigger`, confidence-gated, cap `max_instincts_per_injection = 3`.

Es decir: **Cortex ya tiene una capa de inyección por relevancia (instintos).**
El rediseño no inventa infraestructura nueva; reclasifica qué va en cada capa.

---

## 3. Lo aprendido de Sinapsis (comparación honesta)

Inspección de `/Users/fmm/github/sinapsis` (v4.5) + la comparativa que escribió
su propio autor (`docs/sinapsis-vs-cortex-2026-04-13.html`).

### 3.1 El `skill-router` de Sinapsis NO resuelve este problema

Enruta **skills** (carga bajo demanda de una librería de skills por proyecto,
con menú de instalación; lleva promo a salgadoia.com en el SKILL.md). No tiene
relación con la inyección de conocimiento aprendido. Es comparable, como mucho,
a un futuro split de la skill `cortex` en sub-skills — no al cap de leyes.

### 3.2 Lo comparable es `_instinct-activator.sh` + `_passive-activator.sh`

| Mecanismo Sinapsis | Detalle (evidencia) | ¿Cortex lo tiene? |
|---|---|---|
| Sin leyes-siempre-on | Todo el conocimiento es contextual (regex PreToolUse). `permanent` = instinto que no decae pero sigue siendo contextual | NO — Cortex sí inyecta 15 leyes fijas |
| **Per-injection token cap** | 1500 chars/tool-use (`_instinct-activator.sh:166`) | **SÍ YA** — `MAX_TOTAL_CHARS = 1500` (`injector-engine.js:332`) además del cap por nº (3) |
| **Domain dedup** | máx 1 instinto por dominio + máx 6 por tool-use (`:138-147`) | **SÍ YA** — `seenDomains` Set, máx 1/dominio (`injector-engine.js:334-340`) |

> **Corrección (2026-05-31, verificado en código):** este documento afirmó
> originalmente que Cortex NO tenía per-injection token cap ni domain dedup. Es
> **falso**: el injector (`hooks/lib/injector-engine.js:329-343`) ordena por
> confidence desc, deduplica por dominio (`seenDomains`), y corta a
> `MAX_TOTAL_CHARS = 1500`. La «Fase 3» de robar estos a Sinapsis es por tanto
> **innecesaria** — ya están. Lo único pendiente del lado injector es que
> `MAX_TOTAL_CHARS` está hardcodeado (no en `memory.json` config) y `Operator
> State` (capa estratégica cross-project) que Fer ya cubre a medias en el Brain.
| Passive rules separadas de instintos | engine aparte, 6 reglas (`_passive-rules.json`) | Parcial (10 reflexes) |
| Project stack detection | filtra instintos por tech del `context.md` (`:64-98`) | Parcial (project scope) |

### 3.3 Donde Cortex ya gana (según la comparativa del propio Luis)

- **Law distillation**: Sinapsis = *"Not implemented"*; Cortex = *"unique"*.
  Luis lo lista como mejora #2 que **Sinapsis quiere copiar de Cortex.**
- Confidence continua 0–0.95 (vs 3 niveles discretos), cross-project promotion
  automática (Jaccard), knowledge timeline, multi-agent: todo *"unique"* o
  *"edge"* a favor de Cortex.

**Conclusión:** no hay que migrar a Sinapsis. Para este problema concreto
Cortex está mejor posicionado; Sinapsis aporta exactamente **3 ideas robables**
(§5).

---

## 4. Opciones

| Opción | Qué es | Coste | Veredicto |
|---|---|---|---|
| A. Subir cap 15→25/50 | mismo modelo "todas siempre" | +400-1400 tok fijos | ❌ ruido; resatura pronto |
| **B. Split Core / Domain** | Core (~8 universales, siempre) + Domain (pool grande, inyectado por relevancia vía injector) | ~igual que hoy | ✅ desacopla cap de coste |
| C. B + per-injection token budget | B con tope de chars/tool-use (robado a Sinapsis) | self-limiting | ✅ variante fina de B |

**Recomendación: C** (B + per-injection cap).

---

## 5. Plan de implementación

### Fase 1 — Puente (EJECUTADO 2026-05-31, esta sesión)

- ✅ Swap atómico vía `manual_swap_promote`:
  `read-instructions-before-executing` (conf 0.99) IN como ley;
  `pattern-parallel-research-agents` archivada a `laws/archive/`.
  Logueado en `knowledge-log.md` (`swap-promoted`).
- ✅ Deuda `max_laws` 10→15 sincronizada: `core/memory.template.json`,
  `docs/FEATURES.md`, y `memory.json` vivo del operador.
- Resultado: 15/15 leyes, la universal #1 del sistema (9311 refuerzos) por fin
  inyectada.

### Fase 2 — Split Core / Domain (propuesta v3.34)

1. **Marcar leyes Core vs Domain.** Nuevo campo en el `.txt` de ley o índice
   `laws/_tier.json`: `{ "<law>": "core" | "domain" }`.
2. **Core (siempre-on, ~8):** `never-hardcode-secrets`, `conventional-commits`,
   `build-output-to-log`, `loop-reorient`, `advisor-escalation`,
   `delegate-by-model-routing`, `read-instructions-before-executing`,
   `deep-work-to-docs`.
3. **Domain (degradar de ley → instinct con `trigger`):** `project-bootstrap`,
   `agent-prompt-absolute-path`, `macos-downloads-read-tool`,
   `gotcha-fs-codex-broker-zombie`, `gotcha-agent-spawn-preflight`,
   `fersora-inbox-staging-only-not-final`,
   `pattern-parallel-explore-agents-new-project`.
   Cada una vuelve al cohort de instintos con su regex `trigger` original; el
   injector ya las inyecta cuando el contexto las dispara.
4. **`load_laws()` solo carga Core.** El cap Core se mantiene bajo (~8-10). El
   pool Domain deja de competir por plazas de ley.
5. **Migración segura:** mover una ley a Domain = `manual_swap`-equivalente que
   re-materializa el `.yaml` de instinto (no borra señal). Test e2e que
   verifique que ninguna Domain degradada deja de inyectarse cuando su trigger
   matchea (gate ejecutable, no AD-por-fase — ver instinct
   `gotcha-ad-por-fase-no-sustituye-e2e`).

### Fase 3 — Robos de Sinapsis (revisado 2026-05-31)

**Ya implementados (no hacer nada):** per-injection token cap
(`MAX_TOTAL_CHARS = 1500`, `injector-engine.js:332`) y domain dedup
(`seenDomains`, `injector-engine.js:334-340`). El injector ya ordena por
confidence desc, mete máx 1 por dominio, corta a 3 instintos / 1500 chars.

**Pendiente real (bajo, opcional):**
1. Exponer `MAX_TOTAL_CHARS` en `memory.json` config (hoy hardcodeado) para que
   sea ajustable como `max_instincts_per_injection`. Cambio trivial.
2. (Opcional) **Operator State** explícito cross-project — Fer ya lo cubre a
   medias en el Brain (`/Users/fmm/fersora/`); evaluar solapamiento antes.

**Starvation (revisado):** 143 instintos global en 16 dominios. El domain-dedup
llena las 3 plazas con los 3 dominios de mayor confidence que matcheen → sin
starvation por nº de dominios. Único riesgo: intra-dominio en `error-recovery`
(60 instintos, 1 plaza/inyección) — preexistente y by-design (gotcha-X de baja
señal). Las degradaciones Fase 2 no lo empeoran (triggers específicos, dominios
holgados: `general`/`gotcha`/`pattern`).

### TAREA A residual — 170 instintos sin `.yaml`

170 keys de `instinct-tracking.json` con count alto no tienen fichero `.yaml` →
no son inyectables. Materializar manualmente (con Fer validando) los de señal
real (ej. `release-version-quad-sync`, `gotcha-edit-changelog-unique-string`,
`gotcha-gitignore-docs-selective`). Curación, no script.

---

## 6. Riesgos / cuestiones abiertas

- **Starvation del lado Domain:** con `max_instincts_per_injection=3`, si muchas
  Domain matchean el mismo tool-use, solo entran 3 (ranking por confidence).
  Validar que el ranking prioriza bien antes de degradar leyes a Domain.
- **Desincronización tracking ↔ yaml** (300 keys vs 204 ficheros): hallazgo de
  integridad colateral; merece su propia limpieza (no bloquea Fase 2).
- **Reversibilidad:** toda degradación Core→Domain debe archivar el `.txt` (como
  hace `manual_swap_promote`), nunca borrar.
