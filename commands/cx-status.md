---
name: cx-status
description: Unified Cortex dashboard — laws, instincts, projects, reflexes, system health
command: true
---

# /cx-status

## What it does

Unified dashboard showing the complete state of the Cortex learning system. Replaces the need for separate status, audit, projects, and watchdog commands.

## Help / Discovery

Si el usuario invoca `/cx-status --help`, muestra SOLO esta lista (sin ejecutar el dashboard) y stop:

```
/cx-status — Cortex unified dashboard

Sin flags:    Dashboard ASCII completo
--impact      Sprint 0 funnel panel (impact_log.py stats)
--pipeline    Knowledge pipeline dashboard
--reflexes    Reflex health panel
--reflect     Productivity patterns by time-of-day (v3.27.0+)
--days N      Lookback window in days (default 14)
--json        Machine-readable output
--ascii       ASCII (default)
--html        Placeholder v4.0
--help        Show this help
```

## Implementation

**Performance rule: ONE Bash call → JSON → render.**
Do NOT make multiple rounds of Bash calls to gather data. Run the collector script below as a single Bash call. It outputs a JSON blob with all dashboard data. Parse that JSON and render the ASCII output — zero additional tool calls needed for the default dashboard.

### Collector script (single Bash call)

```bash
python3 << 'COLLECTOR'
import os, re, glob, json, subprocess, time

CORTEX = os.path.expanduser("~/.claude/cortex")
HOME   = os.path.expanduser("~")
CWD    = os.getcwd()

# ── 1. Laws ──────────────────────────────────────────────────────────────────
laws = []
for f in sorted(glob.glob(f"{CORTEX}/laws/*.txt")):
    lid = os.path.basename(f)[:-4]
    try:
        with open(f) as fh:
            content = fh.readline().strip()
    except Exception:
        content = "?"
    laws.append({"id": lid, "content": content})

# ── 2. Detect current project hash ───────────────────────────────────────────
proj_hash = None
proj_name = None
registry  = {}
try:
    with open(f"{CORTEX}/projects/registry.json") as fh:
        registry = json.load(fh)
    for h, meta in registry.items():
        root = meta.get("root", "")
        if root and (CWD.startswith(root) or root == CWD):
            proj_hash = h
            proj_name = meta.get("name", h[:8])
            break
except Exception:
    pass

# ── 3. Parse instinct YAMLs (regex, no pyyaml dep) ───────────────────────────
def parse_yaml_flat(path):
    d = {}
    try:
        with open(path) as fh:
            for line in fh:
                m = re.match(r'^([\w][\w_-]*):\s*(.+)', line.strip())
                if m:
                    d[m.group(1)] = m.group(2).strip("\"'")
    except Exception:
        pass
    return d

def load_instincts(dirpath):
    out = []
    for f in glob.glob(f"{dirpath}/*.yaml"):
        d = parse_yaml_flat(f)
        try:
            conf = round(float(d.get("confidence", 0)), 2)
        except Exception:
            conf = 0.0
        ls = d.get("last_seen", "?")
        if ls and ls != "?" and len(ls) >= 10:
            ls = ls[:10]
        # v4 (SPEC-PORT-SINAPSIS.md §2): status field — draft (tracked, not
        # injected) vs confirmed (injectable). Legacy instincts predate the
        # field; default to "confirmed" per the spec's grandfather rule.
        status = (d.get("status", "confirmed") or "confirmed").strip().lower()
        out.append({
            "id":         d.get("id", os.path.basename(f)[:-5]),
            "domain":     d.get("domain", "unknown"),
            "confidence": conf,
            "last_seen":  ls,
            "status":     status,
        })
    return sorted(out, key=lambda x: -x["confidence"])

proj_instincts   = load_instincts(f"{CORTEX}/projects/{proj_hash}/instincts") if proj_hash else []
global_instincts = load_instincts(f"{CORTEX}/instincts/global")

# ── 4. Projects: obs + inst counts (single loop) ─────────────────────────────
projects = []
for h, meta in registry.items():
    obs_file = f"{CORTEX}/projects/{h}/observations.jsonl"
    inst_dir = f"{CORTEX}/projects/{h}/instincts"
    try:
        with open(obs_file) as fh:
            obs = sum(1 for _ in fh)
    except Exception:
        obs = 0
    inst = len(glob.glob(f"{inst_dir}/*.yaml"))
    root_short = meta.get("root", "?").replace(HOME, "~")
    projects.append({
        "hash":      h,
        "name":      meta.get("name", h[:8]),
        "root":      root_short,
        # AD fix #6 (2026-07-02): the registry writer (hooks/observe.py
        # update_registry, ~line 392) writes snake_case `last_seen`; this
        # reader looked for camelCase `lastSeen` and always fell through to
        # "?". Read both, preferring the field the writer actually uses.
        "last_seen": meta.get("last_seen", meta.get("lastSeen", "?")),
        "obs":       obs,
        "inst":      inst,
        "current":   h == proj_hash,
    })
projects.sort(key=lambda x: -x["obs"])

# ── 5. Reflexes ───────────────────────────────────────────────────────────────
reflexes = []
try:
    with open(f"{CORTEX}/reflexes.json") as fh:
        reflexes = json.load(fh).get("reflexes", [])
except Exception:
    pass

# ── 6. System health ──────────────────────────────────────────────────────────
hook_count = 0
try:
    with open(os.path.expanduser("~/.claude/settings.json")) as fh:
        s = json.load(fh)
    hook_count = sum(len(v) for v in s.get("hooks", {}).values())
except Exception:
    pass

last_obs = "never"
if proj_hash:
    try:
        with open(f"{CORTEX}/projects/{proj_hash}/observations.jsonl") as fh:
            lines = fh.readlines()
        if lines:
            last_obs = json.loads(lines[-1]).get("ts", "?")
    except Exception:
        pass

disk = "?"
try:
    disk = subprocess.run(["du", "-sh", CORTEX], capture_output=True, text=True).stdout.split()[0]
except Exception:
    pass

mem_size = 0
try:
    mem_size = os.path.getsize(f"{CORTEX}/memory.json")
except Exception:
    pass

# v4 — próximo /cx-maintain: weekly cadence, tracked via the `.last-distill`
# compat marker /cx-maintain touches on every run (same marker
# hooks/session-start.py:check_maintenance reads for its [MAINT] reminder).
next_maintain = "never run"
try:
    mtime = os.path.getmtime(f"{CORTEX}/.last-distill")
    age_days = (time.time() - mtime) / 86400
    due_in = 7 - age_days
    if due_in <= 0:
        next_maintain = f"OVERDUE by {abs(due_in):.1f}d — run /cx-maintain"
    else:
        next_maintain = f"in {due_in:.1f}d"
except Exception:
    pass

review_digest_items = 0
try:
    with open(f"{CORTEX}/.review-digest.json") as fh:
        review_digest_items = int(json.load(fh).get("total_items", 0) or 0)
except Exception:
    pass

# ── 7. Instinct tracking ──────────────────────────────────────────────────────
tracking_top = []
try:
    with open(f"{CORTEX}/instinct-tracking.json") as fh:
        tracking = json.load(fh)
    for k, v in sorted(tracking.items(), key=lambda x: x[1].get("count", 0), reverse=True)[:10]:
        sess = v.get("sessions", [])
        tracking_top.append({
            "id":       k,
            "count":    v.get("count", 0),
            "sessions": len(sess) if isinstance(sess, list) else (int(sess) if isinstance(sess, (int, float)) else 0),
        })
except Exception:
    pass

# ── 8. Evolved counts ─────────────────────────────────────────────────────────
evolved = {
    "skills":   len(glob.glob(f"{CORTEX}/evolved/skills/*")),
    "commands": len(glob.glob(f"{CORTEX}/evolved/commands/*")),
    "rules":    len(glob.glob(f"{CORTEX}/evolved/rules/*")),
}

print(json.dumps({
    "laws":             laws,
    "proj_hash":        proj_hash,
    "proj_name":        proj_name,
    "proj_instincts":   proj_instincts,
    "global_instincts": global_instincts,
    "projects":         projects,
    "reflexes":         reflexes,
    "health": {
        "hook_count":    hook_count,
        "last_obs":      last_obs,
        "disk":          disk,
        "learn_pending": os.path.exists(f"{CORTEX}/.learn-pending"),
        "mem_size":      mem_size,
        "next_maintain": next_maintain,
        "review_digest_items": review_digest_items,
        "instincts_draft":     sum(1 for i in proj_instincts + global_instincts if i["status"] == "draft"),
        "instincts_confirmed": sum(1 for i in proj_instincts + global_instincts if i["status"] != "draft"),
    },
    "tracking_top": tracking_top,
    "evolved":      evolved,
}))
COLLECTOR
```

### Render from JSON output

Parse the single JSON blob and render the **visual** ASCII dashboard (glance
first, detail on request). Nothing from the collector is dropped — anything
that does not fit the glance moves to a compact secondary line inside its
own section, never removed. Semaphore thresholds are fixed below so the
render is deterministic across runs/models (rule f).

**Semaphore legend:** 🟢 todo OK · 🟡 atención (no bloquea) · 🔴 acción
requerida · ⚪ sin datos suficientes.

#### Threshold table (source of truth — do not improvise a different cut)

| Señal | Campo del collector | 🟢 | 🟡 | 🔴 |
|---|---|---|---|---|
| Maintain | `health.next_maintain` (parse `due_in` days) | due_in ≥ 2d | 0 ≤ due_in < 2d ("vence pronto") | due_in < 0 o "never run" (overdue) |
| Review digest | `health.review_digest_items` | 0 | 1–10 | > 10 |
| Reflexes noisy | `reflexes[]` vía reglas `--reflexes` (abajo) | noisy == 0 | — (no aplica en este resumen) | noisy ≥ 1 |
| Obs vivas | `health.last_obs` (antigüedad) | ≤ 48h | 48h – 7d | > 7d o "never"/no parseable |
| LAWS | `len(laws)` vs cap fijo **15** (`LAW_MAX_ACTIVE`, `docs/FEATURES.md`) | < 14 | == 14 (1 hueco libre) | ≥ 15 (cap alcanzado, bloquea nuevas promociones) |
| INSTINCTS | `health.instincts_draft` (backlog sin confirmar) | ≤ 10 | 11–30 | > 30 |
| REFLEXES (sección completa) | agregados de `reflexes[]` | noisy == 0 AND borderline ≤ 5 | borderline > 5 (y noisy == 0) | noisy ≥ 1 |
| SISTEMA | `health.hook_count`, `health.learn_pending` | hook_count > 0 AND learn_pending == false | learn_pending == true (hook_count > 0) | hook_count == 0 (hooks no registrados en `settings.json` — proxy de "learn errors", el collector no expone un contador de errores real) |

**SALUD GLOBAL** = el peor semáforo entre {Maintain, Review digest, Reflexes
noisy, Obs vivas, LAWS, INSTINCTS, REFLEXES, SISTEMA}. 🔴 si cualquiera es
🔴, si no 🟡 si cualquiera es 🟡, si no 🟢.

**Header** — `🧠 CORTEX v4 ── {fecha/hora actual de la sesión} ── proyecto:
{proj_name o "sin detectar"}`. La fecha/hora sale del contexto de la sesión
(no dispares una segunda llamada Bash solo para `date`; si no hay hora
precisa disponible, muestra solo la fecha).

**LAWS** — `📜 LAWS {semáforo} {len(laws)}/15 ······· ~{len(laws)*38} tok/sesión`.
Segunda línea: ids separados por ` · `, envueltos a ~70 cols. El primer
renglón de `content` de cada law (tooltip) solo se muestra si el usuario
pide detalle explícito (`/cx-status --help` no cuenta; hay que pedirlo en la
conversación) — sigue disponible en el JSON, no se pierde.

**INSTINCTS** — `🧬 INSTINCTS {semáforo} {total} ({N proyecto} + {N global}) · draft {health.instincts_draft} → confirmed {health.instincts_confirmed}`.
Segunda línea: barra de confianza por tier (LAWS ≥.90, INSTINCTS .70-.89,
PATTERNS .50-.69, HYPOTHESES .30-.49, OBSERVATIONS <.30 — omite tiers en 0).
Escala de barras (máx 14 caracteres): `bar_len = max(1, floor(tier_count /
max_tier_count * 14))` si `tier_count > 0`, si no 0 caracteres. `max_tier_count`
es el conteo del tier más numeroso. Formato por tier: `conf ≥.90 {barra}
{count}   .70-.89 {barra} {count}   .50-.69 {barra} {count}` (omite tiers
vacíos). Tercera línea: `domains: {top4 "domain N" separados por · } · +resto {suma del resto}`
— agrupa `proj_instincts + global_instincts` por `domain`, ordena desc,
top 4 inline, el resto se suma en un solo `+resto N` (si el resto es 0, omite
el segmento).

**PROJECTS** — sin semáforo (informativo). `📁 PROJECTS (top 5 por obs, ◀ =
actual)` + una línea `name {obs formateado} {◀ si current} · name {obs} ...`.
Formato de `obs`: `f"{obs/1000:.1f}k"` si `obs >= 1000`, si no el entero tal
cual. Segunda línea compacta: `Detalle completo (root · hash corto · inst ·
last_seen) de las {len(projects)} entradas → pide "proyectos detalle" o usa
--json.` — el resto de `projects` sigue en el JSON, no se descarta.

**REFLEXES** — `⚡ REFLEXES {semáforo} {len(reflexes)} → 🟢×{healthy} 🟡×{borderline} ⚪×{unknown} 🔴×{noisy}`
usando las reglas STATUS ya definidas para `--reflexes` (healthy/borderline/
NOISY/unknown, ver más abajo — misma fuente, no la dupliques con otro
criterio). Segunda línea (leyenda fija): `(🟢 healthy · 🟡 borderline · ⚪ sin
datos · 🔴 noisy→candidato a disable)`. Detalle por reflex individual
(fireCount/usefulCount/noiseCount/condition/enabled) vía `/cx-status
--reflexes` — no se repite aquí para no duplicar la sección dedicada.

**SISTEMA** — `🔧 SISTEMA {semáforo}  hooks {health.hook_count} · disco
{health.disk} · última obs hace {antigüedad relativa de health.last_obs} ·
learn-pending {"⚠ sí" si true, si no "✓ no"}`. Segunda línea compacta:
`memory.json: {health.mem_size formateado en KB/MB}`. Render `next_maintain`
y `review_digest_items` en el cuadro SALUD GLOBAL de cabecera (no los
repitas aquí, ya están cubiertos ahí con su propio semáforo).

**TOP TRACKING** — sin semáforo. `📈 TOP TRACKING (occurrences_v4, contador
honesto v4)` + una línea con los top 5 de `tracking_top` como `{id}×{count}
(s{sessions})` separados por ` · ` si caben en ~100 cols; si no caben,
parte en 2 líneas de hasta 3 entradas cada una (nunca se corta un id a
medias). Si `tracking_top` está vacío: `No tracking data yet.`

**EVOLVED** — sin semáforo. Si `evolved.skills + evolved.commands +
evolved.rules == 0`: `🚀 EVOLVED: 0 drafts pendientes`. Si > 0: `🚀 EVOLVED:
{total} drafts pendientes ({skills} skills · {commands} commands · {rules}
rules)`.

## Output format

Usa el formato visual siguiente (plantilla obligatoria — mantiene toda la
info del formato anterior, reorganizada para lectura de un vistazo):

```
🧠 CORTEX v4 ── 2026-07-02 17:05 ── proyecto: fersora
┌─────────────────────────────────────────────────────────┐
│  SALUD GLOBAL: 🟢 TODO OK   (o 🟡 ATENCIÓN / 🔴 ACCIÓN) │
│  🟢 Maintain in 6.9d   🟢 Review al día   🟢 Reflexes 0 noisy   🟢 Obs vivas │
└─────────────────────────────────────────────────────────┘

📜 LAWS 🟢 8/15 ······· ~304 tok/sesión
   advisor-escalation · build-output-to-log · deep-work-to-docs · e2e-playwright
   loop-reorient · macos-downloads · project-bootstrap · read-instructions
   (id corto + tooltip: primera línea solo si el usuario pide detalle)

🧬 INSTINCTS 🟢 127 (62 proyecto + 65 global) · draft 0 → confirmed 127
   conf ≥.90 ██████████████ 66   .70-.89 █████████ 45   .50-.69 ███ 16
   domains: workflow 35 · gotcha 34 · pattern 16 · tool-pref 11 · +resto 35

📁 PROJECTS (top 5 por obs, ◀ = actual)
   fs-cortex 15.0k · fersora 11.3k ◀ · fs-vps-playbook 3.7k · LinkedIn 3.4k · ceo-dash 2.0k

⚡ REFLEXES 🟢 23 → 🟢×16 🟡×3 ⚪×4 🔴×0
   (🟢 healthy · 🟡 borderline · ⚪ sin datos · 🔴 noisy→candidato a disable)

🔧 SISTEMA 🟢  hooks 7 · disco 169M · última obs hace Xmin · learn-pending ✓ no
   memory.json: 42 KB

📈 TOP TRACKING (occurrences_v4, contador honesto v4)
   id×count(sN) top 5 en una o dos líneas si caben

🚀 EVOLVED: 0 drafts pendientes
```

## Flags

Available flags: `--impact` `--pipeline` `--reflexes` `--reflect` `--days N` `--json` `--ascii` `--html` `--help`

### `--help` — Show command reference

See [Help / Discovery](#help--discovery) section above for the complete flag list. No dashboard is rendered.

### `--impact` — Sprint 0 funnel panel (v3.14.0+)

Skip the full dashboard and show only the impact funnel from `impact.jsonl`.
Invokes:

```bash
python3 ~/.claude/hooks/cortex/lib/impact_log.py stats --days 14
```

Output includes:
- Event totals (inject / follow / reject / feedback / outcome)
- `useful_ratio`, `noise_ratio`, `health_ratio` (see `docs/IMPACT-METRICS.md`)
- Sprint 0.5 Go/No-Go Gate recommendation (`GO` / `PARTIAL` / `NO-GO`)
- Top 10 useful instincts (candidates to promote)
- Top 10 noisy instincts (candidates to deprecate)

Supports `--days N` to change the lookback window (default 14). Pass
`--json` for machine-readable output suitable for dashboards.

**Reset-aware aggregation (v3.22.1+)** — when a reflex carries an
optional `resetAt` ISO-8601 timestamp in `reflexes.json`, this panel
discards `reflex:X` events whose `ts < resetAt[X]`. This keeps Gate 1
honest after matcher-refining releases (v3.20.0 reset the three
`bash-*` reflexes; their pre-refinement evidence is no longer
attributable to the current matcher). Other callers — `rotate()`,
`outcome-ranking`, `outcome-nudge` — leave the boundary disabled and
see raw history.

### `--pipeline` — Knowledge pipeline dashboard (v3.23.1+)

Skip the full dashboard and show a consolidated view of pipeline activity
(validate → promote → evolve → maintain) over the last N days.

Invokes:

```bash
python3 ~/.claude/hooks/cortex/lib/distill_engine.py pipeline-stats --days 14
```

Output sections:

- **VALIDATE** — auto-accepted proposals (cx-auto-validate), manual accepts/rejects
  (cx-validate), pending proposals broken down by domain and whitelist eligibility
- **PROMOTE** — auto-promoted instincts to laws (cx-auto-distill), manual promotions
  (cx-distill), candidates queued in `auto-distill-candidates.md`, active law count
- **EVOLVE** — auto-generated skill drafts (cx-auto-evolve), manually evolved skills
  (cx-evolve), draft files pending review in `evolved/skills/`
- **MAINTENANCE** — decayed instincts (-0.05 each) and archived instincts (conf < 0.10)
- **LAST RUNS** — mtimes of `.last-auto-distill`, `.last-distill`, `.last-audit`,
  `.learn-pending` / `.last-learn-count`, and today's `daily-summaries/` entry

Supports `--days N` (default 14) to change the lookback window.
Pass `--json` for machine-readable output.

Note: `auto-*` events (cx-auto-validate, cx-auto-evolve) come from Sprint 7+ (v3.23.0+).
Pre-Sprint-7 acceptances have no `accepted_by` field in proposals.json and are counted
under `manual_accepted` (source=cx-validate).

### `--reflexes` — Reflex health panel (v3.18.0+)

Skip the full dashboard and show a per-reflex health table from
`reflexes.json`. Reads `fireCount`, `usefulCount`, `noiseCount`, and
`enabled` to surface candidates for auto-disable (and to show which
reflexes are actually pulling their weight).

Output (ASCII):

```
REFLEX HEALTH (v3.18.0+):
  ID                    FIRES   USEFUL   NOISE   ENABLED   STATUS
  ───────────────────────────────────────────────────────────────────
  read-before-edit       1171    1100      45    yes       healthy
  env-never-commit       1171    1170       0    yes       healthy
  bash-find-use-glob       45      30      12    yes       borderline
  bash-cat-use-read        67      10      48    yes       NOISY (auto-disable candidate)
  ...

  Healthy   : 7   (useful >= 10 AND noise < 3)
  Borderline: 2   (noise == 1 OR noise == 2)
  Noisy     : 1   (noise >= 3 AND fireCount >= 10 AND useful < noise — auto-disable candidate)
  Unknown   : 0   (fireCount < 10 — not enough data)
```

`STATUS` rules (must mirror the auto-disable gate at
`hooks/session-learner.js:1313-1336`):
- `healthy`     → `usefulCount >= 10 AND noiseCount < 3`
- `borderline`  → `noiseCount == 1 OR noiseCount == 2`
- `NOISY`       → `noiseCount >= 3 AND fireCount >= 10 AND usefulCount < noiseCount` (auto-disable candidate)
- `unknown`     → `fireCount < 10` (insufficient data to judge)

The `usefulCount < noiseCount` clause was added in v3.24.2 to keep this
panel in sync with the v3.24.1 auto-disable gate. Pre-v3.24.2 the
panel would label a healthy-but-noisy reflex (e.g. `useful=116,
noise=5`) as a candidate even though the runtime would never disable
it. The label and the gate now agree.

If `CORTEX_AGENT_DISABLE_REFLEXES=1` is set, NOISY reflexes are
auto-disabled by `session-learner.js` at next Stop event. Without the
flag, the threshold is tracked but no state change happens — see
[`docs/AUTO-EVALUATION.md`](../docs/AUTO-EVALUATION.md).

Pass `--json` for machine-readable output (same shape as ASCII data).

### `--reflect` — Productivity patterns (v3.27.0+)

Read `~/.claude/cortex/productivity-patterns.json` (written by `detectTimeOfDayPatterns` in `session-learner.js` on each session close).

If the file does not exist, output:
```
PRODUCTIVITY REFLECTION
  No data yet. Productivity patterns are generated automatically as you work.
  Patterns will appear after several sessions across multiple times of day.
```

If the file exists, format as:
```
PRODUCTIVITY REFLECTION (last updated: <date>)

By Hour (top 3 tools, error rate):
  HH: tool(N) tool(N) tool(N)   err X%   total: N
  ...

Buckets:
  Morning   (06-12):   N obs   X% err   top: T1, T2
  Afternoon (12-18):   N obs   X% err   top: T1, T2
  Evening   (18-22):   N obs   X% err   top: T1, T2
  Night     (22-06):   N obs   X% err   top: T1, T2

Insights:
  • <insight 1>
  • <insight 2>
  ...
```

If `--json` is also passed, output the raw JSON file contents instead.

### `--ascii` (default) vs `--html`

Placeholder for v4.0 — `--html` will delegate to the dashboard generator
(`hooks/lib/dashboard_gen.py`). Until Sprint 2, use `/cx-dashboard`.

## What NOT to do

- Do not invent data that does not exist in the files
- Do not modify any files — this is a read-only command
- Do not show raw observations, only processed instincts
- If a directory or file does not exist, show "not found" for that section, do not error out
