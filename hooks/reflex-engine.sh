#!/bin/bash
# Cortex Reflex Engine — Deterministic PreToolUse hook
# Reads ~/.claude/cortex/reflexes.json and fires matching reflexes

set -e

CORTEX_DIR="$HOME/.claude/cortex"
REFLEXES_FILE="$CORTEX_DIR/reflexes.json"

# Exit silently if no reflexes file
[ ! -f "$REFLEXES_FILE" ] && exit 0

# Read hook input from stdin
INPUT_JSON=$(cat)
[ -z "$INPUT_JSON" ] && exit 0

# Resolve python
PYTHON_CMD=""
command -v python3 >/dev/null 2>&1 && PYTHON_CMD="python3"
[ -z "$PYTHON_CMD" ] && command -v python >/dev/null 2>&1 && PYTHON_CMD="python"
[ -z "$PYTHON_CMD" ] && exit 0

# Extract tool_name and tool_input from hook data
# Match against reflexes, fire if match found
export _CX_REFLEXES_FILE="$REFLEXES_FILE"
"$PYTHON_CMD" -c '
import json, sys, re, os

try:
    hook_data = json.load(sys.stdin)
    tool_name = hook_data.get("tool_name", "")
    tool_input = hook_data.get("tool_input", {})
    if isinstance(tool_input, dict):
        tool_input_str = json.dumps(tool_input)
    else:
        tool_input_str = str(tool_input)

    with open(os.environ["_CX_REFLEXES_FILE"]) as f:
        reflexes = json.load(f)

    fired = []
    for reflex in reflexes.get("reflexes", []):
        if not reflex.get("enabled", True):
            continue
        matcher = reflex.get("matcher", "")
        if not re.search(matcher, tool_name):
            continue
        condition = reflex.get("condition", "")
        if condition and not re.search(condition, tool_input_str, re.IGNORECASE):
            continue
        fired.append(f"[REFLEX:{reflex['id']}] {reflex['action']}")

    if fired:
        context = "\n".join(fired)
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": context
            }
        }))
except Exception:
    pass  # Never block on error
' <<< "$INPUT_JSON"

exit 0
