#!/bin/bash
# Cortex Session Start v2.0 — SessionStart hook
# Injects Laws + EOD Quick Resume + context.md bridge at session start AND after /compact.
# Reads laws from ~/.claude/cortex/laws/, EOD from daily-summaries/, context.md from project.

set -e

CORTEX_DIR="$HOME/.claude/cortex"
LAWS_DIR="$CORTEX_DIR/laws"
LAST_DATE_FILE="$CORTEX_DIR/.last-session-date"
EOD_DIR="$CORTEX_DIR/daily-summaries"
PROJECTS_DIR="$CORTEX_DIR/projects"
CONTEXT_TTL_DAYS=14

# Cross-platform date handling (macOS + Linux)
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null)

# Read stdin for cwd (project detection)
INPUT_JSON=$(cat 2>/dev/null || echo "{}")
PYTHON_CMD=""
command -v python3 >/dev/null 2>&1 && PYTHON_CMD="python3"
[ -z "$PYTHON_CMD" ] && command -v python >/dev/null 2>&1 && PYTHON_CMD="python"

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
  CONTEXT="${CONTEXT}\n\nNEW DAY (last session: ${LAST_DATE}). Consider running /cx-analyze to detect patterns."
elif [ -z "$LAST_DATE" ]; then
  CONTEXT="${CONTEXT}\n\nNEW DAY (first session). Welcome to Cortex."
fi

# 3. Check for .learn-pending marker OR count observations as fallback
if [ -f "$CORTEX_DIR/.learn-pending" ]; then
  CONTEXT="${CONTEXT}\n\nYou have 50+ new observations. Run /cx-analyze to detect patterns."
else
  LAST_LEARN_COUNT=0
  [ -f "$CORTEX_DIR/.last-learn-count" ] && LAST_LEARN_COUNT=$(cat "$CORTEX_DIR/.last-learn-count" 2>/dev/null | tr -d '[:space:]')
  LAST_LEARN_COUNT="${LAST_LEARN_COUNT:-0}"
  TOTAL_OBS=0
  for _obs_file in "$CORTEX_DIR"/projects/*/observations.jsonl; do
    [ -f "$_obs_file" ] && TOTAL_OBS=$((TOTAL_OBS + $(wc -l < "$_obs_file" 2>/dev/null || echo 0)))
  done
  NEW_OBS=$((TOTAL_OBS - LAST_LEARN_COUNT))
  if [ "$NEW_OBS" -ge 50 ]; then
    CONTEXT="${CONTEXT}\n\nYou have ${NEW_OBS} new observations since last /cx-analyze. Run /cx-analyze to detect patterns."
  fi
fi

# 3b. Inject context.md bridge from current project (v2.0)
if [ -n "$PYTHON_CMD" ] && [ -n "$INPUT_JSON" ]; then
  _CWD=$(echo "$INPUT_JSON" | "$PYTHON_CMD" -c 'import json,sys; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null || echo "")
  if [ -n "$_CWD" ] && [ -d "$_CWD" ] && command -v git &>/dev/null; then
    _PROJECT_ROOT=$(git -C "$_CWD" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$_PROJECT_ROOT" ]; then
      _REMOTE=$(git -C "$_PROJECT_ROOT" remote get-url origin 2>/dev/null || echo "$_PROJECT_ROOT")
      _PHASH=$(printf '%s' "$_REMOTE" | "$PYTHON_CMD" -c "import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])" 2>/dev/null || echo "")
      _CONTEXT_FILE="$PROJECTS_DIR/$_PHASH/context.md"
      if [ -n "$_PHASH" ] && [ -f "$_CONTEXT_FILE" ]; then
        # Check TTL (14 days)
        _FILE_AGE_DAYS=$("$PYTHON_CMD" -c "
import os, time
try:
    age = (time.time() - os.path.getmtime('$_CONTEXT_FILE')) / 86400
    print(int(age))
except:
    print(999)
" 2>/dev/null || echo "999")
        if [ "$_FILE_AGE_DAYS" -lt "$CONTEXT_TTL_DAYS" ]; then
          _CTX_CONTENT=$(head -10 "$_CONTEXT_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
          if [ -n "$_CTX_CONTENT" ]; then
            CONTEXT="${CONTEXT}\n\nPROJECT CONTEXT: ${_CTX_CONTENT}"
          fi
        fi
      fi
    fi
  fi
fi

# 4. Find and inject EOD Quick Resume (check today first, then yesterday)
EOD_FILE=""
EOD_DATE=""
if [ -f "$EOD_DIR/${TODAY}.md" ]; then
  EOD_FILE="$EOD_DIR/${TODAY}.md"
  EOD_DATE="$TODAY"
elif [ -n "$YESTERDAY" ] && [ -f "$EOD_DIR/${YESTERDAY}.md" ]; then
  EOD_FILE="$EOD_DIR/${YESTERDAY}.md"
  EOD_DATE="$YESTERDAY"
fi

if [ -n "$EOD_FILE" ]; then
  # Extract Quick Resume section (between "## Quick Resume" and next "##" or EOF)
  QUICK_RESUME=$(sed -n '/^## Quick Resume/,/^## /{ /^## Quick Resume/d; /^## /d; p; }' "$EOD_FILE" 2>/dev/null | head -10 | sed 's/^[[:space:]]*//' | tr -s '\n' ' ' | sed 's/^[> ]*//' | sed 's/[[:space:]]*$//')

  if [ -n "$QUICK_RESUME" ]; then
    CONTEXT="${CONTEXT}\n\nEOD RESUME (${EOD_DATE}): ${QUICK_RESUME}"
  fi

  # Also extract "For tomorrow" section if present (only lines starting with -)
  FOR_TOMORROW=$(sed -n '/^### For tomorrow/,/^###\|^##\|^---/{ /^### For tomorrow/d; /^###/d; /^##/d; /^---/d; p; }' "$EOD_FILE" 2>/dev/null | grep '^- ' | head -5 | sed 's/^- //' | paste -sd ';' - | sed 's/;$//')

  if [ -n "$FOR_TOMORROW" ]; then
    CONTEXT="${CONTEXT}\nPRIORITIES: ${FOR_TOMORROW}"
  fi

  # Instruction for Claude to present EOD proactively
  CONTEXT="${CONTEXT}\nIMPORTANT: Present the EOD resume and priorities to the user in your FIRST response. Do NOT wait for the user to ask. Greet, summarize yesterday, list priorities, ask where to start."
fi

# -- Output JSON via python3 --
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
