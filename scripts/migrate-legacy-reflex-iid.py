#!/usr/bin/env python3
"""
migrate-legacy-reflex-iid.py — v3.19.5 one-shot impact.jsonl normalizer

Rewrites historical events that used the legacy `reflex-<id>` (hyphen) prefix
to the canonical `reflex:<id>` (colon) form introduced in v3.18.0 and enforced
on the writer side by `_normalize_iid` in v3.19.4.

Why
---
The v3.19.4 fix (`hooks/lib/impact_log.py:_normalize_iid`) only normalizes new
feedback events as they are written. It does not touch events already on disk,
so dashboards (`/cx-status --impact`) keep displaying split phantom rows for
any reflex that received feedback before v3.19.4 — e.g. `reflex:bash-cat-use-read`
and `reflex-bash-cat-use-read` ranked separately in TOP NOISY.

Behavior
--------
- Scans `~/.claude/cortex/impact.jsonl` (override via `CORTEX_DIR`).
- Rewrites only events whose `iid` starts with `reflex-` AND whose remainder
  matches a real reflex id present in `reflexes.json`. Anything else is
  passed through unchanged. This guards against false positives like a
  hypothetical `reflex-auto-disable` knowledge-log marker that happens to
  share the prefix.
- Idempotent: a second run sees nothing to migrate and exits 0 without
  rewriting the file or creating a duplicate backup.
- Backup: copies `impact.jsonl` to `impact.jsonl.pre-v3.19.5.bak` before
  the first rewrite. Subsequent runs do not overwrite the backup.
- Atomic: writes to a sibling tmp file and renames over the original.
- Reports counts even in dry-run.

Usage
-----
  python3 scripts/migrate-legacy-reflex-iid.py            # dry-run (default)
  python3 scripts/migrate-legacy-reflex-iid.py --apply    # write changes
  python3 scripts/migrate-legacy-reflex-iid.py --stats    # totals only
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

HOME = Path(os.environ.get("HOME") or os.environ.get("USERPROFILE") or "/tmp")
CORTEX_DIR = Path(os.environ.get("CORTEX_DIR") or (HOME / ".claude" / "cortex"))
IMPACT_FILE = CORTEX_DIR / "impact.jsonl"
REFLEXES_FILE = CORTEX_DIR / "reflexes.json"
BACKUP_SUFFIX = ".pre-v3.19.5.bak"


def _load_reflex_ids() -> set[str]:
    """Return the set of reflex ids known to reflexes.json. Empty set if missing."""
    try:
        data = json.loads(REFLEXES_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return set()
    ids: set[str] = set()
    for entry in data.get("reflexes", []):
        rid = entry.get("id")
        if isinstance(rid, str) and rid:
            ids.add(rid)
    return ids


def _normalize_line(raw: str, known_ids: set[str]) -> tuple[str, bool]:
    """Return (rewritten_line, changed?). Pass-through on any parse error."""
    stripped = raw.strip()
    if not stripped:
        return raw, False
    try:
        obj = json.loads(stripped)
    except json.JSONDecodeError:
        return raw, False
    iid = obj.get("iid")
    if not isinstance(iid, str) or not iid.startswith("reflex-"):
        return raw, False
    candidate_id = iid[len("reflex-"):]
    if candidate_id not in known_ids:
        return raw, False
    obj["iid"] = "reflex:" + candidate_id
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n", True


def migrate(apply: bool = False, quiet: bool = False) -> dict:
    """Run the migration. Returns a stats dict."""
    stats = {
        "scanned": 0,
        "rewrote": 0,
        "passthrough": 0,
        "by_iid": {},
        "applied": False,
        "backup": None,
    }
    if not IMPACT_FILE.exists():
        if not quiet:
            print(f"impact.jsonl not found at {IMPACT_FILE} — nothing to do")
        return stats

    known_ids = _load_reflex_ids()
    if not known_ids and not quiet:
        sys.stderr.write(
            f"[warn] {REFLEXES_FILE} missing or empty — no reflex ids known, "
            f"nothing will be rewritten.\n"
        )

    out_lines: list[str] = []
    with open(IMPACT_FILE, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            stats["scanned"] += 1
            new_line, changed = _normalize_line(raw, known_ids)
            out_lines.append(new_line)
            if changed:
                stats["rewrote"] += 1
                # Capture old → new pair for the by_iid breakdown.
                old_obj = json.loads(raw)
                old_iid = old_obj.get("iid", "")
                stats["by_iid"][old_iid] = stats["by_iid"].get(old_iid, 0) + 1
            else:
                stats["passthrough"] += 1

    if stats["rewrote"] == 0:
        if not quiet:
            print(
                f"scanned {stats['scanned']} events — already canonical, "
                f"nothing to migrate"
            )
        return stats

    if not apply:
        if not quiet:
            print(
                f"DRY-RUN: would rewrite {stats['rewrote']} of "
                f"{stats['scanned']} events"
            )
            for old_iid, count in sorted(
                stats["by_iid"].items(), key=lambda kv: -kv[1]
            ):
                new_iid = "reflex:" + old_iid[len("reflex-"):]
                print(f"  {count:>4}  {old_iid}  ->  {new_iid}")
            print("\n(dry-run — pass --apply to persist)")
        return stats

    backup_path = IMPACT_FILE.with_suffix(IMPACT_FILE.suffix + BACKUP_SUFFIX)
    if not backup_path.exists():
        shutil.copy2(IMPACT_FILE, backup_path)
        stats["backup"] = str(backup_path)
        if not quiet:
            print(f"backup written: {backup_path}")
    elif not quiet:
        print(f"backup already exists: {backup_path} (preserving)")

    tmp = IMPACT_FILE.with_suffix(IMPACT_FILE.suffix + f".tmp.{os.getpid()}")
    tmp.write_text("".join(out_lines), encoding="utf-8")
    tmp.replace(IMPACT_FILE)
    stats["applied"] = True

    if not quiet:
        print(f"rewrote {stats['rewrote']} events in {IMPACT_FILE}")
        for old_iid, count in sorted(
            stats["by_iid"].items(), key=lambda kv: -kv[1]
        ):
            new_iid = "reflex:" + old_iid[len("reflex-"):]
            print(f"  {count:>4}  {old_iid}  ->  {new_iid}")
    return stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Normalize legacy reflex-<id> iids in impact.jsonl"
    )
    parser.add_argument("--apply", action="store_true", help="actually write (default: dry-run)")
    parser.add_argument("--stats", action="store_true", help="print summary only")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    stats = migrate(apply=args.apply, quiet=args.quiet or args.stats)

    if args.stats:
        print(
            f"scanned: {stats['scanned']}\n"
            f"rewrote: {stats['rewrote']}\n"
            f"passthrough: {stats['passthrough']}\n"
            f"applied: {stats['applied']}\n"
            f"backup: {stats['backup'] or '-'}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
