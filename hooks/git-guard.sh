#!/bin/bash
# Cortex Git Guard — PreToolUse hook for Bash
# Reminds about git best practices before commit/push/merge

set -e

INPUT_JSON=$(cat)
[ -z "$INPUT_JSON" ] && exit 0

PYTHON_CMD=""
command -v python3 >/dev/null 2>&1 && PYTHON_CMD="python3"
[ -z "$PYTHON_CMD" ] && command -v python >/dev/null 2>&1 && PYTHON_CMD="python"
[ -z "$PYTHON_CMD" ] && exit 0

# Extract command from tool_input using Python
COMMAND=$("$PYTHON_CMD" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    inp = data.get("tool_input", {})
    if isinstance(inp, dict):
        print(inp.get("command", ""))
    else:
        print(str(inp))
except:
    print("")
' <<< "$INPUT_JSON" 2>/dev/null)

[ -z "$COMMAND" ] && exit 0

emit_context() {
  local msg="$1"
  "$PYTHON_CMD" -c "
import json, sys
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'additionalContext': sys.argv[1]
    }
}))
" "$msg"
}

# Check for git commit
if echo "$COMMAND" | grep -qE 'git commit'; then
  emit_context "[CORTEX GIT GUARD] Before committing: verify tests pass, lint is clean, and build succeeds."
  exit 0
fi

# Check for git push or PR create
if echo "$COMMAND" | grep -qE 'git push|gh pr create'; then
  emit_context "[CORTEX GIT GUARD] Before pushing: ensure branch is up to date (fetch + rebase). Use --force-with-lease for force pushes. Verify PR base branch is correct."
  exit 0
fi

# Check for PR merge
if echo "$COMMAND" | grep -qE 'gh pr merge'; then
  emit_context "[CORTEX GIT GUARD] Before merging: verify all checks pass. After merge: clean up branch (local + remote)."
  exit 0
fi

exit 0
