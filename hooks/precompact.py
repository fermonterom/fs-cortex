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


def _spawn_learner(stdin_bytes: bytes, sid: str) -> None:
    if not LEARNER.exists():
        return
    # v3.29.0 §4.15: export CORTEX_SESSION_ID into the child env BEFORE spawn.
    # session-learner.js reads `process.env.CORTEX_SESSION_ID` as the primary
    # session-id source (with stdin payload as fallback). Pre-v3.29 we only
    # piped the payload through stdin, which works but is fragile under
    # /compact's signal handling — if SIGPIPE arrives between fork and the
    # first stdin.write, the child sees empty stdin and falls back to
    # `observations[0].sid` (the FIRST observation's session id), which
    # could be a stale/orphan session. Setting the env var is belt-and-
    # suspenders: even if the stdin pipe fails, the child still has the
    # correct sid.
    child_env = os.environ.copy()
    if sid and sid != "anon":
        child_env["CORTEX_SESSION_ID"] = sid
    try:
        proc = subprocess.Popen(
            ["node", str(LEARNER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # detach from the compact caller
            close_fds=True,
            env=child_env,
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
    # v3.29.0 §4.15: kill-switch checks BEFORE any work. CORTEX_OBSERVE_OFF
    # and CORTEX_DETECTORS_OFF both imply "don't run the learner this cycle"
    # — precompact would otherwise wake the learner anyway, defeating the
    # switch. Honored here so the operator's intent is consistent across
    # both Stop and PreCompact entry points.
    if os.environ.get("CORTEX_OBSERVE_OFF", "0") == "1":
        return 0
    if os.environ.get("CORTEX_DETECTORS_OFF", "0") == "1":
        return 0

    # v3.29.0 §4.15: wrap the entire body so any exception path still exits
    # 0. Pre-v3.29 only the spawn block was protected; an exception in
    # _parse_session_id or _already_flushed would have bubbled up and the
    # /compact operation would see a non-zero return — Claude Code logs
    # this as a hook failure even though precompact is supposed to be
    # fire-and-forget.
    try:
        raw = _read_stdin()
        sid = _parse_session_id(raw) or "anon"

        # Double-flush guard: if /compact fires twice in quick succession,
        # do nothing.
        if _already_flushed(sid):
            return 0

        _spawn_learner(raw.encode("utf-8"), sid)
        _touch_marker(sid)
    except Exception:
        # Never bubble — the hook contract is "exit 0 always".
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
