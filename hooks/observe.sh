#!/bin/bash
# Cortex Continuous Learning - Observation Hook
# Based on Sinapsis observe.sh v2.1
#
# Captures tool use events for pattern analysis.
# Claude Code passes hook data via stdin as JSON.
#
# Usage: bash observe.sh [pre|post]
# Register in ~/.claude/settings.json hooks PreToolUse and PostToolUse

set -e
umask 077

HOOK_PHASE="${1:-post}"

# -- Read stdin --
INPUT_JSON=$(cat)
[ -z "$INPUT_JSON" ] && exit 0

# -- Resolve Python --
PYTHON_CMD=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_CMD="python"
fi

if [ -z "$PYTHON_CMD" ]; then
  echo "[cortex-observe] No python found, skipping observation" >&2
  exit 0
fi

# -- Extract cwd from stdin for project detection --
STDIN_CWD=$(echo "$INPUT_JSON" | "$PYTHON_CMD" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("cwd", ""))
except:
    print("")
' 2>/dev/null || echo "")

if [ -n "$STDIN_CWD" ] && [ -d "$STDIN_CWD" ]; then
  export CLAUDE_PROJECT_DIR="$STDIN_CWD"
fi

# -- Configuration --
CORTEX_DIR="${HOME}/.claude/cortex"
PROJECTS_DIR="${CORTEX_DIR}/projects"
MAX_FILE_SIZE_MB=10

# Skip if disabled
[ -f "$CORTEX_DIR/disabled" ] && exit 0

# -- Session guards --

# Skip non-CLI sessions
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in
  cli) ;;
  *) exit 0 ;;
esac

# Skip minimal profile
[ "${ECC_HOOK_PROFILE:-standard}" = "minimal" ] && exit 0

# Skip if cooperative variable active
[ "${ECC_SKIP_OBSERVE:-0}" = "1" ] && exit 0

# Skip subagents
_AGENT_ID=$(echo "$INPUT_JSON" | "$PYTHON_CMD" -c "import json,sys; print(json.load(sys.stdin).get('agent_id',''))" 2>/dev/null || true)
[ -n "$_AGENT_ID" ] && exit 0

# -- Skip non-useful tools --
_TOOL_NAME=$(echo "$INPUT_JSON" | "$PYTHON_CMD" -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('tool_name', data.get('tool', '')))
except:
    print('')
" 2>/dev/null || echo "")

# Always skip ToolSearch and Skill tools (no useful observations)
case "$_TOOL_NAME" in
  ToolSearch|Skill) exit 0 ;;
esac

# -- Sampling: For Read, Glob, Grep tools, only record 1 in 3 --
case "$_TOOL_NAME" in
  Read|Glob|Grep)
    if [ $(( RANDOM % 3 )) -ne 0 ]; then
      exit 0
    fi
    ;;
esac

# -- Dedup: Skip exact duplicates within session --
SESSION_ID=$(echo "$INPUT_JSON" | "$PYTHON_CMD" -c "import json,sys,re; sid=json.load(sys.stdin).get('session_id','unknown'); print(re.sub(r'[^a-zA-Z0-9_-]','',sid))" 2>/dev/null || echo "unknown")
DEDUP_FILE="${TMPDIR:-/tmp}/cortex-dedup-${SESSION_ID}"

# Compute hash of tool+input for dedup
_INPUT_HASH=$(echo "$INPUT_JSON" | "$PYTHON_CMD" -c "
import json, sys, hashlib
try:
    data = json.load(sys.stdin)
    tool = data.get('tool_name', data.get('tool', ''))
    inp = str(data.get('tool_input', data.get('input', '')))
    h = hashlib.md5((tool + inp).encode()).hexdigest()[:16]
    print(h)
except:
    print('')
" 2>/dev/null || echo "")

if [ -n "$_INPUT_HASH" ] && [ -f "$DEDUP_FILE" ]; then
  if grep -qF "$_INPUT_HASH" "$DEDUP_FILE" 2>/dev/null; then
    exit 0
  fi
fi

# Update dedup file (keep last 5 entries)
if [ -n "$_INPUT_HASH" ]; then
  if [ -f "$DEDUP_FILE" ]; then
    # Keep last 4 + add new one = 5 total
    tail -4 "$DEDUP_FILE" > "${DEDUP_FILE}.tmp" 2>/dev/null || true
    mv "${DEDUP_FILE}.tmp" "$DEDUP_FILE" 2>/dev/null || true
  fi
  echo "$_INPUT_HASH" >> "$DEDUP_FILE" 2>/dev/null || true
fi

# -- Project detection --

PROJECT_ID="global"
PROJECT_NAME="global"
PROJECT_DIR="$CORTEX_DIR"

# Detect project via git
if command -v git &>/dev/null; then
  PROJECT_ROOT=""
  if [ -n "$CLAUDE_PROJECT_DIR" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    PROJECT_ROOT="$CLAUDE_PROJECT_DIR"
  else
    PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  fi

  if [ -n "$PROJECT_ROOT" ]; then
    PROJECT_NAME=$(basename "$PROJECT_ROOT")

    # Hash of remote URL (portable) or path (fallback)
    REMOTE_URL=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)
    HASH_INPUT="${REMOTE_URL:-$PROJECT_ROOT}"
    PROJECT_ID=$(printf '%s' "$HASH_INPUT" | "$PYTHON_CMD" -c "import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])" 2>/dev/null || echo "fallback")

    PROJECT_DIR="${PROJECTS_DIR}/${PROJECT_ID}"

    # Create project structure
    mkdir -p "${PROJECT_DIR}/observations.archive"

    # Update registry
    export _CX_REGISTRY_PATH="${PROJECTS_DIR}/registry.json"
    export _CX_PROJECT_DIR="$PROJECT_DIR"
    export _CX_PROJECT_ID="$PROJECT_ID"
    export _CX_PROJECT_NAME="$PROJECT_NAME"
    export _CX_PROJECT_ROOT="$PROJECT_ROOT"
    export _CX_REMOTE_URL="$REMOTE_URL"

    "$PYTHON_CMD" -c '
import json, os, tempfile
from datetime import datetime, timezone

registry_path = os.environ["_CX_REGISTRY_PATH"]
project_dir = os.environ["_CX_PROJECT_DIR"]

os.makedirs(project_dir, exist_ok=True)
os.makedirs(os.path.dirname(registry_path), exist_ok=True)

try:
    with open(registry_path) as f:
        registry = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    registry = {}

now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
registry[os.environ["_CX_PROJECT_ID"]] = {
    "name": os.environ["_CX_PROJECT_NAME"],
    "root": os.environ["_CX_PROJECT_ROOT"],
    "remote": os.environ.get("_CX_REMOTE_URL", ""),
    "last_seen": now,
}

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(registry_path), text=True)
with os.fdopen(fd, "w") as f:
    json.dump(registry, f, indent=2)
os.replace(tmp, registry_path)
' 2>/dev/null || true
  fi
fi

OBSERVATIONS_FILE="${PROJECT_DIR}/observations.jsonl"

# -- Auto-purge observations >30 days --
PURGE_MARKER="${PROJECT_DIR}/.last-purge"
if [ ! -f "$PURGE_MARKER" ] || [ "$(find "$PURGE_MARKER" -mtime +1 2>/dev/null)" ]; then
  find "${PROJECT_DIR}" -name "observations-*.jsonl" -mtime +30 -delete 2>/dev/null || true
  touch "$PURGE_MARKER" 2>/dev/null || true
fi

# -- Parse input JSON (truncate input to 2000, output to 1000) --
PARSED=$(echo "$INPUT_JSON" | HOOK_PHASE="$HOOK_PHASE" "$PYTHON_CMD" -c '
import json, sys, os

try:
    data = json.load(sys.stdin)
    hook_phase = os.environ.get("HOOK_PHASE", "post")
    event = "tool_start" if hook_phase == "pre" else "tool_complete"

    tool_name = data.get("tool_name", data.get("tool", "unknown"))
    tool_input = data.get("tool_input", data.get("input", {}))
    tool_output = data.get("tool_response", data.get("tool_output", data.get("output", "")))
    session_id = data.get("session_id", "unknown")
    cwd = data.get("cwd", "")

    if isinstance(tool_input, dict):
        tool_input_str = json.dumps(tool_input)[:2000]
    else:
        tool_input_str = str(tool_input)[:2000]

    if isinstance(tool_output, dict):
        tool_output_str = json.dumps(tool_output)[:1000]
    else:
        tool_output_str = str(tool_output)[:1000]

    print(json.dumps({
        "parsed": True,
        "event": event,
        "tool": tool_name,
        "input": tool_input_str if event == "tool_start" else None,
        "output": tool_output_str if event == "tool_complete" else None,
        "session": session_id,
        "cwd": cwd
    }))
except Exception as e:
    print(json.dumps({"parsed": False, "error": str(e)}))
' || echo '{"parsed":false}')

PARSED_OK=$(echo "$PARSED" | "$PYTHON_CMD" -c "import json,sys; print(json.load(sys.stdin).get('parsed', False))" 2>/dev/null || echo "False")

if [ "$PARSED_OK" != "True" ]; then
  exit 0
fi

# -- Archive if file too large --
if [ -f "$OBSERVATIONS_FILE" ]; then
  file_size_mb=$(du -m "$OBSERVATIONS_FILE" 2>/dev/null | cut -f1)
  if [ "${file_size_mb:-0}" -ge "$MAX_FILE_SIZE_MB" ]; then
    archive_dir="${PROJECT_DIR}/observations.archive"
    mkdir -p "$archive_dir"
    mv "$OBSERVATIONS_FILE" "$archive_dir/observations-$(date +%Y%m%d-%H%M%S)-$$.jsonl" 2>/dev/null || true
  fi
fi

# -- Write observation (with secret scrubbing) --
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export PROJECT_ID_ENV="$PROJECT_ID"
export PROJECT_NAME_ENV="$PROJECT_NAME"
export TIMESTAMP="$timestamp"

OBS_LINE=$(echo "$PARSED" | "$PYTHON_CMD" -c '
import json, sys, os, re

parsed = json.load(sys.stdin)

SECRET_RE = re.compile(
    r"(?i)(api[_-]?key|token|secret|password|authorization|credentials?|auth|bearer)"
    r"""(["'"'"'"'"'"'\s:=]+)"""
    r"([A-Za-z]+\s+)?"
    r"([A-Za-z0-9_\-/.+=]{8,})"
)
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")
PEM_RE = re.compile(r"-----BEGIN[A-Z \n]+-----[\s\S]*?-----END[A-Z \n]+-----")

def scrub(val):
    if val is None:
        return None
    s = str(val)
    s = SECRET_RE.sub(lambda m: m.group(1) + m.group(2) + (m.group(3) or "") + "[REDACTED]", s)
    s = JWT_RE.sub("[JWT_REDACTED]", s)
    s = PEM_RE.sub("[PEM_REDACTED]", s)
    return s

observation = {
    "timestamp": os.environ["TIMESTAMP"],
    "event": parsed["event"],
    "tool": parsed["tool"],
    "session": parsed["session"],
    "project_id": os.environ.get("PROJECT_ID_ENV", "global"),
    "project_name": os.environ.get("PROJECT_NAME_ENV", "global"),
}

if parsed.get("input"):
    observation["input"] = scrub(parsed["input"])
if parsed.get("output") is not None:
    observation["output"] = scrub(parsed["output"])

print(json.dumps(observation))
' 2>/dev/null || echo "")

# Write with file locking for concurrent safety
_write_observation() {
  local obs="$1"
  local target="$2"
  if command -v flock >/dev/null 2>&1; then
    (flock -w 10 200 && echo "$obs" >> "$target") 200>"${target}.lock"
  else
    # Fallback without flock (macOS without coreutils) — OS-level atomic append
    echo "$obs" >> "$target"
  fi
}

[ -n "$OBS_LINE" ] && _write_observation "$OBS_LINE" "$OBSERVATIONS_FILE"

# -- Watchdog: proactive alerts on critical errors --
if [ "$HOOK_PHASE" = "post" ]; then
  _OUTPUT=$(echo "$PARSED" | "$PYTHON_CMD" -c "import json,sys; print(json.load(sys.stdin).get('output','') or '')" 2>/dev/null || echo "")
  if echo "$_OUTPUT" | grep -qiE "(FATAL|PANIC|OOM|segfault|killed|ENOSPC|out of memory)"; then
    echo "[cortex-watchdog] Critical error detected in output. Consider capturing it." >&2
  fi
fi

# -- Learn trigger: marker every 50 observations --
OBS_COUNT_FILE="${CORTEX_DIR}/.obs-count"
LEARN_THRESHOLD=50
if [ -f "$OBS_COUNT_FILE" ]; then
  COUNT=$(cat "$OBS_COUNT_FILE" 2>/dev/null || echo "0")
else
  COUNT=0
fi
COUNT=$((COUNT + 1))
echo "$COUNT" > "$OBS_COUNT_FILE" 2>/dev/null || true
if [ "$COUNT" -ge "$LEARN_THRESHOLD" ]; then
  touch "${CORTEX_DIR}/.learn-pending" 2>/dev/null || true
  echo "0" > "$OBS_COUNT_FILE" 2>/dev/null || true
fi

exit 0
