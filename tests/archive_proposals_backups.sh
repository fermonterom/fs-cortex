#!/usr/bin/env bash
# archive_proposals_backups.sh — v3.29.0 (Sprint 8 §4.9)
#
# One-shot ops script. Bundles every `proposals.json.bak*` file under
# CORTEX_DIR into a timestamped, SHA-256-checksummed tarball under
# CORTEX_DIR/archive/, then removes the originals. Idempotent: running
# again with nothing to archive is a no-op.
#
# Usage:
#   bash tests/archive_proposals_backups.sh [--dry-run]
#
# Honors CORTEX_DIR (defaults to ~/.claude/cortex), so it can be exercised
# inside a test sandbox.

set -euo pipefail
umask 077

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

CORTEX_DIR="${CORTEX_DIR:-$HOME/.claude/cortex}"
ARCHIVE_DIR="$CORTEX_DIR/archive"

# Collect the candidate files BEFORE creating the archive so we don't tar
# our own archive next time the script runs. macOS ships bash 3.2 which
# lacks `mapfile`, so we use a portable while-read loop with NUL delim.
BAKS=()
while IFS= read -r -d '' f; do
    BAKS+=("$f")
done < <(find "$CORTEX_DIR" -maxdepth 1 -name 'proposals.json.bak*' -type f -print0 2>/dev/null)

if [ "${#BAKS[@]}" -eq 0 ]; then
    echo "archive_proposals_backups: nothing to archive (clean)."
    exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$ARCHIVE_DIR/proposals-pre-v3.29-${TS}.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"
MANIFEST="${ARCHIVE}.manifest.txt"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] Would archive ${#BAKS[@]} file(s) into $ARCHIVE:"
    for f in "${BAKS[@]}"; do
        echo "  $f"
    done
    exit 0
fi

mkdir -p "$ARCHIVE_DIR"

# Build manifest BEFORE tarring so its content is the on-disk snapshot
# (timestamps + sizes) of what we're about to remove.
{
    echo "# archive_proposals_backups.sh — $TS"
    echo "# CORTEX_DIR=$CORTEX_DIR"
    echo "# archive=$ARCHIVE"
    echo
    for f in "${BAKS[@]}"; do
        # GNU coreutils first: BSD `stat -f` is parsed as --file-system on GNU
        # and succeeds (exit 0) with garbage, so a BSD-first order skips the
        # GNU fallback. `stat -c` is rejected by BSD (exit 1) → falls back to -f.
        size=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo "?")
        mtime=$(stat -c %y "$f" 2>/dev/null || stat -f %Sm "$f" 2>/dev/null || echo "?")
        echo "$f|${size}|${mtime}"
    done
} > "$MANIFEST"

# Tar with paths relative to CORTEX_DIR so extracting is predictable.
( cd "$CORTEX_DIR" && tar -czf "$ARCHIVE" \
    $(printf '%s\n' "${BAKS[@]}" | sed "s|^$CORTEX_DIR/||") )

# Checksum. shasum -a 256 works on both macOS (BSD) and Linux (GNU
# sha256sum is usually available too but shasum is the cross-platform
# common denominator).
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ARCHIVE" > "$CHECKSUM"
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$ARCHIVE" > "$CHECKSUM"
else
    echo "WARN: no sha256sum or shasum available — skipping checksum" >&2
fi

# Only delete the originals after the archive + checksum are on disk.
for f in "${BAKS[@]}"; do
    rm -f "$f"
done

echo "archive_proposals_backups: archived ${#BAKS[@]} file(s)."
echo "  archive:  $ARCHIVE"
echo "  manifest: $MANIFEST"
[ -f "$CHECKSUM" ] && echo "  checksum: $CHECKSUM"
