#!/usr/bin/env bash
# One-shot cleanup of legacy context.md files (v3.31.0 migration).
# Rotates files in the v3.30 English format ("## Project:") to
# .legacy-YYYYMMDD backups. Safe to run before OR after the new writer
# ships — only touches the old format. Idempotent.
set -euo pipefail

PROJECTS_DIR="${CORTEX_PROJECTS_DIR:-${HOME}/.claude/cortex/projects}"
TODAY=$(date +%Y%m%d)
rotated=0
skipped=0

if [ ! -d "$PROJECTS_DIR" ]; then
  echo "No projects dir at $PROJECTS_DIR — nothing to do."
  exit 0
fi

shopt -s nullglob
for f in "$PROJECTS_DIR"/*/context.md; do
  [ -f "$f" ] || continue
  first_line=$(head -n 1 "$f" 2>/dev/null || echo "")
  case "$first_line" in
    "## Proyecto:"*)
      skipped=$((skipped + 1))
      ;;
    *)
      mv "$f" "${f}.legacy-${TODAY}"
      echo "Rotated: $f"
      rotated=$((rotated + 1))
      ;;
  esac
done

echo ""
echo "Done. Rotated: $rotated. Kept (new format): $skipped."
