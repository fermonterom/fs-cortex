---
name: cx-feedback-auto
description: Agent self-rating on tool-choice reflexes — emits feedback with source=agent
command: true
---

# /cx-feedback-auto

## What it does

Lets the **agent** (Claude) rate injected reflexes and tool-choice instincts that the human cannot meaningfully evaluate. Emits a `feedback` event with `source: agent` into `impact.jsonl`, parallel to `/cx-feedback` (which emits `source: user`).

Introduced in **v3.17.0**. See [`docs/AGENT-FEEDBACK.md`](../docs/AGENT-FEEDBACK.md) for the full design rationale.

## When to invoke

This command is invoked **by Claude**, not the user. The agent calls it at end of turn (or right after the tool call that triggered the inject) when one or both of these hold:

- A `[reflex:…]` injection fired and the agent can judge whether following it was useful.
- An instinct injection covered tool-choice (e.g. "use Glob over find") that the user cannot observe.

The agent should **not** use this for instincts that produced a user-visible artefact (RLS policy, release commit, code change). Those belong to `/cx-feedback`, where the human decides.

## Usage

```
/cx-feedback-auto <id> <rating> [--note "<rationale>"]
```

Both `<id>` and `<rating>` are required. Unlike `/cx-feedback`, there is no
`.last-instinct` fallback — the agent must name the target explicitly so the
event is unambiguous.

| Argument | Allowed values |
|----------|----------------|
| `<id>` | reflex id (in `reflexes.json`) or instinct id (in `instincts/`) |
| `<rating>` | `useful` \| `noise` \| `ignore` (shortcuts: `u`/`n`/`i`/`+`/`-`) |
| `--note` | optional rationale ≤ 500 chars (sanitized) |

## Implementation

### Step 1 · Validate id

Verify `<id>` exists either in `~/.claude/cortex/reflexes.json` (`.reflexes[*].id`) or in any `~/.claude/cortex/instincts/global/*.yaml` / `~/.claude/cortex/projects/*/instincts/*.yaml`. Reject unknown ids with a clear error.

### Step 2 · Validate rating

Apply the same shortcut expansion as `/cx-feedback`:

| Shortcut | Expands to |
|----------|------------|
| `u` / `useful` / `ok` / `+` | `useful` |
| `n` / `noise` / `bad` / `-` | `noise` |
| `i` / `ignore` / `skip` | `ignore` |

### Step 3 · Emit feedback event

```bash
python3 ~/.claude/cortex/hooks/cortex/lib/impact_log.py log \
  --event feedback \
  --iid <id> \
  --sid <session-id> \
  --rating <useful|noise|ignore> \
  --source agent \
  ${note:+--note "$note"}
```

The Python writer mirrors to `feedback.jsonl` and applies v1 schema (with `source: agent`). The Sprint 0.5 Gate ignores agent events by design.

### Step 4 · Reflex-specific bookkeeping

If `<id>` matches a reflex (not an instinct), additionally:

- On `useful`: no further action (no confidence nudge, reflexes have none).
- On `noise`: increment `noiseCount` on the reflex entry in `reflexes.json` (atomic tmp+rename).
- On `ignore`: no further action.

If `noiseCount ≥ 3` AND `fireCount ≥ 10` AND env `CORTEX_AGENT_DISABLE_REFLEXES=1` is set, set `enabled: false` on the reflex and log:

```
YYYY-MM-DD | reflex-auto-disable | <reflex-id> | noiseCount=N fireCount=M | cx-feedback-auto
```

to `~/.claude/cortex/knowledge-log.md`. Otherwise the threshold is tracked but no state change happens (default in v3.17.0).

### Step 5 · Instinct-specific bookkeeping

If `<id>` matches an instinct (not a reflex):

- **No confidence nudge**, ever. Agent self-rating must not bootstrap an instinct's confidence — that is reserved for human feedback or distillation. The event is logged for diagnostic visibility only.
- Append a line to `knowledge-log.md`:

```
YYYY-MM-DD | feedback-agent | <instinct-id> | rating=<rating> | cx-feedback-auto
```

### Step 6 · Confirm

Print one line:

```
✓ agent-rated <id> as <rating> (source=agent, no confidence change)
```

If the user passed `--note`, echo the first 80 chars truncated.

## Where the signal goes

- `impact.jsonl` — canonical event log (`ev: feedback`, `source: agent`)
- `feedback.jsonl` — sampled mirror
- `knowledge-log.md` — audit trail
- `/cx-status --impact` — agent ratios surfaced as diagnostic, **not** as gate input

## Safety

- The same blocked-keyword sanitizer used by the injector runs on `--note`.
- The command never modifies instinct YAML, never modifies laws.
- Reflex `enabled: false` flips ONLY when the explicit env flag is set, AND both `noiseCount` AND `fireCount` thresholds are met.
- Never fails the session — best-effort logging.

## Why this exists

The DA follow-up audit (2026-04-25) showed that `/cx-feedback` alone left agent-internal reflexes (~60% of injects on the reference workstation) without any positive signal channel. Mixing user and agent feedback in a single ratio destroyed the gate's meaning.

This command keeps both signals separate so the Sprint 0.5 Go/No-Go Gate continues to measure **human value**, while the agent's self-ratings provide a parallel diagnostic.

## Pairing with `/cx-feedback`

| Situation | User runs | Agent runs |
|-----------|-----------|-----------|
| `[gotcha-rls-silent-fail]` fired before RLS policy edit | `/cx-feedback useful` | – |
| `[reflex:bash-find-use-glob]` fired before bash call | – | `/cx-feedback-auto bash-find-use-glob useful` |
| `[reflex:read-before-edit]` fired but file was already Read | – | `/cx-feedback-auto read-before-edit ignore` |
| `[fs-cortex-release-checklist]` fired before release commit | `/cx-feedback useful` | – |
