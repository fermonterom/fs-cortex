"""Cortex Regex Guard — shared ReDoS protection (v3.23.4+).

Python parity of lib/regex-guard.js. Single source of truth for the
limits applied to reflex matchers/conditions and instinct triggers.

Limits raised in v3.23.4 to fix the bash-cat-use-read silent regression:
    MAX_LEN     100 → 200
    MAX_PIPES     5 → 25
    REDOS_DETECTOR removed `?` (only `+` and `*` cause exponential paths)

Python does not run this guard in PreToolUse latency-sensitive code paths,
so the live timeout check is omitted here — we keep parity on the static
shape only. The Node implementation is the authoritative runtime guard.
"""

from __future__ import annotations

import re
import sys

MAX_LEN = 200
MAX_PIPES = 25
LIVE_TIMEOUT_MS = 50  # parity with JS; Python guard does NOT enforce live timeout

# Catastrophic backtracking detector. Mirrors the JS regex.
# `(a+)+`, `(a+)*`, `(a*)+`, `(a*)*` flagged. `(a+)?` is SAFE.
REDOS_DETECTOR = re.compile(r"\([^)]*[+*]\)[+*]")

# Process-local dedup so a malformed pattern does not spam stderr on every call.
# Bounded to avoid unbounded growth; reset on process restart.
_LOGGED_REJECTIONS = set()
_LOGGED_REJECTIONS_MAX = 256


def unsafe_reason(pattern):
    """Return None if pattern is safe, else a short reason string.

    Reasons: "non-string" | "len>200" | "redos" | "pipes>25" | "invalid".
    """
    if not isinstance(pattern, str):
        return "non-string"
    if len(pattern) > MAX_LEN:
        return f"len>{MAX_LEN}"
    if REDOS_DETECTOR.search(pattern):
        return "redos"
    if pattern.count("|") > MAX_PIPES:
        return f"pipes>{MAX_PIPES}"
    try:
        re.compile(pattern)
    except re.error:
        return "invalid"
    return None


def is_safe_regex(pattern):
    """Boolean wrapper around unsafe_reason."""
    return unsafe_reason(pattern) is None


def validate_instinct_trigger(pattern):
    """Validate trigger regex. Returns (is_valid, reason_string).

    Kept as compatibility shim for dream_cycle.calculate_health_score and
    other callers that expect the (bool, str) tuple shape.
    """
    if not pattern or not isinstance(pattern, str):
        return False, "Empty or non-string trigger"
    reason = unsafe_reason(pattern)
    if reason is None:
        return True, "OK"
    if reason.startswith("len"):
        return False, f"Trigger too long ({len(pattern)} chars, max {MAX_LEN})"
    if reason == "redos":
        return False, "Nested quantifiers (ReDoS risk)"
    if reason.startswith("pipes"):
        return False, f"Too many alternations (max {MAX_PIPES})"
    if reason == "invalid":
        try:
            re.compile(pattern)
        except re.error as exc:
            return False, f"Invalid regex: {exc}"
    return False, reason


def log_rejection(tag, pattern, reason):
    """Best-effort stderr log when a pattern is rejected.
    Deduped per (tag, reason, pattern[:64]) within the current process.
    """
    try:
        snippet = pattern[:64] if isinstance(pattern, str) else "?"
        key = f"{tag}|{reason}|{snippet}"
        if key in _LOGGED_REJECTIONS:
            return
        if len(_LOGGED_REJECTIONS) < _LOGGED_REJECTIONS_MAX:
            _LOGGED_REJECTIONS.add(key)
        plen = len(pattern) if isinstance(pattern, str) else "?"
        sys.stderr.write(
            f"[cortex:guard] rejected pattern in {tag}: {reason} (len={plen})\n"
        )
    except Exception:
        pass
