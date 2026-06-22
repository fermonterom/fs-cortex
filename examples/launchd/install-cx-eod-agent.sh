#!/bin/bash
# Helper: install the example launchd agent that runs cx-eod automatically.
# macOS only. Generic — does not hardcode any user's hours; edit the plist
# (StartCalendarInterval) to change when it fires. Defaults: 15:00, 19:00, 22:00.
#
# cx-eod --auto is fully deterministic (the gather script composes the summary
# itself, no model call), so this agent runs `bash .../_cx-eod-gather.sh --write`
# directly — no `claude -p`, no auth token, zero model quota.
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
GATHER="$HOME/.claude/cortex/core/_cx-eod-gather.sh"

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

if [ ! -f "$GATHER" ]; then
  echo "Gather script not found at $GATHER." >&2
  echo "Install/deploy fs-cortex first (run install.sh), then re-run this helper." >&2
  exit 1
fi

mkdir -p "$DEST_DIR" "$HOME/.claude/cortex/log"

# Materialize the template with the real HOME. Escape for BOTH XML (the plist is
# XML — &, <, > must be entities) and sed replacement syntax (&, |, \), so a HOME
# containing those characters produces a valid plist instead of breaking sed.
xml_sed_esc() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    | sed -e 's/[\\&|]/\\&/g'
}
HOME_ESC="$(xml_sed_esc "$HOME")"
sed -e "s|__HOME__|$HOME_ESC|g" "$SRC_PLIST" > "$DEST_PLIST"

# Reload (idempotent).
launchctl unload "$DEST_PLIST" 2>/dev/null || true
launchctl load "$DEST_PLIST"

echo "Installed and loaded: $DEST_PLIST"
echo "  runs: bash $GATHER --write  (deterministic, no claude -p, zero model quota)"
echo "  schedule: edit StartCalendarInterval in the plist to change the hours."
echo "  logs: $HOME/.claude/cortex/log/cx-eod-launchd.{out,err}.log"
echo ""
echo "Verify with:  launchctl list | grep $LABEL"
