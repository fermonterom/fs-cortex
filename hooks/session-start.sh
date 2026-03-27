#!/bin/bash
# Cortex Session Start — SessionStart hook
# Injects condensed Laws at every session start AND after /compact.
# Reads laws from ~/.claude/cortex/laws/, checks for new day, learn-pending, and EOD.

set -e

CORTEX_DIR="$HOME/.claude/cortex"
LAWS_DIR="$CORTEX_DIR/laws"
LAST_DATE_FILE="$CORTEX_DIR/.last-session-date"
EOD_DIR="$CORTEX_DIR/daily-summaries"

# Cross-platform date handling (macOS + Linux)
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null)

# -- Build context string --
CONTEXT=""

# 1. Read all law files (max 10)
if [ -d "$LAWS_DIR" ]; then
  LAW_FILES=$(find "$LAWS_DIR" -maxdepth 1 -name "*.txt" -type f 2>/dev/null | sort | head -10)
  if [ -n "$LAW_FILES" ]; then
    LAWS=""
    while IFS= read -r law_file; do
      LAW_CONTENT=$(head -1 "$law_file" 2>/dev/null | tr -d '\n')
      [ -n "$LAW_CONTENT" ] && LAWS="${LAWS}\n- ${LAW_CONTENT}"
    done <<< "$LAW_FILES"
    if [ -n "$LAWS" ]; then
      CONTEXT="CORTEX LAWS (follow always):${LAWS}"
    fi
  fi
fi

# If no laws found, still provide a header
[ -z "$CONTEXT" ] && CONTEXT="CORTEX: No laws configured yet. Add .txt files to ~/.claude/cortex/laws/"

# 2. Check for new day
LAST_DATE=""
[ -f "$LAST_DATE_FILE" ] && LAST_DATE=$(cat "$LAST_DATE_FILE" | tr -d '[:space:]')

# Always update the date file
mkdir -p "$CORTEX_DIR"
echo "$TODAY" > "$LAST_DATE_FILE"

if [ "$LAST_DATE" != "$TODAY" ] && [ -n "$LAST_DATE" ]; then
  CONTEXT="${CONTEXT}\n\nNEW DAY (last session: ${LAST_DATE}). Consider running /cx-learn to crystallize patterns."
elif [ -z "$LAST_DATE" ]; then
  CONTEXT="${CONTEXT}\n\nNEW DAY (last session: first time). Consider running /cx-learn to crystallize patterns."
fi

# 3. Check for .learn-pending marker
if [ -f "$CORTEX_DIR/.learn-pending" ]; then
  CONTEXT="${CONTEXT}\n\nYou have 50+ new observations. Run /cx-learn to analyze patterns."
fi

# 4. Check for yesterday's EOD
if [ -n "$YESTERDAY" ]; then
  EOD_FILE="$EOD_DIR/${YESTERDAY}.md"
  if [ -f "$EOD_FILE" ]; then
    CONTEXT="${CONTEXT}\n\nYesterday's EOD found. Read ~/.claude/cortex/daily-summaries/${YESTERDAY}.md for context."
  fi
fi

# -- Output JSON via python3 --
PYTHON_CMD=""
command -v python3 >/dev/null 2>&1 && PYTHON_CMD="python3"
[ -z "$PYTHON_CMD" ] && command -v python >/dev/null 2>&1 && PYTHON_CMD="python"
[ -z "$PYTHON_CMD" ] && exit 0

"$PYTHON_CMD" -c "
import json, sys
ctx = sys.argv[1].replace('\\\\n', '\n')
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': ctx
    }
}))
" "$CONTEXT"

exit 0
