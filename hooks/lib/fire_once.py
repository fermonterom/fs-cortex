"""
fire_once.py — Sprint 1.11 (v3.15.0)

Reusable "one-shot per session (with optional TTL) + stale cleanup" primitive.

Problem this solves:
  Several Cortex hooks want to inject something EXACTLY ONCE per session_id
  (EOD resume, context bridge, skills hint, precompact flush). Each has its
  own bespoke marker scheme. fire_once provides the canonical helper so new
  hooks don't reinvent the pattern and old hooks can migrate when touched.

Two API shapes:

  from hooks.lib import fire_once

  # (a) Explicit check + mark, two calls. Useful when the work in between
  #     is long or side-effect heavy and we want to mark as fired even if
  #     it partially failed.
  if fire_once.not_fired(name="eod-resume", sid=session_id):
      do_work()
      fire_once.mark(name="eod-resume", sid=session_id)

  # (b) Context manager, marks on exit regardless of exception (unless
  #     force_mark=False is passed to __exit__).
  with fire_once.once(name="precompact-flush", sid=session_id) as fire:
      if fire:
          do_work()

  # (c) Decorator — fire-once per (callable, sid). Rare; prefer (a).

Cleanup helper:

  fire_once.cleanup_stale(max_age_hours=24)

Markers live under $CORTEX_DIR/.fire-once/<name>-<sid12>. The short sid is
truncated to 24 chars (same as impact_log session prefix) to keep filenames
bounded.
"""
from __future__ import annotations

import os
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

HOME = Path(os.environ.get("HOME") or os.environ.get("USERPROFILE") or "/tmp")
CORTEX_DIR = Path(os.environ.get("CORTEX_DIR") or (HOME / ".claude" / "cortex"))
FIRE_ONCE_DIR = CORTEX_DIR / ".fire-once"
DEFAULT_MAX_AGE_HOURS = 24


# ── path helpers ────────────────────────────────────────────────────────────

def _safe_slug(value: str, maxlen: int = 24) -> str:
    """Trim + replace filesystem-unfriendly chars. Empty → 'anon'."""
    if not value:
        return "anon"
    cleaned = "".join(c if (c.isalnum() or c in "-_") else "_" for c in value[:maxlen])
    return cleaned or "anon"


def _marker_path(name: str, sid: str) -> Path:
    FIRE_ONCE_DIR.mkdir(parents=True, exist_ok=True)
    return FIRE_ONCE_DIR / f"{_safe_slug(name, 32)}-{_safe_slug(sid, 24)}"


# ── public API ──────────────────────────────────────────────────────────────

def not_fired(name: str, sid: str, ttl_hours: int | None = None) -> bool:
    """
    Return True if the marker does NOT yet exist (or is older than ttl_hours).
    False means "already fired within TTL — skip".
    """
    path = _marker_path(name, sid)
    if not path.exists():
        return True
    if ttl_hours is None:
        return False
    try:
        age_seconds = time.time() - path.stat().st_mtime
    except OSError:
        return True
    return age_seconds > ttl_hours * 3600


def mark(name: str, sid: str) -> None:
    """Touch the marker. Safe to call repeatedly."""
    try:
        path = _marker_path(name, sid)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(exist_ok=True)
    except OSError:
        # Never let the marker failure block the calling hook.
        pass


def unmark(name: str, sid: str) -> None:
    """Remove a marker. Used by tests and by deliberate re-firing."""
    try:
        _marker_path(name, sid).unlink(missing_ok=True)
    except OSError:
        pass


@contextmanager
def once(name: str, sid: str, ttl_hours: int | None = None) -> Iterator[bool]:
    """
    Context manager variant.

    Example:
        with fire_once.once("eod-resume", session_id) as should_fire:
            if should_fire:
                inject_eod()

    Marks on __exit__ ONLY when should_fire was True (so a skipped call does
    not refresh the timestamp). If the caller raises, mark still happens —
    semantics: "we fired once even if it errored halfway".
    """
    should_fire = not_fired(name, sid, ttl_hours)
    try:
        yield should_fire
    finally:
        if should_fire:
            mark(name, sid)


# ── maintenance ─────────────────────────────────────────────────────────────

def cleanup_stale(max_age_hours: int = DEFAULT_MAX_AGE_HOURS) -> int:
    """
    Remove marker files older than max_age_hours. Returns count deleted.
    Safe to call from SessionStart hooks; best-effort.
    """
    if not FIRE_ONCE_DIR.exists():
        return 0
    now = time.time()
    cutoff = max_age_hours * 3600
    deleted = 0
    try:
        for entry in FIRE_ONCE_DIR.iterdir():
            if not entry.is_file():
                continue
            try:
                if now - entry.stat().st_mtime > cutoff:
                    entry.unlink(missing_ok=True)
                    deleted += 1
            except OSError:
                continue
    except OSError:
        pass
    return deleted
