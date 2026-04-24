---
name: cx-feedback
description: Cierra el loop humano del funnel de impacto — marca la última inyección como útil o ruido
command: true
---

# /cx-feedback

## What it does

Closes the human feedback loop on Cortex injections. Previously only `/cx-downvote` existed, which was one-way negative. `/cx-feedback` emits positive, negative, or neutral signal into `impact.jsonl`, where the Sprint 0.5 Go/No-Go Gate reads it.

Introduced in **v3.14.0** as part of Sprint 0 · Instrumentation.

## Usage

```
/cx-feedback useful                 # last injected instinct was useful
/cx-feedback noise                  # last injected instinct was noise
/cx-feedback ignore                 # last injected instinct was neither (neutral)
/cx-feedback <instinct-id> useful   # target a specific instinct id
/cx-feedback <instinct-id> noise
/cx-feedback --note "<free text>"   # attach rationale to the rating
```

Arguments may come in any order. If no `<instinct-id>` is provided, the
last entry written to `~/.claude/cortex/.last-instinct` is used.

## Implementation

### Step 1 · Resolve target instinct id(s)

Read `~/.claude/cortex/.last-instinct`. It contains:
```json
{"ids": ["gotcha-docker-...", "e2e-playwright-..."], "ts": "2026-04-24T..."}
```

- If argument looks like an instinct id (kebab-case, present in `instincts/global/` or `projects/*/instincts/`), target that one.
- Otherwise target the **first** id in `.last-instinct.ids` (the instinct of highest priority in the batch).
- If the file does not exist, tell the user "No recent inyection found" and stop.

### Step 2 · Resolve rating

Accept these tokens: `useful` | `noise` | `ignore`. Reject anything else
with an error message that lists the valid values.

### Step 3 · Resolve session id

Use the current session id if exposed by the harness, otherwise omit.

### Step 4 · Emit feedback event

Invoke:

```bash
python3 ~/.claude/cortex/hooks/cortex/lib/impact_log.py log \
  --event feedback \
  --iid <instinct-id> \
  --sid <session-id> \
  --rating <useful|noise|ignore> \
  ${note:+--note "$note"}
```

The Python writer:
- Appends one event to `~/.claude/cortex/impact.jsonl`
- Mirrors to `~/.claude/cortex/feedback.jsonl` for quick sampling
- Applies the v1 schema

### Step 5 · Apply soft confidence adjustment

Only for `useful` or `noise`:

- **useful** → nudge confidence **+0.02** in the instinct's YAML file (capped at 0.95)
- **noise**  → nudge confidence **-0.05** (floored at 0.10; below that, the instinct is eligible for archive in `/cx-maintenance`)

The nudge is atomic (tmp+rename). Log the change as a line in
`~/.claude/cortex/knowledge-log.md`:

```
YYYY-MM-DD | feedback | <instinct-id> | <before>→<after> | cx-feedback
```

### Step 6 · Confirm to user

Print a one-line confirmation:

```
✓ marked gotcha-docker-cross-network-isolation as useful (confidence 0.75 → 0.77)
```

If the user passed `--note`, echo the first 80 chars truncated.

## UX · shorthand consistency

Valid shortcuts, case-insensitive:

| Shortcut | Expands to |
|----------|------------|
| `u` / `useful` / `ok` / `+` | `useful` |
| `n` / `noise` / `bad`  / `-` | `noise` |
| `i` / `ignore` / `skip` | `ignore` |

## Where the signal goes

- `impact.jsonl` — canonical event log (ev:feedback)
- `feedback.jsonl` — sampled mirror for quick reads
- Instinct YAML — soft confidence nudge
- `knowledge-log.md` — audit trail
- Sprint 0.5 Go/No-Go Gate (`/cx-status --impact`) — aggregated decision signal

## Safety

- `useful|noise|ignore` are the **only** accepted ratings (validator rejects others).
- `--note` is length-capped at 500 chars and sanitized with the same rules as injector sanitization (blocked words, control chars).
- The command never modifies proposals.json, laws, or reflexes.
- Never fails the session — all errors are best-effort.

## Why this exists

Until v3.14.0 the only humane feedback channel was `/cx-downvote` (one-way
negative). The DA audit concluded that Cortex measured use, not impact,
because there was no positive signal. `/cx-feedback` is the contract that
closes the loop, feeding the same `impact.jsonl` funnel that the
Go/No-Go Gate reads to decide if the v4.0 refactor continues.

See `docs/IMPACT-METRICS.md` for the canonical formulas and
`~/.claude/cortex/hooks/cortex/lib/impact_log.py` for the writer.
