#!/usr/bin/env python3
# CORTEX-MANAGED — do not edit manually, updated by install.sh
# PreCompact hook — flush session-learner before Claude Code compacts the conversation.
#
# Sprint 1.9 (v3.15.0). Problem: /compact cuts the conversation without running the
# Stop hook, so pending proposals / impact follow-events are lost. Fix: register a
# PreCompact event in settings.json that runs THIS script, which fire-and-forgets
# session-learner.js inheriting the same stdin payload.
#
# Contract with Claude Code:
#   - stdin: JSON with at least {session_id, ...} (same shape as Stop hook)
#   - timeout: 8000ms (configured in install.sh)
#   - exit 0: always (never block the /compact operation)
#
# The launched session-learner enforces its own 15s internal timeout, so even if
# PreCompact killed this wrapper after 8s, the child process keeps running
# detached and finishes on its own.

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HOME = Path(os.environ.get("HOME") or os.environ.get("USERPROFILE") or "/tmp")
CORTEX_DIR = Path(os.environ.get("CORTEX_DIR") or (HOME / ".claude" / "cortex"))
LEARNER = HOME / ".claude" / "hooks" / "cortex" / "session-learner.js"

# Optional fire_once helper (Sprint 1.11). Fallback to inline marker if missing.
_fire_once = None
try:
    _lib_dir = Path(__file__).resolve().parent / "lib"
    sys.path.insert(0, str(_lib_dir))
    import fire_once as _fire_once  # type: ignore[import]
finally:
    pass

MARKER_NAME = "precompact-flush"


def _read_stdin() -> str:
    try:
        return sys.stdin.read()
    except Exception:
        return ""


def _parse_session_id(raw: str) -> str | None:
    if not raw.strip():
        return None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None
    sid = payload.get("session_id")
    if not isinstance(sid, str):
        return None
    return sid[:24]


def _touch_marker(sid: str) -> None:
    if _fire_once is not None:
        _fire_once.mark(MARKER_NAME, sid)
        return
    try:
        CORTEX_DIR.mkdir(parents=True, exist_ok=True)
        (CORTEX_DIR / f".precompact-flushed-{sid}").touch(exist_ok=True)
    except OSError:
        pass


def _already_flushed(sid: str) -> bool:
    if _fire_once is not None:
        # not_fired() is "safe to fire" → invert for "already flushed"
        return not _fire_once.not_fired(MARKER_NAME, sid, ttl_hours=1)
    try:
        return (CORTEX_DIR / f".precompact-flushed-{sid}").exists()
    except OSError:
        return False


def _spawn_learner(stdin_bytes: bytes) -> None:
    if not LEARNER.exists():
        return
    try:
        proc = subprocess.Popen(
            ["node", str(LEARNER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # detach from the compact caller
            close_fds=True,
        )
        if proc.stdin is not None:
            try:
                proc.stdin.write(stdin_bytes)
            except (BrokenPipeError, OSError):
                pass
            finally:
                try:
                    proc.stdin.close()
                except OSError:
                    pass
    except (OSError, FileNotFoundError):
        # `node` missing or learner unreadable — never block compact
        pass


def main() -> int:
    raw = _read_stdin()
    sid = _parse_session_id(raw) or "anon"

    # Double-flush guard: if /compact fires twice in quick succession, do nothing.
    if _already_flushed(sid):
        return 0

    _spawn_learner(raw.encode("utf-8"))
    _touch_marker(sid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
