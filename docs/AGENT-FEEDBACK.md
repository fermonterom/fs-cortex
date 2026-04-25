# AGENT-FEEDBACK — Splitting human and agent signal in the impact funnel

> Introduced in **v3.17.0** (Sprint 0 · Instrumentation, follow-up to v3.14.0).
> Extends [`IMPACT-METRICS.md`](IMPACT-METRICS.md) with a `source` field
> on `feedback` events.
> Writer: `hooks/lib/impact_log.py`.

This document is the architectural decision record for **why feedback events
must distinguish between human ratings and agent self-ratings**, and the
contract by which the Sprint 0.5 Go/No-Go Gate stays a measure of human
value, not agent self-affirmation.

---

## Problem

The Sprint 0 funnel (v3.14.0) introduced one positive feedback channel:
`/cx-feedback useful|noise|ignore`. The implicit assumption was that the
human rates every injection.

In practice, injections fall into two categories that the human cannot
evaluate symmetrically:

### Type A — User-visible instincts
Gotchas, security policies, domain rules, release checklists. The user
sees the resulting code (an RLS policy with `auth.uid()`, a release with
the version bumped) and can judge whether the inject changed the outcome.

Examples: `gotcha-rls-silent-fail`, `fs-cortex-release-checklist`,
`gotcha-agent-spawn-preflight`.

### Type B — Agent-internal reflexes
Tool-choice rules. `find` → `Glob`, `cat` → `Read`, "read before edit".
The user does not see which tool the agent picked under the hood; the
agent does. Asking the user to rate `bash-find-use-glob useful` requires
the user to know the relative cost of each tool — knowledge they do not
have, by design.

The DA-style follow-up audit (this session, 2026-04-25) concluded that
forcing the human to rate Type B injections produces noise on the
`useful_ratio` metric in two directions:

1. **Bias-up.** A user who blindly votes `useful` on every reflex will
   inflate the ratio without the inject having created value.
2. **Bias-down.** A user who skips reflex feedback (because they don't
   understand them) leaves the agent-side signal silent, and the most
   common injections (~60% of the corpus on this workstation) never
   contribute to the gate.

Either way, the **Go/No-Go Gate stops measuring human value** and starts
measuring something else.

---

## Decision

Add a `source` field to every `feedback` event:

| `source` | Who emits | Subject typically | Counts toward |
|----------|-----------|--------------------|----------------|
| `user`   | `/cx-feedback` (default) | Type A instincts | `useful_ratio_user` (gate input) |
| `agent`  | `/cx-feedback-auto` | Type B reflexes & tool-choice instincts | `useful_ratio_agent` (diagnostic only) |

The Sprint 0.5 Gate uses **`useful_ratio_user`** exclusively. The agent
ratio is computed and surfaced in `/cx-status --impact` for
introspection but does **not** flip the gate.

This is intentionally asymmetric. Human feedback is the scarce, signal-
rich channel. Agent self-rating is plentiful but partially circular
(the agent that produced the injection is also the one that judges it).
Mixing them in a single ratio destroys the property the gate was meant
to measure: *"does Cortex help a human developer?"*

---

## Schema addition

The v1 schema gains one optional field on `feedback` events:

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `source` | string enum | no | `"user"` | One of `"user"`, `"agent"` |

Existing readers ignore unknown fields (per the Stability contract in
IMPACT-METRICS.md), so events written before v3.17.0 are still parsable.
Missing `source` is treated as `"user"` to preserve historical semantics
of the v3.14.0–v3.16.x corpus.

The schema version stays at `v:1`. No migration script needed. The
addition is backward-compatible.

---

## Canonical formulas (extended)

```
useful_event_user  = (feedback.rating == "useful" AND feedback.source == "user")
                    OR (follow.followed == true AND follow.err_after == false)

useful_event_agent = (feedback.rating == "useful" AND feedback.source == "agent")

noise_event_user   = (feedback.rating == "noise" AND feedback.source == "user")
                    OR (follow.followed == false)
                    OR (reject event exists for the inject)

noise_event_agent  = (feedback.rating == "noise" AND feedback.source == "agent")

useful_ratio_user  = count(useful_event_user)  / count(inject)
useful_ratio_agent = count(useful_event_agent) / count(inject)

noise_ratio_user   = count(noise_event_user)   / count(inject)
noise_ratio_agent  = count(noise_event_agent)  / count(inject)

health_ratio_user  = useful_ratio_user / max(noise_ratio_user, 0.01)
```

The legacy aggregates (`useful_ratio`, `noise_ratio`, `health_ratio` from
v3.14.0) remain available for backward compatibility:

```
useful_ratio = useful_ratio_user + useful_ratio_agent     # additive view
noise_ratio  = noise_ratio_user  + noise_ratio_agent
```

Implicit follow-derived events stay attributed to `source: user` because
they reflect the user's actual next action.

---

## Sprint 0.5 — Go/No-Go Gate (revised)

The gate now reads only the `_user` ratios:

| Condition | Recommendation |
|-----------|----------------|
| `useful_ratio_user ≥ 0.25` AND `health_ratio_user ≥ 1.5` | **GO** |
| `0.10 ≤ useful_ratio_user < 0.25` OR `1.0 ≤ health_ratio_user < 1.5` | **PARTIAL** |
| `useful_ratio_user < 0.10` OR `health_ratio_user < 1.0` | **NO-GO** |

`useful_ratio_agent` is reported alongside but does **not** alter the
recommendation. A high agent ratio with a low user ratio is a flag, not
a pass — it suggests the agent finds value the user doesn't see, which is
worth investigating but never sufficient to ship v4.0.

---

## Reflex feedback (new path)

Reflexes (`reflexes.json`) have no `confidence` field by design — they
are deterministic rules. The previous `/cx-feedback` spec explicitly
forbade modifying reflexes.

v3.17.0 keeps that contract for human feedback (the user should not be
voting on reflexes anyway) but allows **agent-emitted feedback** on
reflexes via `/cx-feedback-auto`. Effects:

- `useful` → logs event with `source: agent`, `iid: <reflex-id>`. No
  confidence nudge (reflexes have none). No state change in
  `reflexes.json`.
- `noise`  → same logging, plus increments a counter
  `noiseCount` on the reflex entry. When `noiseCount ≥ 3` AND
  `fireCount ≥ 10` (so we have evidence the trigger fires often enough
  to judge), the reflex is auto-flagged with `enabled: false`. The user
  is notified at next `/cx-status` and can re-enable manually.

This auto-disable is conservative: it requires the agent to vote noise
3 times AND the reflex to have fired ≥10 times in its lifetime, so a
single bad session cannot kill a useful reflex.

Auto-disable is gated behind a new env flag
`CORTEX_AGENT_DISABLE_REFLEXES=1` (default: off in v3.17.0). Without
the flag, `noiseCount` is tracked but no state change happens. This
gives the user one release cycle to validate the heuristic.

---

## Commands

### `/cx-feedback` (updated)

Default source is `user`. Argument resolution stays the same: read
`.last-instinct`, accept rating shortcuts, write to `impact.jsonl` with
`source: "user"`. The only spec change:

- Step 1 now also accepts reflex ids if explicitly passed (e.g.
  `/cx-feedback bash-find-use-glob useful`). Behavior: log event but do
  not nudge confidence (reflexes have none) and warn the user that this
  is normally an agent responsibility.

### `/cx-feedback-auto` (new)

Invoked by Claude (the agent) at end of turn when one or more reflexes
fired. Spec:

```
/cx-feedback-auto <reflex-or-instinct-id> <useful|noise|ignore> [--note "..."]
```

Differences from `/cx-feedback`:
- `source: "agent"` always
- No interaction with `.last-instinct` — id is required
- No confidence nudge on instincts (agent self-rating must not
  bootstrap an instinct's confidence; only human feedback does)
- Tracks `noiseCount` on reflexes for auto-disable heuristic

The command is **not** intended for direct invocation by the user.
Documenting it as a CLI command keeps the action observable in the
transcript.

---

## UX expectations for the user

After this change, the rule of thumb the user follows simplifies:

> "If you see a `[gotcha-…]` or `[fs-…]` injection and recognize the
> intent, vote with `/cx-feedback`. If you see a `[reflex:…]` injection,
> ignore it — Claude will rate it for you."

The decision tree on the user's side becomes:

```
Did the injection visibly change the code or output?
├─ YES → /cx-feedback useful | noise
└─ NO (it's a tool-choice reflex) → skip; agent will rate
```

---

## Migration

- Schema is backward-compatible. No script needed.
- Existing `feedback` events without `source` are read as `source: user`.
- `compute_metrics()` returns both legacy fields (`useful_ratio`,
  `noise_ratio`, `health_ratio`) and split fields
  (`useful_ratio_user`, `useful_ratio_agent`, etc.). Old dashboards
  keep working.
- `/cx-status --impact` ASCII output adds two lines under the existing
  ratios. JSON output adds keys; consumers must ignore unknown ones.

---

## Testing

`tests/test_impact.sh` (was 13 tests in v3.14.0) gains:

14. `feedback` event with `--source user` is parseable, `source` field present
15. `feedback` event with `--source agent` is parseable
16. Missing `--source` defaults to `user` on read
17. `compute_metrics()` returns both legacy and split ratios
18. `useful_ratio_user` ignores `source: agent` events
19. Reflex id (not in instincts/) is accepted as `iid` without error
20. Reflex `noise` event increments `noiseCount` only when feature flag set
21. Auto-disable threshold (`noiseCount ≥ 3 AND fireCount ≥ 10`) is respected

Run with:

```bash
bash tests/test_impact.sh
```

---

## Stability contract

- Schema `v:1` unchanged. New `source` field is optional, default `user`.
- Future agent feedback channels (e.g. session-learner inferring `useful`
  from a tool-call success) MUST set `source: agent` for visibility.
- Adding new sources beyond `user`/`agent` requires bumping `v:` to `2`
  and a migration script.

---

## Why this is small on purpose

The audit could have proposed a much larger change: a Stop hook that
automatically rates every reflex by inspecting the next tool call,
auto-promotes useful instincts, deprecates noisy ones. That is the
**Alcance MAX** in the proposal. We deliberately ship the **Alcance MID**
first because:

1. The Sprint 0.5 Gate is the immediate blocker. Fixing the metric
   integrity unblocks the gate. Auto-evaluation can come in Sprint 1+.
2. The auto-disable heuristic for reflexes is gated behind an opt-in
   flag, so the v3.17.0 release cannot break existing user reflex
   configurations.
3. Backward compatibility costs nothing here — the schema absorbs the
   new field cleanly. A bigger refactor would force a `v:2` schema
   bump and a migration, which Sprint 0 does not need.

---

## Referenced by

- `hooks/lib/impact_log.py` — adds `source` parameter, split ratios
- `commands/cx-feedback.md` — updated spec
- `commands/cx-feedback-auto.md` — new
- `tests/test_impact.sh` — extended
- `CHANGELOG.md` v3.17.0 entry
- `docs/IMPACT-METRICS.md` — references this doc for source semantics
- `docs/FEATURES.md` — updated
