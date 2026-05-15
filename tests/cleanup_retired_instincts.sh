#!/usr/bin/env bash
# cleanup_retired_instincts.sh — v3.29.0 (Sprint 8 §4.13)
#
# Move orphan instincts created by the now-retired detectors
# (detectRepetitions, detectWorkflowChains) out of the active tree into
# a timestamped archive directory. Idempotent: re-running with nothing
# to move is a no-op. Reversible: instincts can be moved back from the
# archive directory if needed.
#
# Usage:
#   bash tests/cleanup_retired_instincts.sh [--dry-run]
#
# Honors CORTEX_DIR (defaults to ~/.claude/cortex), so it can be exercised
# inside a test sandbox.

set -euo pipefail
umask 077  # archive dir + manifest carry the same sensitivity as the source

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

CORTEX_DIR="${CORTEX_DIR:-$HOME/.claude/cortex}"
TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_DIR="$CORTEX_DIR/archive/retired-instincts-$TS"

# Patterns of orphan ids to retire. detectRepetitions emitted `repeat-<tool>-<hash>`
# and detectWorkflowChains emitted `workflow-<hash>` (see git history pre-v3.29).
PATTERNS=("repeat-*.yaml" "workflow-*.yaml")

# Source roots to scan: global instincts + every project instinct directory.
SOURCE_ROOTS=("$CORTEX_DIR/instincts/global")
if [ -d "$CORTEX_DIR/projects" ]; then
    while IFS= read -r -d '' proj_dir; do
        SOURCE_ROOTS+=("$proj_dir/instincts")
    done < <(find "$CORTEX_DIR/projects" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

MOVED=0
TO_MOVE=()

for root in "${SOURCE_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    for pattern in "${PATTERNS[@]}"; do
        # `find … -path '*/archive/*' -prune -o … -print` skips anything that's
        # already archived (the parent dir's `archive/` subdir for each instinct
        # set), preventing accidental re-archive on re-runs.
        while IFS= read -r -d '' src; do
            TO_MOVE+=("$src")
        done < <(find "$root" -path '*/archive/*' -prune -o -name "$pattern" -type f -print0 2>/dev/null)
    done
done

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
    echo "cleanup_retired_instincts: nothing to move (clean)."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] Would move ${#TO_MOVE[@]} retired instinct(s) to $ARCHIVE_DIR:"
    for src in "${TO_MOVE[@]}"; do
        echo "  $src"
    done
    exit 0
fi

mkdir -p "$ARCHIVE_DIR"
MANIFEST="$ARCHIVE_DIR/MANIFEST.txt"
{
    echo "# cleanup_retired_instincts.sh — $TS"
    echo "# CORTEX_DIR=$CORTEX_DIR"
    echo "# patterns=${PATTERNS[*]}"
    echo
} > "$MANIFEST"

for src in "${TO_MOVE[@]}"; do
    base="$(basename "$src")"
    parent_tag="$(basename "$(dirname "$(dirname "$src")")")"  # global or <project>
    dest="$ARCHIVE_DIR/${parent_tag}__${base}"
    # `mv -n` would be safer but is non-portable. The TS suffix in $ARCHIVE_DIR
    # guarantees uniqueness across runs, so collisions inside one run only
    # happen if the same file name appears twice in different source roots;
    # the `${parent_tag}__` prefix prevents that.
    mv "$src" "$dest"
    echo "$src -> $dest" >> "$MANIFEST"
    MOVED=$((MOVED + 1))
done

echo "cleanup_retired_instincts: moved $MOVED file(s) to $ARCHIVE_DIR"
echo "manifest: $MANIFEST"
