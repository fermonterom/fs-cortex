#!/bin/bash
# CORTEX-MANAGED — do not edit manually, updated by install.sh
# Cortex Injector v3.0 — Thin Bash wrapper for Node.js engine
# Reads stdin, writes to temp file, delegates to lib/injector-engine.js
# Safety: exits 0 silently on any error (never blocks Claude)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORTEX_DIR="$HOME/.claude/cortex"
REFLEXES_FILE="$CORTEX_DIR/reflexes.json"
GLOBAL_INSTINCTS_DIR="$CORTEX_DIR/instincts/global"

# Read hook input from stdin (once)
INPUT_JSON=$(cat)
[ -z "$INPUT_JSON" ] && exit 0

# Require node — exit silently if unavailable
command -v node >/dev/null 2>&1 || exit 0

# Write hook payload to temp file (avoids exposing full payload in env/proc)
_CX_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/cx-input-XXXXXX")
chmod 600 "$_CX_INPUT_FILE"
echo "$INPUT_JSON" > "$_CX_INPUT_FILE"
trap 'rm -f "'"$_CX_INPUT_FILE"'"' EXIT

# Validate CORTEX_DIR is under real home directory
_REAL_HOME=$(eval echo ~"$(whoami)" 2>/dev/null || echo "$HOME")
if [[ "$CORTEX_DIR" != "$_REAL_HOME/.claude/cortex" ]]; then
  exit 0
fi

# Engine file
ENGINE="$SCRIPT_DIR/lib/injector-engine.js"
[ -f "$ENGINE" ] || exit 0

# Execute engine with environment and timeout
export _CX_INPUT_FILE
export _CX_CORTEX_DIR="$CORTEX_DIR"
export _CX_REFLEXES_FILE="$REFLEXES_FILE"
export _CX_GLOBAL_INSTINCTS_DIR="$GLOBAL_INSTINCTS_DIR"

node "$ENGINE" 2>/dev/null

exit 0
