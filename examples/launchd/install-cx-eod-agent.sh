#!/bin/bash
# Helper: install the example launchd agent that runs /cx-eod automatically.
# macOS only. Generic — does not hardcode any user's hours; edit the plist
# (StartCalendarInterval) to change when it fires. Defaults: 15:00, 19:00, 22:00.
#
# Usage:
#   bash examples/launchd/install-cx-eod-agent.sh            # install + load
#   bash examples/launchd/install-cx-eod-agent.sh --uninstall # unload + remove
#
# Re-running is safe: it unloads any previous version before loading the new one.
set -euo pipefail

LABEL="com.cortex.cx-eod"
PLIST_NAME="$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_PLIST="$SCRIPT_DIR/$PLIST_NAME"
DEST_DIR="$HOME/Library/LaunchAgents"
DEST_PLIST="$DEST_DIR/$PLIST_NAME"

if [ "$(uname)" != "Darwin" ]; then
  echo "This helper is macOS-only (launchd). On Linux use cron or a systemd timer." >&2
  exit 1
fi

# --uninstall path.
if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$DEST_PLIST" ]; then
    launchctl unload "$DEST_PLIST" 2>/dev/null || true
    rm -f "$DEST_PLIST"
    echo "Removed $DEST_PLIST"
  else
    echo "No agent installed at $DEST_PLIST"
  fi
  exit 0
fi

# Locate the claude CLI.
CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "Could not find 'claude' on PATH. Install Claude Code first, or edit the" >&2
  echo "plist and set __CLAUDE_BIN__ to the absolute path manually." >&2
  exit 1
fi

mkdir -p "$DEST_DIR" "$HOME/.claude/cortex/log"

# Materialize the template with real paths. Escape for BOTH XML (the plist is
# XML — &, <, > must be entities) and sed replacement syntax (&, |, \), so paths
# containing those characters produce a valid plist instead of breaking sed.
xml_sed_esc() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    | sed -e 's/[\\&|]/\\&/g'
}
CLAUDE_BIN_ESC="$(xml_sed_esc "$CLAUDE_BIN")"
HOME_ESC="$(xml_sed_esc "$HOME")"
sed -e "s|__CLAUDE_BIN__|$CLAUDE_BIN_ESC|g" \
    -e "s|__HOME__|$HOME_ESC|g" \
    "$SRC_PLIST" > "$DEST_PLIST"

# Reload (idempotent).
launchctl unload "$DEST_PLIST" 2>/dev/null || true
launchctl load "$DEST_PLIST"

echo "Installed and loaded: $DEST_PLIST"
echo "  claude: $CLAUDE_BIN"
echo "  schedule: edit StartCalendarInterval in the plist to change the hours."
echo "  logs: $HOME/.claude/cortex/log/cx-eod-launchd.{out,err}.log"
echo ""
echo "Verify with:  launchctl list | grep $LABEL"
