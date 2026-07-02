# Migrating to Cortex v4.0.0

v4.0.0 ("signal-first, zero-decision") replaces the v3 command set and part
of the capture/injection engine. Full design rationale lives in
`docs/DESIGN-V4.md` and `docs/SPEC-PORT-SINAPSIS.md` (both gitignored, not
shipped in the public repo — this doc is the public-facing summary). If
you're on v3.x and running `bash install.sh` / `install.ps1` to upgrade,
read this first.

## Why v4

The diagnosis behind this release, in short: capture was starving every
downstream detector. `hooks/observe.py` rarely populated real `output`/`err_msg`
on tool calls, so the pattern detectors that fed `/cx-analyze` and
`/cx-validate` mostly worked off noise — raw JSON fragments, grep headers
misread as errors, npm log lines. The historical rejection rate on proposals
was 88.5%. On top of that, 20+ of the 22 commands that existed pre-v4 were
interactive — they asked questions, showed shorthand menus, waited for
confirmation — which meant none of them could be scheduled with cron or
Claude Code's own schedule feature. When Fer ran them by hand, most said
"nothing to do" because the signal had already died upstream. The system
looked idle because it was starved, not because there was nothing to learn.

v4 fixes both problems at the root instead of adding another validation gate
on top of bad data. Capture now guards against known noise patterns *before*
marking something an error (ported from
[Sinapsis](https://github.com/Luispitik/sinapsis-3.2/) v4.6.1, MIT, by Luis
Salgado — see `docs/SPEC-PORT-SINAPSIS.md` for exactly what was ported
literal and what was adapted to Cortex's own observation schema). And every
command is now either fully deterministic and cron-able (`/cx-maintain`) or a
single human-judgment step that batches everything deterministic maintenance
left over (`/cx-review`). Nothing in between.

## Command mapping (v3 → v4)

| v3 command | v4.0.0 | Notes |
|---|---|---|
| `/cx-analyze` | `/cx-maintain` | Pattern detection is now deterministic; no more Opus 1M interactive pass |
| `/cx-distill` | `/cx-maintain` | Law promotion, decay, `--swap` deprecation all folded in |
| `/cx-dream` | `/cx-maintain` | Dedup (now by subtopic, not domain), contradictions, staleness, cleanup |
| `/cx-promote` | `/cx-maintain` | Cross-project Jaccard promotion runs inside the engine pass |
| `/cx-backfill` | `/cx-maintain` | Legacy `session_id` recovery folded into the same pass |
| `/cx-validate` | `/cx-review` | Human-gated proposals now surface in the weekly digest |
| `/cx-evolve` | `/cx-review` | Evolve drafts wait in `evolved/skills/`; `/cx-review` installs or discards |
| `/cx-downvote` | `/cx-review` | Negative feedback recorded through the digest, not a standalone command |
| `/cx-retro` | `/cx-review` | Weekly retrospective is now part of the same weekly touchpoint |
| `/cx-timeline` | `/cx-status` | Knowledge event log accessible from the dashboard |
| `/cx-dashboard` | `/cx-status` | HTML dashboard generation frozen (no investment, `docs/DESIGN-V4.md` §8); `/cx-status` text is the official surface |
| `/cx-export` | `/cx-status` | Portable-skill export folded into status output |
| `/cx-audit` | workflow `cortex-audit` | No longer a slash command — invoke the `cortex-audit` skill/workflow directly for a deep multi-agent audit |
| `/cx-feedback` | *(removed)* | No direct substitute — feedback now flows through `/cx-review`'s digest |
| `/cx-feedback-auto` | *(removed)* | No direct substitute |
| `/cx-router` | *(removed)* | Command catalog with token costs is no longer needed at 7 active commands |
| `/cx-stop` | *(removed)* | Manual Stop-hook flush is no longer part of the supported surface |

Commands unchanged: `/cx-status`, `/cx-eod`, `/cx-gotcha`, `/cx-backup`,
`/cx-restore`.

Every deprecated command is still present as a `.md` stub in `commands/` — it
prints a one-line notice + its replacement and executes no legacy logic. Ask
Claude Code to run one and it will tell you where to go instead; nothing
breaks silently.

## What happens to your existing data

Nothing is deleted, and no migration script needs to run manually — the
compatibility rules below apply lazily, the first time each mechanism
touches a given file.

- **Existing instincts (no `status` field)**: treated as `status: confirmed`
  — they keep injecting exactly as before. Only instincts created after the
  v4 upgrade are born `status: draft` and need to earn `confirmed` (5+
  occurrences across 3+ distinct sessions) before they inject.
- **Occurrence counters**: `occurrences_v4` starts at 0 on the first
  `/cx-maintain` run for each instinct (`_ensure_occurrences_v4` in
  `hooks/lib/distill_engine.py`), lazily. The pre-v4 counter is preserved
  verbatim as `occurrences_legacy` — nothing is lost, it just stops counting
  toward the new deterministic law-promotion gate (which requires
  `occurrences_v4 >= 10`, counted post-fix).
- **Laws**: untouched. All active laws keep injecting at every SessionStart
  exactly as before; the only change is how *new* laws get promoted (see
  below) and that deprecation now goes through `/cx-review` instead of
  `/cx-distill --swap`.
- **`auto-distill-candidates.md`**: removed. If you had pending candidates in
  that file, they are not migrated — re-run `/cx-maintain`, and anything that
  meets the new deterministic gate gets promoted or shows up as a
  `law_candidates[]` entry in `/cx-review`'s digest with the specific reason
  it hasn't cleared yet.
- **Proposals (`proposals.json`)**: unaffected by the upgrade itself. Going
  forward, only proposals in human-gated domains (`correction`,
  `user-preference`, `decision`, `workflow`, `coupling`, `agent-quality`,
  `agent-evolution`, `error-recovery`) accumulate for `/cx-review`; the rest
  auto-validate inside `/cx-maintain`.

## Deterministic law promotion (replaces manual Criteria 8)

A law now promotes automatically, with no `law_eligible: true` flag to set by
hand, when **all** of these hold:

- `confidence >= 0.95`
- seen in `projects_seen >= 3` distinct projects
- `occurrences_v4 >= 10` (the post-fix counter described above)
- no noise feedback recorded in the last 14 days

`law_eligible: false` is still respected as an explicit veto if you set it.
Everything that doesn't clear the bar simply isn't a law candidate — it stays
a normal instinct, injected on-demand when its trigger matches, which
`docs/DESIGN-V4.md` argues is the correct behavior for narrow, project-scoped
knowledge anyway.

## Scheduling `/cx-maintain` weekly

`/cx-maintain` is deterministic and side-effect-safe to run unattended
(idempotent — every sub-step guards its own state). A lightweight
"maintain-lite" pass (decay + rotation) already runs once a day at
SessionStart automatically, so the schedule below is a weekly top-up, not a
requirement for the system to function — but without it, promotion/dedup
progress only advances on days you happen to open Claude Code.

**Cron (macOS/Linux)** — Sunday at 4am:

```cron
0 4 * * 0 claude -p "/cx-maintain" >> ~/.claude/cortex/log/cx-maintain-cron.log 2>&1
```

**Claude Code schedule** — equivalent, if you prefer not to touch crontab
directly, register the same command through Claude Code's own `schedule`
feature (routine, weekly cadence, `/cx-maintain` as the prompt).

After `/cx-maintain` runs, check `hooks/session-start.py`'s `[REVIEW] N items
pendientes` badge at your next SessionStart — that's your cue to run
`/cx-review`.

## See also

- `docs/DESIGN-V4.md` — full design document (principles P1-P4, all 8
  numbered sections).
- `docs/SPEC-PORT-SINAPSIS.md` — exact values and code references for what
  was ported from Sinapsis v4.6.1 vs adapted to Cortex's own schema.
- `CHANGELOG.md` — the `[4.0.0]` entry has the complete Added/Fixed/Breaking
  list with file-level detail.
