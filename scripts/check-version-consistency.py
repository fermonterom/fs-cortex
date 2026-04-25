#!/usr/bin/env python3
"""
check-version-consistency.py — Sprint 1.6 (v3.15.0)

Validates that all version markers across the repo agree before push.
Called by the pre-push hook and available as `python3 scripts/check-version-consistency.py`.

Sources of truth validated:
  1. install.sh             NEW_VERSION="X.Y.Z"
  2. install.ps1            $NewVersion = "X.Y.Z"
  3. CHANGELOG.md           first `## [X.Y.Z] — YYYY-MM-DD` entry
  4. docs/FEATURES.md       first `# fs-cortex vX.Y.Z — ...` header (if present)

Exit codes:
  0  all versions match
  1  drift detected (prints a diff-style table)
  2  could not parse one or more sources (treat as drift)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SOURCES = {
    "install.sh":        (ROOT / "install.sh",        r'^NEW_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"'),
    "install.ps1":       (ROOT / "install.ps1",       r'^\$NewVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"'),
    "CHANGELOG.md":      (ROOT / "CHANGELOG.md",      r'^##\s+\[([0-9]+\.[0-9]+\.[0-9]+)\]'),
    "docs/FEATURES.md":  (ROOT / "docs" / "FEATURES.md", r'^#\s+fs-cortex\s+v([0-9]+\.[0-9]+\.[0-9]+)'),
}


def extract(path: Path, pattern: str) -> str | None:
    """Return the first regex match group or None if not found / file missing."""
    if not path.exists():
        return None
    regex = re.compile(pattern, re.MULTILINE)
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return None
    m = regex.search(content)
    return m.group(1) if m else None


def main(argv: list[str] | None = None) -> int:
    argv = argv or sys.argv[1:]
    quiet = "--quiet" in argv or "-q" in argv

    results: dict[str, str | None] = {}
    for name, (path, pattern) in SOURCES.items():
        results[name] = extract(path, pattern)

    present = {name: v for name, v in results.items() if v is not None}
    missing = [name for name, v in results.items() if v is None]

    if not present:
        print("ERROR: could not extract version from any source", file=sys.stderr)
        return 2

    distinct = set(present.values())
    ok = len(distinct) == 1

    if ok and not missing:
        if not quiet:
            v = next(iter(distinct))
            print(f"✅ Version consistency OK — all sources at v{v}")
        return 0

    # Drift or missing source: print table
    print()
    print("❌ VERSION DRIFT DETECTED")
    print()
    width = max(len(n) for n in SOURCES)
    for name in SOURCES:
        v = results.get(name)
        status = "✓" if v and v in distinct and len(distinct) == 1 else ("?" if v is None else "!")
        shown = v or "MISSING (expected present)"
        print(f"  {status}  {name:<{width}}  {shown}")
    print()

    if len(distinct) > 1:
        print(f"  → {len(distinct)} distinct versions found: {sorted(distinct)}")
        print("    Update ALL sources to the same X.Y.Z before pushing.")
        return 1
    # Missing source
    print(f"  → {len(missing)} source(s) missing a parseable version marker:")
    for name in missing:
        print(f"      - {name}")
    print("    Fix the marker in the file(s) above or adjust SOURCES in this script.")
    return 2


if __name__ == "__main__":
    sys.exit(main())
