#!/usr/bin/env bash
# CORTEX-MANAGED — do not edit manually, updated by install.sh
# Cortex Observer — thin wrapper that delegates to observe.py
# Kept as .sh for backward compatibility with settings.json hook commands
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_CMD="${CORTEX_PYTHON:-}"
if [ -z "$PYTHON_CMD" ]; then
    command -v python3 >/dev/null 2>&1 && PYTHON_CMD="python3" || PYTHON_CMD="python"
fi
exec "$PYTHON_CMD" "$SCRIPT_DIR/observe.py" "$@"
