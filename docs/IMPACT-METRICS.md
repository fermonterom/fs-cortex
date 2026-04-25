# IMPACT-METRICS — Canonical definitions for the fs-cortex impact funnel

> Introduced in **v3.14.0** (Sprint 0 · Instrumentation).
> Writer: `hooks/lib/impact_log.py` + `hooks/lib/impact_log.js`.
> Event log: `~/.claude/cortex/impact.jsonl`.
> Feedback mirror: `~/.claude/cortex/feedback.jsonl`.

This document is the source of truth for how fs-cortex measures whether it
helps a human developer. Everything else — the Go/No-Go Gate, `/cx-status
--impact`, `/cx-feedback`, future A/B experiments — reads from here.

---

## Why this exists

The Devil's Advocate audit (2026-04-24) concluded that fs-cortex measured
**use** (observation count, injection count, proposals) but never **impact**
(did an instinct actually avoid an error or save time?). Without that
signal, the system could grow indefinitely without evidence that any of it
helps.

Sprint 0 adds a single JSONL funnel that links every stage:

```
observation → inject → follow | reject → outcome
                         ↘ feedback ↙
```

---

## Event schema (v1)

Every line in `impact.jsonl` is a JSON object with these fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `v`   | int  | yes      | schema version (currently `1`) |
| `ts`  | string ISO-8601 UTC | yes | event timestamp, `YYYY-MM-DDTHH:MM:SSZ` |
| `ev`  | string enum | yes | one of `inject`, `follow`, `reject`, `feedback`, `outcome` |
| `iid` | string | when applicable | instinct id |
| `tool`| string | `inject` only | Claude Code tool name (Bash, Edit, …) |
| `pid` | string | `inject` | project id (sha256 prefix of git remote) |
| `sid` | string | all except rotation | session id |
| `conf`| float  | `inject` | confidence of the injected instinct (0.00-1.00) |
| `dom` | string | `inject` | instinct domain (gotcha, e2e, security, …) |
| `followed` | bool | `follow` | next tool call matched the instinct semantics |
| `err_after` | bool | `follow` | any tool in next 10 events reported `is_error` |
| `win` | int    | `follow` | window size actually inspected |
| `inject_ts` | string | `follow` | ts of the inject event this follow correlates with (dedup key) |
| `reason` | string | `reject` | why the next call did not match (e.g., `unrelated`) |
| `rating` | string enum | `feedback` | `useful` \| `noise` \| `ignore` |
| `note` | string | `feedback` | optional human rationale, ≤500 chars |
| `error_within_10` | bool | `outcome` | whether an error happened within 10 tool uses (future) |

### Event semantics

- **`inject`** — Emitted by `hooks/lib/injector-engine.js` for every
  instinct that passes all filters (domain, dedup, token budget) and ends
  up in the PreToolUse context.
- **`follow`** — Emitted by `hooks/session-learner.js` at session end.
  For each `inject` without a matching `follow`, find the first subsequent
  observation of the same session and evaluate `followed`/`err_after`.
- **`reject`** — Reserved for a future explicit detector. Currently the
  "not followed" case is encoded as `follow` with `followed:false`.
- **`feedback`** — Emitted by `/cx-feedback` when the human rates the
  last injection as useful / noise / ignore.
- **`outcome`** — Reserved for Sprint 5 (auto-ranking by apply-rate).

---

## Canonical formulas

The only metrics that downstream consumers should depend on:

```
useful_event = (feedback.rating == "useful")
             OR (follow.followed == true AND follow.err_after == false)

noise_event  = (feedback.rating == "noise")
             OR (follow.followed == false)
             OR (reject event exists for the inject)

useful_ratio = count(useful_event) / count(inject)
noise_ratio  = count(noise_event)  / count(inject)

health_ratio = useful_ratio / max(noise_ratio, 0.01)
```

Notes:
- **Correlation, not causation.** A `useful` signal does not prove the
  instinct caused the outcome; it proves the two were positively
  correlated. This is a known limitation (DA audit finding). V4.1 may
  add a temporal A/B experiment (1 day off per week) if the user consents.
- **Per-instinct stats** aggregate the same events grouped by `iid`.
  `compute_metrics()` returns `top_useful` and `top_noisy` lists sorted by
  count descending, capped at 10 entries each.
- **Events older than 30 days** are moved to
  `~/.claude/cortex/impact.archive/` by `rotate()`.

---

## Sprint 0.5 — Go/No-Go Gate

After **14 days** of data in `impact.jsonl` with Sprint 1 bugfixes
already applied, run:

```bash
/cx-status --impact --days 14
# or directly
python3 ~/.claude/hooks/cortex/lib/impact_log.py stats --days 14
```

The gate recommendation is deterministic:

| Condition | Recommendation | Plan impact |
|-----------|----------------|-------------|
| `useful_ratio ≥ 0.25` AND `health_ratio ≥ 1.5` | **GO** | Continue v4.0 plan (sprints 2-7) |
| `0.10 ≤ useful_ratio < 0.25` OR `1.0 ≤ health_ratio < 1.5` | **PARTIAL** | Only Sprints 2 + 3 + 4 (docs, comandos, installer). Sprints 5-7 dropped. Release as v4.0 minimal. |
| `useful_ratio < 0.10` OR `health_ratio < 1.0` | **NO-GO** | Only Sprint 1 (bugfixes) + Sprint 3.1 (docs). Release as v3.14.x consolidation. Consider trimming Cortex to 30%. |

The decision remains human — the gate produces a number, the user signs off.

---

## Privacy and retention

- `impact.jsonl` stores **instinct ids, tool names, session ids, project
  id prefixes (sha256), domains, confidence, and free-text feedback notes**.
- It does **NOT** store: code, file paths, tool inputs, tool outputs,
  error messages. Those live in `observations.jsonl`, which has its own
  scrubbing pipeline.
- Free-text `note` fields in feedback are sanitized with the same blocked
  keywords as injector sanitization before being written.
- Rotation to archive at 30 days (`impact.archive/impact-<ts>.jsonl`).
- `/cx-share --export` will apply the same aggressive redaction as
  observations when bundling for external sharing (Sprint 6).

---

## Testing

`tests/test_impact.sh` (13 tests) covers:

1. Python library imports cleanly
2. JS library requires cleanly
3. CLI `log` command appends one event
4. Schema v:1 fields are present and correct
5. JS writer produces schema-compatible events
6. Python + JS events are mutually parseable
7. Feedback event mirrors to `feedback.jsonl`
8. `compute_metrics()` matches canonical formulas on a fixed fixture
9. Gate recommendation returns `GO` / `PARTIAL` / `NO-GO` correctly
10. Concurrent writes (10 parallel `log` invocations) do not corrupt
11. `rotate()` archives events older than 30 days
12. Invalid event names raise `ValueError`
13. Invalid feedback ratings raise `ValueError`

Run with:

```bash
bash tests/test_impact.sh
```

---

## Stability contract

Schema version `v:1` is frozen. Any change requires:

- Bump `SCHEMA_VERSION` in both `impact_log.py` and `impact_log.js`
- Migration script in `scripts/migrate-impact-vN-to-vN+1.py`
- Backward-compatible read for at least one release

Consumers (dashboards, `/cx-status --impact`, future A/B experiments) must
handle unknown fields gracefully — extra keys are allowed and ignored.

---

## Referenced by

- `hooks/lib/injector-engine.js` — emits `inject` events
- `hooks/session-learner.js` — emits `follow` events
- `commands/cx-feedback.md` — emits `feedback` events
- `commands/cx-status.md` — reads funnel via `--impact` flag
- `tests/test_impact.sh` — regression coverage
- `CHANGELOG.md` v3.14.0 entry
- `/Users/fmm/.claude/plans/analiza-toda-la-informaci-n-enchanted-salamander.md` — plan Sprint 0 / Sprint 0.5
