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

### Step 1: Laws (Level 3 — always active)

Read all files from `~/.claude/cortex/laws/*.txt`.

Display each law (one-liner per file). Show count and estimated total tokens.

```
LAWS (Level 3 — always loaded):
  1. [law-id] — "One-liner content"
  2. [law-id] — "One-liner content"
  Total: N laws | ~T tokens
```

### Step 2: Instincts (Level 2 — on demand)

Scan both locations:
- Global: `~/.claude/cortex/instincts/global/*.yaml`
- Project: `~/.claude/cortex/projects/<hash>/instincts/*.yaml`

Detect current project via git remote hash or cwd.

Group by confidence tier and display:

```
INSTINCTS:

  Project: [name] ([hash])
  ----------------------------------------
  LAWS (0.9-1.0):
    [id]                    [domain]      [confidence]   [last_seen]

  INSTINCTS (0.7-0.9):
    [id]                    [domain]      [confidence]   [last_seen]

  PATTERNS (0.5-0.7):
    [id]                    [domain]      [confidence]   [last_seen]

  HYPOTHESES (0.3-0.5):
    [id]                    [domain]      [confidence]   [last_seen]

  OBSERVATIONS (0.0-0.3):
    [id]                    [domain]      [confidence]   [last_seen]

  Global:
  ----------------------------------------
  [same grouping]
```

### Step 2b: Knowledge by Domain

Using the instincts already parsed in Step 2 (both project and global), group by the `domain` YAML field and count per type.

For each unique domain found:
- **Instincts**: count of instincts in that domain (any confidence)
- **Law-tier**: count of instincts with confidence >= 0.90 in that domain

If an instinct has no `domain` field, count it under "unknown".
Sort domains by total instinct count (descending).

Display:

```
KNOWLEDGE BY DOMAIN:
  Domain              Instincts   Law-tier (≥0.90)
  ─────────────────────────────────────────────────
  database            5           2
  web-development     3           1
  testing             4           0
  workflow            2           0
  unknown             1           0
```

Note: Laws (.txt files) have no domain metadata — only instinct YAML files are counted.
Reflexes have no domain field — they are not included in this section.

### Step 3: Projects

Read `~/.claude/cortex/projects/registry.json`.

For EACH project hash in the registry, gather real data:
- **OBS**: count lines in `~/.claude/cortex/projects/<hash>/observations.jsonl` (use `wc -l`). Show 0 if file missing.
- **INST**: count `*.yaml` files in `~/.claude/cortex/projects/<hash>/instincts/` (use `ls | wc -l`). Show 0 if dir missing.

IMPORTANT: Do NOT skip projects or show "—" placeholders. Run a single bash loop over ALL hashes to collect counts efficiently:

```bash
for hash in $(cat ~/.claude/cortex/projects/registry.json | python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)]"); do
  obs=$(wc -l < ~/.claude/cortex/projects/$hash/observations.jsonl 2>/dev/null || echo 0)
  inst=$(ls ~/.claude/cortex/projects/$hash/instincts/*.yaml 2>/dev/null | wc -l | tr -d ' ')
  echo "$hash $obs $inst"
done
```

Display table sorted by LAST SEEN descending:

```
PROJECTS:
  NAME                ROOT                           LAST SEEN     OBS   INST
  my-saas             ~/github/my-saas               2026-03-27    142   8
  landing-page        ~/github/landing               2026-03-25    53    3
```

### Step 4: Reflexes

Read `~/.claude/cortex/reflexes.json`.

Display each reflex with its runtime stats. Highlight reflexes that have **never fired** (fireCount = 0 or missing) with a `[NEVER FIRED]` tag — these are candidates for removal or trigger tuning.

```
REFLEXES:
  ID                        MATCHER              SEVERITY    ENABLED  FIRES  LAST FIRED
  read-before-edit          Edit|Write           high        yes      87     today
  env-never-commit          git add|commit       critical    yes      12     2 days ago
  git-push-safety           git push             high        yes      0      [NEVER FIRED]
  security-headers          vercel.json          medium      no       0      [NEVER FIRED]

  Active: 8/10 | Never fired: 2 | Total fires: 247
```

### Step 5: System Health

Check each indicator:

```
SYSTEM HEALTH:
  Hooks active:          [yes/no] (check ~/.claude/settings.json)
  Last observation:      [timestamp or "never"]
  Disk usage:            [size of ~/.claude/cortex/]
  .learn-pending:        [yes/no — run /cx-analyze if yes]
  memory.json:           [populated/empty/missing]
```

### Step 6: Instinct Tracking (activation stats)

Read `~/.claude/cortex/instinct-tracking.json` if it exists.

Display the top 10 most activated instincts:

```
INSTINCT TRACKING (top 10 by activations):
  ID                          COUNT   SESSIONS   FIRST SEEN     LAST SEEN
  gotcha-rls-silent-fail      47      12         2026-03-15     2026-04-09
  pattern-test-after-change   38      15         2026-03-20     2026-04-09
  pref-touch-visible-buttons  22      8          2026-03-25     2026-04-08
```

If no tracking file exists, display: "No tracking data yet. Instinct tracking starts automatically on next tool use."

### Step 7: Evolved Content

Count files in each evolved directory:

```
EVOLVED:
  Skills:    N files in ~/.claude/cortex/evolved/skills/
  Commands:  N files in ~/.claude/cortex/evolved/commands/
  Rules:     N files in ~/.claude/cortex/evolved/rules/
```

## Output format

Use clean ASCII box format:

```
================================================================
  CORTEX STATUS
  Date: YYYY-MM-DD HH:MM
================================================================

  [Section 1: Laws]
  [Section 2: Instincts]
  [Section 3: Projects]
  [Section 4: Reflexes]
  [Section 5: System Health]
  [Section 6: Instinct Tracking]
  [Section 7: Evolved]

================================================================
  Total: N laws | N instincts (N project + N global) | N projects
================================================================
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
