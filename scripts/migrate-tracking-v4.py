#!/usr/bin/env python3
"""
migrate-tracking-v4.py — Sprint 1.3 (v3.15.0)

One-shot idempotent migration that unifies instinct usage counters.

Problem:
  v3.x stored per-instinct counters in TWO places:
    1. ~/.claude/cortex/instinct-tracking.json  (written by injector)
    2. Each YAML's frontmatter `occurrences:` + `last_seen:` (written by learner)
  Live data (audit 2026-04-24): tracking.json had 1 entry, but 61 YAMLs had
  occurrences values, some as high as 1014. The injector's inline staleness
  filter (60-day cutoff) read tracking.json, so for 98% of the corpus the
  filter never triggered — instincts that should have expired kept injecting.

Fix:
  Merge YAML occurrences+last_seen into tracking.json so the JSON has the
  complete picture. Keep YAML fields intact (readable, portable) but JSON
  becomes the operational source of truth.

Safety:
  - Idempotent: if tracking entry already has higher count, do not regress.
  - Additive: never deletes entries or YAML fields.
  - Atomic: tmp + rename for tracking.json.
  - --dry-run by default: prints what it would do, writes nothing.
  - Backup: copies tracking.json to tracking.json.pre-v4.0 before first write.

Usage:
  python3 scripts/migrate-tracking-v4.py              # dry-run (default)
  python3 scripts/migrate-tracking-v4.py --apply      # write changes
  python3 scripts/migrate-tracking-v4.py --stats      # print summary only
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

HOME = Path(os.environ.get("HOME") or os.environ.get("USERPROFILE") or "/tmp")
CORTEX_DIR = Path(os.environ.get("CORTEX_DIR") or (HOME / ".claude" / "cortex"))
TRACKING_FILE = CORTEX_DIR / "instinct-tracking.json"
GLOBAL_INSTINCTS = CORTEX_DIR / "instincts" / "global"
PROJECTS_DIR = CORTEX_DIR / "projects"

FIELD_RE = re.compile(r'^(?P<key>id|occurrences|last_seen|confidence|domain|scope|project_id)\s*:\s*["\']?(?P<val>[^"\'\n]+?)["\']?\s*$', re.MULTILINE)


def _parse_yaml_frontmatter(path: Path) -> dict | None:
    """Very small frontmatter parser — enough for flat string/number scalars."""
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return None
    if not content.startswith("---"):
        return None
    end = content.find("---", 3)
    if end < 0:
        return None
    front = content[3:end]
    fields = {}
    for m in FIELD_RE.finditer(front):
        fields[m.group("key")] = m.group("val").strip()
    return fields


def _load_tracking() -> dict:
    try:
        return json.loads(TRACKING_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_tracking(data: dict) -> None:
    CORTEX_DIR.mkdir(parents=True, exist_ok=True)
    tmp = TRACKING_FILE.with_suffix(TRACKING_FILE.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(TRACKING_FILE)


def _collect_yaml_files() -> list[Path]:
    paths: list[Path] = []
    if GLOBAL_INSTINCTS.is_dir():
        paths.extend(sorted(GLOBAL_INSTINCTS.glob("*.yaml")))
    if PROJECTS_DIR.is_dir():
        for proj in sorted(PROJECTS_DIR.iterdir()):
            inst_dir = proj / "instincts"
            if inst_dir.is_dir():
                paths.extend(sorted(inst_dir.glob("*.yaml")))
    return paths


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Merge YAML occurrences+last_seen into instinct-tracking.json")
    parser.add_argument("--apply", action="store_true", help="actually write (default: dry-run)")
    parser.add_argument("--stats", action="store_true", help="print totals only")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    yaml_files = _collect_yaml_files()
    tracking = _load_tracking()
    tracking_before = dict(tracking)  # shallow copy for comparison

    merged = 0
    added = 0
    unchanged = 0
    skipped = 0
    details: list[tuple[str, str]] = []

    for path in yaml_files:
        fields = _parse_yaml_frontmatter(path)
        if not fields:
            skipped += 1
            continue
        iid = fields.get("id")
        if not iid:
            skipped += 1
            continue

        yaml_count = int(fields.get("occurrences") or 0)
        yaml_last_seen = fields.get("last_seen") or None

        entry = tracking.get(iid)
        if entry is None:
            if yaml_count <= 0 and not yaml_last_seen:
                skipped += 1
                continue
            tracking[iid] = {
                "count": yaml_count,
                "sessions": [],
                "projects_seen": [],
                "first_seen": yaml_last_seen or "",
                "last_seen": yaml_last_seen or "",
            }
            added += 1
            details.append((iid, f"NEW   count={yaml_count} last_seen={yaml_last_seen or '-'}"))
            continue

        # Entry exists — merge conservatively (never regress count)
        cur_count = int(entry.get("count") or 0)
        cur_last_seen = entry.get("last_seen") or ""
        changed = False
        if yaml_count > cur_count:
            entry["count"] = yaml_count
            changed = True
        if yaml_last_seen and (not cur_last_seen or yaml_last_seen > cur_last_seen):
            entry["last_seen"] = yaml_last_seen
            if not entry.get("first_seen"):
                entry["first_seen"] = yaml_last_seen
            changed = True
        if changed:
            merged += 1
            details.append((iid, f"MERGE count {cur_count}->{entry['count']} last_seen -> {entry['last_seen']}"))
        else:
            unchanged += 1

    summary = (
        f"YAML files scanned : {len(yaml_files)}\n"
        f"tracking entries   : {len(tracking_before)} -> {len(tracking)}\n"
        f"added              : {added}\n"
        f"merged (updated)   : {merged}\n"
        f"unchanged          : {unchanged}\n"
        f"skipped (no id/no data): {skipped}"
    )
    if args.stats:
        print(summary)
        return 0

    if not args.quiet:
        for iid, line in details[:30]:
            print(f"  {iid:<45} {line}")
        if len(details) > 30:
            print(f"  ... {len(details) - 30} more entries")
        print()
        print(summary)

    will_write = (added + merged) > 0
    if not will_write:
        if not args.quiet:
            print("Nothing to migrate — already consistent.")
        return 0

    if not args.apply:
        print("\n(dry-run — pass --apply to persist. Backup will be written to tracking.json.pre-v4.0)")
        return 0

    if TRACKING_FILE.exists():
        backup = TRACKING_FILE.with_suffix(TRACKING_FILE.suffix + ".pre-v4.0")
        if not backup.exists():
            shutil.copy2(TRACKING_FILE, backup)
            if not args.quiet:
                print(f"Backup written: {backup}")

    _save_tracking(tracking)
    if not args.quiet:
        print(f"Wrote {TRACKING_FILE} ({len(tracking)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
