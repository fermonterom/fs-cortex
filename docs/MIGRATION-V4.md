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

## Automatic v3-data adaptation (v4.5.0)

The installer and runtime were audited end-to-end against a realistic v3.37
data tree (sandboxed fresh install, v3-data upgrade, v4 re-install). Summary
of what a v3.x user gets, grouped by outcome:

**Self-heals (no action needed)**

- Legacy instincts without `status` inject as `confirmed`; `occurrences` is
  preserved as `occurrences_legacy` (see the section above).
- Missing `laws/laws-meta.json` is tolerated — every law defaults to tier
  `principle` and SessionStart renders normally (`load_laws` is tolerant of a
  missing or malformed meta file since v4.2.1).
- Missing v4 artifacts (`.review-digest.json`, `proposals-history.jsonl`,
  `instinct-tracking.json`, `.last-curate`) are created lazily by the first
  `/cx-maintain` / learner run that needs them.
- **`.last-learn-count` is seeded by the installer** (v4.5.0) from your
  existing observation count when upgrading from < 4, so the SessionStart
  "N+ new observations" banner counts since-upgrade instead of your entire
  v3 history.

**By-design resets (expected, not bugs)**

- Law-promotion maturity clocks restart: the deterministic gate counts
  `occurrences_v4` from zero and requires 3+ distinct projects again
  (`LAW_MIN_PROJECTS` was 1 in late v3).
- Legacy rejected proposals in `proposals-history.jsonl` become permanent
  tombstones — previously rejected patterns will not resurface as pending.

**Degrades silently / action needed**

- Hollow or corrupt legacy instinct YAMLs (action < 30 chars, raw-JSON
  fragments, unparseable frontmatter) are skipped at injection with no
  operator-visible signal. Run a session with `CORTEX_DEBUG=1` to list the
  skipped files, or delete/fix them.
- Pending v3 proposals in human-gated domains expire after 30 days
  (`PROPOSAL_TTL_DAYS`, v4.3.0) unless reviewed via `/cx-review`.
- v3-era cron/launchd jobs invoking deprecated commands (`/cx-distill`,
  `/cx-dream`, `/cx-analyze`, `/cx-validate`) exit 0 while doing nothing —
  reschedule them to `bin/cx-maintain.sh` (see "Scheduling" below).

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

**Recommended: `bin/cx-maintain.sh`, no LLM, no tokens.** The command's
Implementation section is also shipped as a standalone bash script that
calls the exact same `distill_engine.py` / `dream_cycle.py` /
`storage-rotation.js` functions directly — no `claude -p`, no model call
involved. It resolves the engine lib from the installed hooks
(`~/.claude/hooks/cortex/lib`) with a fallback to the repo's `hooks/lib`,
takes its own mkdir-based lock so overlapping scheduled runs don't race each
other, and always exits 0 on a clean pass (nonzero only on a real infra
failure — missing python3, missing engine lib). This is now the default way
to schedule maintenance; `claude -p "/cx-maintain"` still works for a manual
or interactive run.

**Cron (macOS/Linux)** — Sunday at 4am, script-based (preferred, zero token cost):

```cron
0 4 * * 0 /path/to/fs-cortex/bin/cx-maintain.sh >> ~/.claude/cortex/log/cx-maintain-cron.log 2>&1
```

**launchd (macOS)** — equivalent as a LaunchAgent, e.g.
`~/Library/LaunchAgents/com.fscortex.cx-maintain.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.fscortex.cx-maintain</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/fs-cortex/bin/cx-maintain.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>0</integer>
    <key>Hour</key><integer>4</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>/tmp/cx-maintain-launchd.log</string>
  <key>StandardErrorPath</key><string>/tmp/cx-maintain-launchd.log</string>
</dict>
</plist>
```

Load it with `launchctl load ~/Library/LaunchAgents/com.fscortex.cx-maintain.plist`.
Redirect `StandardOutPath`/`StandardErrorPath` to a real log location under
`~/.claude/cortex/log/` once created — `/tmp` is only illustrative here.

**Claude Code schedule** — if you prefer an LLM-driven trigger instead of
cron/launchd, register `/cx-maintain` through Claude Code's own `schedule`
feature (routine, weekly cadence, `/cx-maintain` as the prompt). This costs
tokens on every run, unlike `bin/cx-maintain.sh`.

After `/cx-maintain` (or `bin/cx-maintain.sh`) runs, check
`hooks/session-start.py`'s `[REVIEW] N items pendientes` badge at your next
SessionStart — that's your cue to run `/cx-review`.

## See also

- `docs/DESIGN-V4.md` — full design document (principles P1-P4, all 8
  numbered sections).
- `docs/SPEC-PORT-SINAPSIS.md` — exact values and code references for what
  was ported from Sinapsis v4.6.1 vs adapted to Cortex's own schema.
- `CHANGELOG.md` — the `[4.0.0]` entry has the complete Added/Fixed/Breaking
  list with file-level detail.
