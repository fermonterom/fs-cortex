---
name: cx-stop
description: Close current session cleanly — flush observations and run Stop hook
command: true
---

# /cx-stop

## What it does

Manually triggers the Stop hook semantics: runs `session-learner.js` immediately on the current session. Useful when you want to end work on a session and have its patterns analyzed without waiting for Claude Code to detect inactivity.

Does NOT close the chat — that's Claude Code's job. Only ensures the learning pipeline runs now.

Does NOT trigger /cx-eod — EOD is independent and runs nightly.

## Usage

`/cx-stop`

## Implementation

### Step 1: Resolve session ID

Get the current session ID from environment `CORTEX_SESSION_ID` or from Claude Code's session context.

### Step 2: Run session-learner

Execute via Bash:

```bash
SID="${CORTEX_SESSION_ID:-$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || python -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || echo unknown)}"
TS=$(date +%Y%m%d-%H%M%S)
LOG="${TMPDIR:-/tmp}/cx-stop-${TS}.log"
printf '{"session_id": "%s"}\n' "$SID" | node ~/.claude/hooks/cortex/session-learner.js > "$LOG" 2>&1
EXIT=$?
```

### Step 3: Show result

Read the last 20 lines of the log. Count proposals from `~/.claude/cortex/proposals.json` (delta vs before is informational only — actual count is what matters).

Display:

```
✅ Session pipeline executed for session $SID
   Total proposals in queue: N
   Run /cx-status to inspect knowledge state.
   Run /cx-validate to review pending proposals.
```

If exit code != 0, show last 10 lines of log and indicate failure.

## What NOT to do

- Do NOT auto-trigger /cx-eod (EOD runs nightly via cortex-daily-routine).
- Do NOT close the Claude Code chat (out of scope).
- Do NOT delete observations (idempotent — can be run multiple times safely).
