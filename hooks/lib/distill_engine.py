#!/usr/bin/env python3
"""
distill_engine.py — Auto-distillation engine (Sprint 7, v3.23.0).

Deterministic parts of the distillation pipeline that run automatically at
SessionStart (once per 24 h, idempotent) without any human judgment:
  1. Confidence decay  (-0.05 per 30 days unused)
  2. Archive low-confidence instincts (< 0.10)
  3. Auto-validate proposals that meet whitelist criteria (Sprint 7)
  4. Promote mature instincts to laws (STRICT 7-criteria gate)
  5. Auto-evolve: detect clusters of mature instincts, generate skill drafts (Sprint 7)

Public API
----------
  run_auto_distill(dry_run=False) -> dict
  apply_decay(now=None, dry_run=False) -> list[dict]
  archive_decayed(threshold=0.10, dry_run=False) -> list[str]
  auto_validate_proposals(dry_run=False) -> dict
  auto_promote_to_law(dry_run=False) -> tuple[list[dict], list[dict]]
  auto_evolve_detect(dry_run=False) -> dict

CLI
---
  python3 distill_engine.py auto [--dry-run]
  python3 distill_engine.py decay [--dry-run]
  python3 distill_engine.py promote [--dry-run]
  python3 distill_engine.py status
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any

# Robust import: ensure lib/ is on sys.path even when invoked from a foreign cwd.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)

from regex_guard import unsafe_reason as _guard_unsafe_reason
from validate_instinct import validate_yaml_content as _validate_yaml_content

# ── Environment & paths ─────────────────────────────────────────────────────

CORTEX_DIR = Path(os.environ.get("CORTEX_DIR", str(Path.home() / ".claude" / "cortex")))
INSTINCTS_DIR = CORTEX_DIR / "instincts" / "global"
LAWS_DIR = CORTEX_DIR / "laws"
IMPACT_FILE = CORTEX_DIR / "impact.jsonl"
KNOWLEDGE_LOG = CORTEX_DIR / "knowledge-log.md"
CANDIDATES_FILE = CORTEX_DIR / "auto-distill-candidates.md"
MARKER_FILE = CORTEX_DIR / ".last-auto-distill"
LOCK_FILE = CORTEX_DIR / ".distill-engine.lock"
PROPOSALS_FILE = CORTEX_DIR / "proposals.json"
# v3.29.5 §F5 storage split: terminal-state (accepted/rejected) is appended
# to this JSONL by session-learner.js after the per-Stop split. Source of
# truth for v3.32.0 §4.4 promotion gate (AD P0-1 — `proposals.json` only
# carries the live pending/held entries).
PROPOSALS_HISTORY_FILE = CORTEX_DIR / "proposals-history.jsonl"
PROMOTED_DETECTORS_FILE = CORTEX_DIR / ".promoted-detectors.json"
SECURITY_LOG_FILE = CORTEX_DIR / "log" / "security-events.jsonl"
EVOLVED_SKILLS_DIR = CORTEX_DIR / "evolved" / "skills"
SKILLS_DIR = Path(os.environ.get("SKILLS_DIR", str(Path.home() / ".claude" / "skills")))
# v3.29.0 §4.16: source of truth for the multi-session promotion gate.
# injector-engine.js writes here on every PreToolUse match — dedup'd, cap 20
# entries per instinct.
INSTINCT_TRACKING_FILE = CORTEX_DIR / "instinct-tracking.json"

RATE_LIMIT_HOURS = 24
DECAY_PER_30_DAYS = 0.05
DECAY_PERIOD_DAYS = 30
ARCHIVE_THRESHOLD = 0.10
LAW_THRESHOLD_CONF = 0.95
LAW_SUSTAINED_DAYS = 14
LAW_MIN_PROJECTS = 1  # v3.24.0: was 3 — unreachable for solo-project knowledge.
                      # Audit C found: 11 mature instincts at conf>=0.95 but
                      # zero promoted ever, because most learnings happen in
                      # 1-2 projects and `_count_distinct_projects >= 3` was a
                      # permanent dead-end. Lowered to 1: the other gates
                      # (LAW_THRESHOLD_CONF=0.95, LAW_SUSTAINED_DAYS=14,
                      # LAW_MIN_USEFUL_14D=5, LAW_MAX_NOISE_14D=0,
                      # LAW_JACCARD_THRESHOLD=0.50) still preserve quality.
LAW_MIN_USEFUL_14D = 5
LAW_MAX_NOISE_14D = 0
LAW_MAX_ACTIVE = 15  # v3.32.0 §4.5: was 12. Raise + deprecation policy
                     # hybrid (Sprint 9 D4): subir cap da espacio inmediato a
                     # candidates conf=0.95 bloqueados HOY; el algoritmo de
                     # deprecación (_find_least_impactful_law + age guard
                     # LAW_DEPRECATE_MIN_AGE_DAYS=7) cubre la saturación
                     # futura. v3.29.2 había subido de 10 → 12.
                     # Token cost: +120 tok/session baseline (3 extra laws × 40).
                     # Quality gate intact (LAW_THRESHOLD_CONF, LAW_SUSTAINED_DAYS,
                     # LAW_MIN_DISTINCT_SESSIONS, LAW_MAX_NOISE_14D unchanged).
LAW_DEPRECATE_MIN_AGE_DAYS = 7  # v3.32.0 §4.5 (AD P1-3): laws younger than
                                # this are NOT deprecation candidates. Without
                                # the age guard a freshly-promoted law without
                                # accumulated impact data would have ratio=0
                                # and be marked for immediate deprecation
                                # before getting a chance to be exercised.
LAW_JACCARD_THRESHOLD = 0.50
LAW_MAX_CHARS = 120
# v3.29.0 §4.16: minimum distinct sessions (UUIDs) where an instinct must
# have fired before it can be promoted to a law. Single-session bursts —
# e.g. one very long debugging session producing 25 file-coupling
# proposals 24 of which the operator accepts out of fatigue — won't pass
# until at least 3 different sessions have seen the same pattern.
LAW_MIN_DISTINCT_SESSIONS = 3

# v3.32.0 §4.4 — promotion gate HUMAN → AUTO. Source: proposals-history.jsonl
# (AD P0-1). Statistical-strict: prefer false negatives (no promote) over
# false positives (promote noise). A detector becomes AUTO-eligible only
# when n ≥ 20 reviewed AND accept_rate ≥ 70% AND distinct_sessions ≥ 3 AND
# critical_rejections == 0. Visibility tier at n=10 surfaces partial progress
# in /cx-status without enabling promotion (AD P1-2).
PROMOTE_REVIEW_THRESHOLD = 10        # visibility tier — not promotion
PROMOTE_AUTO_THRESHOLD = 20          # AUTO-eligibility floor
PROMOTE_ACCEPT_RATE = 0.70
PROMOTE_MIN_SESSIONS = 3

# v3.32.0 §4.4.c — rejection_category enum (AD P1-6). Optional field new
# rejects via /cx-validate. Legacy rejects without the field fall back to
# a keyword heuristic over rejected_reason (ES + EN).
CRITICAL_REJECTION_CATEGORIES = frozenset({"security", "breaking", "injection"})
CRITICAL_REJECTION_KEYWORDS_FALLBACK = (
    # ES
    "seguridad", "inseguro", "rompedor", "inyecci", "vulnerab",
    # EN
    "security", "breaking", "injection", "unsafe", "vulnerab",
)
REJECTION_CATEGORY_ENUM = frozenset({
    "security", "breaking", "injection", "noise", "other",
})

# Sprint 7 — auto-validate
VALIDATE_MIN_CONF = 0.50
VALIDATE_AUTO_DOMAINS = {"gotcha", "pattern", "error-recovery", "agent-evolution"}
# v3.29.0 (Sprint 8 §4.1): added 'coupling' + 'agent-quality'. Pre-v3.29.0 these
# were orphan domains — emitted by detectFileCoupling + detectAgentSubtypes but
# absent from every whitelist, so every proposal fell through to
# `needs-human-judgment` skip and never produced an instinct. Registering them
# here lets the operator review them via `/cx-validate` and decide manually
# (human-gated, exactly as the Sprint 8 detector overhaul intends).
VALIDATE_HUMAN_DOMAINS = {"correction", "user-preference", "decision", "workflow",
                          "coupling", "agent-quality"}

# v3.29.5 §F1 — Union of every domain that auto_validate_proposals knows how to
# handle. Any proposal whose domain falls outside this set is HELD (not pending,
# not silently rejected) with hold_reason="orphan-domain:<name>" so the operator
# sees it via /cx-validate and the engineering team gets a signal that the
# detector emitting that domain is missing from the whitelists.
KNOWN_DOMAINS = VALIDATE_AUTO_DOMAINS | VALIDATE_HUMAN_DOMAINS

# v3.29.0 (Sprint 8 §4.7): whitelist of authorized rejecter identities for the
# ghost-guard. Any proposal carrying a rejected status with `rejected_by` NOT
# in this set will be restored to pending by `_detect_unauthorized_rejections`.
# `cx-validate-auto` is INTENTIONALLY excluded — on 2026-05-05 an unidentified
# external script bulk-rejected 648 proposals as that identity; until the
# source is found (see docs/GHOST-CX-VALIDATE-AUTO.md), we treat any reject
# from `cx-validate-auto` as unauthorized.
VALIDATE_AUTHORIZED_REJECTERS = {
    "cx-validate",         # manual /cx-validate
    "cx-auto-validate",    # auto_validate_proposals (this module)
    "cx-cleanup",          # ops cleanup
    "v3.28.9-cleanup",     # bulk-reject we did in v3.28.9
    None,                  # legacy: pre-Sprint-7 acceptances
}

# Sprint 7 — auto-evolve
EVOLVE_MIN_CONF = 0.70
EVOLVE_CLUSTER_MIN = 3
EVOLVE_JACCARD_MIN = 0.50

STOPWORDS = {"the", "a", "an", "of", "to", "and", "or", "is", "in"}

# ── YAML frontmatter helpers ─────────────────────────────────────────────────

_FRONT_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)
_SCALAR_RE = re.compile(
    r'^(?P<key>[A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(?P<val>.+?)\s*$'
)
_LIST_START_RE = re.compile(r'^(?P<key>[A-Za-z_][A-Za-z0-9_-]*)\s*:\s*$')
_LIST_ITEM_RE = re.compile(r'^\s*-\s*(?P<item>.+?)\s*$')


def _parse_frontmatter(text: str) -> tuple[dict, str]:
    """Parse YAML frontmatter (no PyYAML dep). Returns (fields, body_after_fence).
    Supports: scalar strings/numbers/dates, list of strings (- item lines).
    """
    m = _FRONT_RE.match(text)
    if not m:
        return {}, text

    front = m.group(1)
    rest = text[m.end():]
    fields: dict[str, Any] = {}
    lines = front.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        # List key: "key:"
        lm = _LIST_START_RE.match(line)
        if lm:
            key = lm.group("key")
            items: list[str] = []
            i += 1
            while i < len(lines):
                im = _LIST_ITEM_RE.match(lines[i])
                if im:
                    items.append(_strip_quotes(im.group("item")))
                    i += 1
                else:
                    break
            fields[key] = items
            continue
        # Scalar key: "key: value"
        sm = _SCALAR_RE.match(line)
        if sm:
            key = sm.group("key")
            val = _strip_quotes(sm.group("val"))
            # Try numeric coercion
            try:
                val = int(val)
            except (ValueError, TypeError):
                try:
                    val = float(val)
                except (ValueError, TypeError):
                    pass
            fields[key] = val
        i += 1
    return fields, rest


def _strip_quotes(val: str) -> str:
    if (val.startswith('"') and val.endswith('"')) or \
       (val.startswith("'") and val.endswith("'")):
        return val[1:-1]
    return val


def _set_frontmatter_field(text: str, key: str, value: Any) -> str:
    """Update or insert a scalar field in the YAML frontmatter, preserving all other content."""
    m = _FRONT_RE.match(text)
    if not m:
        # No frontmatter — prepend it
        new_front = f"---\n{key}: {value}\n---\n"
        return new_front + text

    front = m.group(1)
    rest = text[m.end():]
    lines = front.splitlines()

    new_lines = []
    found = False
    for line in lines:
        sm = _SCALAR_RE.match(line)
        if sm and sm.group("key") == key:
            new_lines.append(f"{key}: {value}")
            found = True
        else:
            new_lines.append(line)

    if not found:
        new_lines.append(f"{key}: {value}")

    new_front = "\n".join(new_lines)
    return f"---\n{new_front}\n---\n{rest}"


def _remove_frontmatter_field(text: str, key: str) -> str:
    """Remove a scalar field from the YAML frontmatter."""
    m = _FRONT_RE.match(text)
    if not m:
        return text
    front = m.group(1)
    rest = text[m.end():]
    lines = front.splitlines()
    new_lines = [ln for ln in lines if not (_SCALAR_RE.match(ln) and _SCALAR_RE.match(ln).group("key") == key)]
    new_front = "\n".join(new_lines)
    return f"---\n{new_front}\n---\n{rest}"


def _atomic_write(path: Path, content: str) -> None:
    """Write content atomically: tmp then os.replace.

    v3.29.4: try/finally around os.replace so a failed replace (EACCES,
    cross-device move, EBUSY on Windows) does not leak the .tmp.PID file.
    Matches the pattern already used in hooks/observe.py:atomic_write_json.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(content, encoding="utf-8")
    try:
        os.replace(tmp, path)
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


# ── File discovery ────────────────────────────────────────────────────────────

def _all_instinct_paths() -> list[Path]:
    """All active (non-archived) instinct YAML paths."""
    paths: list[Path] = []
    # Global instincts
    g_dir = CORTEX_DIR / "instincts" / "global"
    if g_dir.is_dir():
        for p in sorted(g_dir.glob("*.yaml")):
            if "archive" not in str(p):
                paths.append(p)
    # Project instincts
    proj_dir = CORTEX_DIR / "projects"
    if proj_dir.is_dir():
        for proj in sorted(proj_dir.iterdir()):
            inst_dir = proj / "instincts"
            if inst_dir.is_dir():
                for p in sorted(inst_dir.glob("*.yaml")):
                    if "archive" not in str(p):
                        paths.append(p)
    return paths


def _read_instinct(path: Path) -> tuple[dict, str] | None:
    """Read an instinct YAML. Returns (fields, full_text) or None on error."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.startswith("---"):
        return None
    fields, _ = _parse_frontmatter(text)
    if not fields.get("id"):
        return None
    return fields, text


# ── Locking ──────────────────────────────────────────────────────────────────

def _lock_acquire(nonblocking: bool = False):
    """Acquire advisory lock. Returns (fh, True) if acquired, (None, False) if busy."""
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        return None, True  # No fcntl on Windows — no-op
    try:
        import fcntl
        fh = open(LOCK_FILE, "w", encoding="utf-8")
        flag = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
        try:
            fcntl.flock(fh.fileno(), flag)
            return fh, True
        except BlockingIOError:
            fh.close()
            return None, False
    except (ImportError, OSError):
        return None, True


def _lock_release(fh) -> None:
    if fh is None:
        return
    try:
        import fcntl
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    except Exception:
        pass
    try:
        fh.close()
    except Exception:
        pass


# ── Knowledge log ─────────────────────────────────────────────────────────────

def _log_knowledge(event: str, iid: str, detail: str, source: str = "cx-auto-distill") -> None:
    """Append one line to knowledge-log.md.

    v3.24.0: source is now a real parameter — pre-v3.24.0 it was hardcoded
    to "cx-auto-distill" so accepted/held events from cx-auto-validate and
    evolve-draft events from cx-auto-evolve were mis-sourced, and
    `compute_pipeline_stats` couldn't find them (the parser keys on the
    last `|`-separated field). Counters silently reported zero auto-pipeline
    activity even when it ran successfully.
    """
    today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
    line = f"{today} | {event} | {iid} | {detail} | {source}\n"
    try:
        KNOWLEDGE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(KNOWLEDGE_LOG, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


# ── Impact log helpers ────────────────────────────────────────────────────────

def _iter_impact_events(since_days: int | None = None):
    """Iterate impact.jsonl events, optionally filtering to recent N days."""
    if not IMPACT_FILE.exists():
        return
    cutoff: _dt.datetime | None = None
    if since_days is not None:
        cutoff = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=since_days)
    try:
        with open(IMPACT_FILE, "r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if cutoff is not None:
                    ts_raw = obj.get("ts", "")
                    try:
                        when = _dt.datetime.strptime(ts_raw, "%Y-%m-%dT%H:%M:%SZ").replace(
                            tzinfo=_dt.timezone.utc
                        )
                    except ValueError:
                        continue
                    if when < cutoff:
                        continue
                yield obj
    except OSError:
        pass


def _impact_per_iid(days: int = 14) -> dict[str, dict]:
    """Compute per-iid useful and noise counts for the last `days` days."""
    per: dict[str, dict] = {}
    for ev in _iter_impact_events(since_days=days):
        iid = ev.get("iid")
        if not iid:
            continue
        b = per.setdefault(iid, {"useful": 0, "noise": 0})
        kind = ev.get("ev")
        if kind == "feedback":
            rating = ev.get("rating")
            if rating == "useful":
                b["useful"] += 1
            elif rating == "noise":
                b["noise"] += 1
        elif kind == "follow":
            if ev.get("followed") is True and not ev.get("err_after"):
                b["useful"] += 1
            elif ev.get("followed") is False:
                b["noise"] += 1
        elif kind == "reject":
            b["noise"] += 1
    return per


# ── Jaccard similarity ────────────────────────────────────────────────────────

def _tokenize(text: str) -> set[str]:
    """Lowercase, split on non-word chars, drop stopwords."""
    tokens = set(re.split(r"\W+", text.lower()))
    tokens.discard("")
    return tokens - STOPWORDS


def _jaccard(a: str, b: str) -> float:
    ta, tb = _tokenize(a), _tokenize(b)
    if not ta and not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb)


# ── 1. Decay ─────────────────────────────────────────────────────────────────

def apply_decay(now: _dt.datetime | None = None, dry_run: bool = False) -> list[dict]:
    """Apply -0.05 per 30 days unused decay to all active instinct YAMLs.

    Decay is computed from `last_seen` (or `first_seen` as fallback).
    A `last_decay_at` field is written so consecutive same-day calls are no-ops.
    Returns list of {id, old_conf, new_conf, days_unused}.
    """
    if now is None:
        now = _dt.datetime.now(_dt.timezone.utc)
    today_str = now.strftime("%Y-%m-%d")
    changed: list[dict] = []

    for path in _all_instinct_paths():
        result = _read_instinct(path)
        if result is None:
            continue
        fields, text = result
        iid = str(fields.get("id", ""))
        conf = fields.get("confidence")
        if conf is None:
            continue
        try:
            conf = float(conf)
        except (TypeError, ValueError):
            continue

        # Idempotency: skip if already decayed today
        last_decay_at = str(fields.get("last_decay_at", ""))
        if last_decay_at == today_str:
            continue

        # v3.24.0: anchor decay window on last_decay_at when present, not on
        # last_seen. Pre-v3.24.0 the formula `(now - last_seen).days // 30`
        # kept yielding >=1 every day after day 30 because last_seen never
        # advanced — so an instinct decayed -0.05 daily instead of -0.05/30d.
        # By preferring last_decay_at as the baseline, we measure "days since
        # the previous decay" and a fresh decay only applies once the next
        # 30-day window has elapsed.
        baseline_str = str(
            fields.get("last_decay_at", "")
            or fields.get("last_seen", "")
            or fields.get("first_seen", "")
            or ""
        )
        if not baseline_str:
            continue
        try:
            baseline = _dt.datetime.strptime(baseline_str[:10], "%Y-%m-%d").replace(
                tzinfo=_dt.timezone.utc
            )
        except ValueError:
            continue

        days_unused = (now - baseline).days
        if days_unused < DECAY_PERIOD_DAYS:
            continue  # Not old enough to decay (one period since last decay/seen)

        periods = days_unused // DECAY_PERIOD_DAYS
        decay = periods * DECAY_PER_30_DAYS
        new_conf = max(0.0, round(conf - decay, 4))

        changed.append({
            "id": iid,
            "path": str(path),
            "old_conf": round(conf, 4),
            "new_conf": new_conf,
            "days_unused": days_unused,
        })

        if not dry_run:
            # Update confidence
            new_text = re.sub(
                r'^(confidence\s*:\s*)["\']?[\d.]+["\']?\s*$',
                lambda m: f"confidence: {new_conf:.4f}",
                text,
                count=1,
                flags=re.MULTILINE,
            )
            # Update last_decay_at
            new_text = _set_frontmatter_field(new_text, "last_decay_at", today_str)
            _atomic_write(path, new_text)
            _log_knowledge("decayed", iid, f"conf {conf:.4f} → {new_conf:.4f} ({days_unused}d unused)")

    return changed


# ── 2. Archive ────────────────────────────────────────────────────────────────

def archive_decayed(threshold: float = ARCHIVE_THRESHOLD, dry_run: bool = False) -> list[str]:
    """Move instincts with confidence < threshold to their archive/ subdirectory.

    Returns list of instinct ids archived.
    """
    archived: list[str] = []

    for path in _all_instinct_paths():
        result = _read_instinct(path)
        if result is None:
            continue
        fields, text = result
        iid = str(fields.get("id", ""))
        conf = fields.get("confidence")
        if conf is None:
            continue
        try:
            conf = float(conf)
        except (TypeError, ValueError):
            continue

        if conf >= threshold:
            continue

        # Determine archive destination: same parent dir / archive /
        archive_dir = path.parent / "archive"
        dest = archive_dir / path.name

        archived.append(iid)

        if not dry_run:
            archive_dir.mkdir(parents=True, exist_ok=True)
            path.rename(dest)
            _log_knowledge("archived", iid, f"conf {conf:.4f} < {threshold}")

    return archived


# ── 3. Auto-promote to law ────────────────────────────────────────────────────

def _count_distinct_projects(fields: dict, iid: str) -> int:
    """Count distinct project hashes where this instinct has been seen."""
    seen: set[str] = set()

    # From the YAML itself
    pid = str(fields.get("project_id", "")).strip()
    if pid:
        seen.add(pid)

    # From projects_seen[] list field
    ps = fields.get("projects_seen")
    if isinstance(ps, list):
        for p in ps:
            s = str(p).strip()
            if s:
                seen.add(s)

    # From filesystem: check all project instinct dirs for the same id
    proj_dir = CORTEX_DIR / "projects"
    if proj_dir.is_dir():
        for proj in proj_dir.iterdir():
            inst_dir = proj / "instincts"
            if inst_dir.is_dir():
                candidate = inst_dir / f"{iid}.yaml"
                if candidate.exists():
                    seen.add(proj.name)

    return len(seen)


def _active_law_count() -> int:
    """Count active (non-archived) law .txt files."""
    if not LAWS_DIR.is_dir():
        return 0
    count = 0
    for f in LAWS_DIR.glob("*.txt"):
        if "archive" not in str(f):
            count += 1
    return count


# ── v3.32.0 §4.5 — laws cap deprecation policy ──────────────────────────

def _law_age_days(law_path: Path, today: _dt.date | None = None) -> int:
    """Return integer days since the law file's mtime. Laws don't have
    frontmatter (they're one-line .txt), so mtime IS the canonical
    "last_seen" — set the day the law was promoted or rewritten."""
    if today is None:
        today = _dt.date.today()
    try:
        mtime = _dt.date.fromtimestamp(law_path.stat().st_mtime)
    except OSError:
        return 0
    return max(0, (today - mtime).days)


def _find_least_impactful_law(
    impact_per_iid: dict,
    today: _dt.date | None = None,
) -> str | None:
    """Find the law most suitable for deprecation when the cap is saturated.

    Heuristic: lowest `useful_14d / (1 + noise_14d)` ratio. Tie-break by
    oldest mtime (more days idle wins). Laws younger than
    LAW_DEPRECATE_MIN_AGE_DAYS are NOT candidates (AD P1-3 absorbed):
    without the age guard a freshly-promoted law without accumulated
    impact data would have ratio=0 and be marked for immediate
    deprecation before getting a chance to be exercised.

    Returns law_id (filename stem) when a viable candidate exists, or
    None when:
      - LAWS_DIR is missing or empty
      - every law is younger than LAW_DEPRECATE_MIN_AGE_DAYS
      - the best candidate's ratio is already > 1.0 (productive cohort,
        don't deprecate the least-bad of a healthy set)"""
    if today is None:
        today = _dt.date.today()
    if not LAWS_DIR.is_dir():
        return None
    candidates: list[tuple[float, int, str]] = []  # (ratio, age_days_neg, iid)
    for law_path in LAWS_DIR.glob("*.txt"):
        if "archive" in str(law_path):
            continue
        iid = law_path.stem
        age = _law_age_days(law_path, today)
        if age < LAW_DEPRECATE_MIN_AGE_DAYS:
            continue
        bucket = impact_per_iid.get(iid, {"useful": 0, "noise": 0})
        useful = int(bucket.get("useful", 0) or 0)
        noise = int(bucket.get("noise", 0) or 0)
        ratio = useful / (1 + noise)
        # Negate age so larger age sorts first under ascending sort
        candidates.append((ratio, -age, iid))

    if not candidates:
        return None
    candidates.sort(key=lambda x: (x[0], x[1]))
    best_ratio, _, best_iid = candidates[0]
    if best_ratio > 1.0:
        return None  # all laws productive, don't deprecate
    return best_iid


def manual_swap_promote(
    new_iid: str,
    deprecate_iid: str,
    dry_run: bool = False,
    today: _dt.date | None = None,
) -> tuple[bool, str]:
    """Atomic swap: promote `new_iid` to a new law + archive `deprecate_iid`
    in one operation. Called from /cx-distill --swap <to_deprecate>
    <new_iid> --confirm. (AD P1-7 rollback absorbed.)

    Safety:
      - Pre-check: deprecate_iid exists in LAWS_DIR
      - Pre-check: new_iid is an instinct in the global cohort with
        conf >= LAW_THRESHOLD_CONF (mature enough to graduate)
      - Backup: copy the old law file to LAWS_DIR/archive/ BEFORE
        creating the new one (manifest preserved)
      - Atomic: tmp+rename via _atomic_write avoids half-written state
      - Rollback: if the new-law write fails, restore the old law from
        the archive copy so the cohort stays at the same count

    Returns (success, reason). Reason is human-readable, suitable for
    echo to the operator."""
    if today is None:
        today = _dt.date.today()

    deprecate_path = LAWS_DIR / f"{deprecate_iid}.txt"
    if not deprecate_path.exists() or "archive" in str(deprecate_path):
        return False, f"deprecate target not found: {deprecate_iid}.txt"

    # Locate the new instinct file (global cohort first; project cohort
    # secondarily) and confirm conf>=0.95.
    new_instinct_path = INSTINCTS_DIR / f"{new_iid}.yaml"
    instinct_fields = None
    if new_instinct_path.exists():
        result = _read_instinct(new_instinct_path)
        if result is not None:
            instinct_fields, _ = result
    if instinct_fields is None:
        proj_dir = CORTEX_DIR / "projects"
        if proj_dir.is_dir():
            for proj in proj_dir.iterdir():
                cand = proj / "instincts" / f"{new_iid}.yaml"
                if cand.exists():
                    result = _read_instinct(cand)
                    if result is not None:
                        instinct_fields, _ = result
                        new_instinct_path = cand
                        break
    if instinct_fields is None:
        return False, f"new instinct not found: {new_iid}.yaml"

    try:
        conf = float(instinct_fields.get("confidence", 0))
    except (TypeError, ValueError):
        return False, f"new instinct has invalid confidence: {new_iid}"
    if conf < LAW_THRESHOLD_CONF:
        return False, f"new instinct conf {conf:.2f} < {LAW_THRESHOLD_CONF:.2f}"

    if dry_run:
        return True, (
            f"dry-run: would archive {deprecate_iid} and promote "
            f"{new_iid} (conf={conf:.2f})"
        )

    archive_dir = LAWS_DIR / "archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
    archive_path = archive_dir / f"{deprecate_iid}.{ts}.txt"
    backup_content: str | None = None
    try:
        backup_content = deprecate_path.read_text(encoding="utf-8")
        _atomic_write(archive_path, backup_content)
    except OSError as e:
        return False, f"archive backup failed: {e}"

    # Remove the old law (we've got it in archive); write the new one.
    new_law_line = _derive_law_line(instinct_fields)
    new_law_path = LAWS_DIR / f"{new_iid}.txt"
    try:
        deprecate_path.unlink()
    except OSError as e:
        # archive exists but old still in place: no harm, just bail
        return False, f"unlink old law failed: {e}"

    try:
        _atomic_write(new_law_path, new_law_line + "\n")
    except OSError as e:
        # Rollback: restore the old law from archive content we kept in memory.
        try:
            _atomic_write(deprecate_path, backup_content or "")
        except OSError:
            pass
        return False, f"write new law failed (rolled back): {e}"

    _log_knowledge(
        "swap-promoted", new_iid,
        f"archived={deprecate_iid} archive_file={archive_path.name}",
        source="cx-distill-swap",
    )
    return True, (
        f"swapped: {deprecate_iid} → archive/{archive_path.name}; "
        f"{new_iid} promoted (conf={conf:.2f})"
    )


def _law_content_for_jaccard(law_path: Path) -> str:
    """Read first line of a law file for Jaccard comparison."""
    try:
        return law_path.read_text(encoding="utf-8").split("\n")[0].strip()
    except OSError:
        return ""


def _derive_law_line(fields: dict) -> str:
    """Derive a ≤120-char one-liner for the law file from the instinct."""
    action = str(fields.get("action", "")).strip()
    trigger = str(fields.get("trigger", "")).strip()

    # If action already starts with imperative style, use as-is
    if re.match(r'^(Always|Never|Use|Avoid|When|If|Do|Don\'t|Run|Check|Set|Add|Call|Write)', action, re.IGNORECASE):
        line = action
    else:
        # Build "When <trigger>, <action>"
        if trigger:
            # Truncate trigger if long
            short_trigger = trigger[:40] if len(trigger) > 40 else trigger
            line = f"When {short_trigger}, {action}"
        else:
            line = action

    if len(line) > LAW_MAX_CHARS:
        line = line[: LAW_MAX_CHARS - 1] + "…"
    return line


def _load_instinct_tracking() -> dict:
    """Load instinct-tracking.json. Returns {} on missing/invalid.

    v3.29.0 §4.16: written by injector-engine.js on every PreToolUse match.
    Schema (per id key):
      {
        "count": int,
        "sessions": ["<uuid>", ...],   # deduped, capped at 20 entries
        "projects_seen": ["<phash>", ...],
        "first_seen": "<iso>",
        "last_seen": "<iso>",
      }
    """
    if not INSTINCT_TRACKING_FILE.exists():
        return {}
    try:
        raw = INSTINCT_TRACKING_FILE.read_text(encoding="utf-8")
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
        return {}
    except (OSError, json.JSONDecodeError):
        return {}


def _count_distinct_sessions(iid: str, tracking_data: dict) -> int:
    """Read the deduplicated count of distinct session UUIDs for an instinct.

    Defensive: handles missing file/key, malformed schema, missing 'sessions'
    field, duplicates, empty/None values. Returns 0 on any anomaly so the
    caller can decide policy (gate vs. grandfather).

    v3.29.0 §4.16 — source pattern: Sinapsis core/_instinct-activator.sh:43-63.
    """
    if not isinstance(tracking_data, dict):
        return 0
    entry = tracking_data.get(iid)
    if not isinstance(entry, dict):
        return 0
    sessions = entry.get("sessions")
    if not isinstance(sessions, list):
        return 0
    unique = {s for s in sessions if isinstance(s, str) and s.strip()}
    return len(unique)


def auto_promote_to_law(
    dry_run: bool = False,
) -> tuple[list[dict], list[dict]]:
    """Check all instincts against strict 7-criteria law promotion gate.

    Returns (promoted, candidates) where:
      promoted   = instincts that now have a law file
      candidates = instincts that almost qualify (for surfacing to user)
    """
    today = _dt.datetime.now(_dt.timezone.utc).date()
    impact = _impact_per_iid(days=14)
    active_laws = _active_law_count()
    # v3.29.0 §4.16: load instinct-tracking.json ONCE for the whole pass.
    tracking_data = _load_instinct_tracking()
    promoted: list[dict] = []
    candidates: list[dict] = []

    # Pre-load existing law content for Jaccard check
    existing_laws: list[tuple[str, str]] = []  # [(law_id, content)]
    if LAWS_DIR.is_dir():
        for lf in LAWS_DIR.glob("*.txt"):
            if "archive" not in str(lf):
                content = _law_content_for_jaccard(lf)
                if content:
                    existing_laws.append((lf.stem, content))

    for path in _all_instinct_paths():
        result = _read_instinct(path)
        if result is None:
            continue
        fields, text = result
        iid = str(fields.get("id", ""))
        if not iid:
            continue

        conf = fields.get("confidence")
        try:
            conf = float(conf)
        except (TypeError, ValueError):
            continue

        failed_reasons: list[str] = []

        # ── Criteria 1: confidence ≥ 0.95 ────────────────────────────────
        if conf < LAW_THRESHOLD_CONF:
            # Not even a candidate — don't clutter the list
            # But do update/clear the at_law_threshold_since field
            existing_field = fields.get("at_law_threshold_since")
            if existing_field and not dry_run:
                new_text = _remove_frontmatter_field(text, "at_law_threshold_since")
                _atomic_write(path, new_text)
            continue

        # conf ≥ 0.95 — manage at_law_threshold_since
        threshold_since_str = str(fields.get("at_law_threshold_since", "")).strip()
        threshold_since: _dt.date | None = None
        if threshold_since_str:
            try:
                threshold_since = _dt.date.fromisoformat(threshold_since_str)
            except ValueError:
                threshold_since = None

        if threshold_since is None:
            # Set the field for the first time
            if not dry_run:
                new_text = _set_frontmatter_field(text, "at_law_threshold_since", today.isoformat())
                _atomic_write(path, new_text)
            failed_reasons.append("sustained < 14d (just set threshold_since today)")
        else:
            days_at_threshold = (today - threshold_since).days
            if days_at_threshold < LAW_SUSTAINED_DAYS:
                failed_reasons.append(f"sustained < 14d ({days_at_threshold}d so far)")

        # ── Criteria 2b (v3.29.0 §4.16): ≥ 3 distinct sessions ────────────
        # Grandfather clause: if an instinct already has conf >= 0.95 AND
        # no meaningful tracking yet, treat it as if it had 3 distinct
        # sessions so pre-existing high-confidence instincts (from before
        # v3.29.0 shipped this gate) are not retroactively blocked.
        # v3.31.2 §4.1.A — narrow per AD P1-1: grandfather ONLY when
        # (entry absent) OR (sessions == [] explicit). NOT when sessions
        # is null / missing key / wrong type — those signal tracking
        # corruption and must keep blocking so the operator notices.
        distinct_sessions = _count_distinct_sessions(iid, tracking_data)
        entry = tracking_data.get(iid)
        has_tracking_entry = isinstance(entry, dict)
        no_meaningful_tracking = (
            not has_tracking_entry  # case 1: no entry at all (pre-v3.29 corpus)
            or (isinstance(entry, dict) and entry.get("sessions") == [])
            # case 2: entry exists with explicit empty list
        )
        if no_meaningful_tracking and conf >= LAW_THRESHOLD_CONF:
            distinct_sessions = LAW_MIN_DISTINCT_SESSIONS  # grandfathered
        if distinct_sessions < LAW_MIN_DISTINCT_SESSIONS:
            need = LAW_MIN_DISTINCT_SESSIONS - distinct_sessions
            failed_reasons.append(
                f"sessions {distinct_sessions}/{LAW_MIN_DISTINCT_SESSIONS} (need {need} more)"
            )

        # ── Criteria 3: ≥ LAW_MIN_PROJECTS distinct projects ─────────────
        # v3.29.4: use the constant (lowered to 1 in v3.24.0) instead of
        # the stale literal "3" so /cx-distill audit output matches the
        # gate actually applied.
        proj_count = _count_distinct_projects(fields, iid)
        if proj_count < LAW_MIN_PROJECTS:
            failed_reasons.append(f"projects < {LAW_MIN_PROJECTS} ({proj_count} seen)")

        # ── Criteria 4 & 5: impact events ────────────────────────────────
        iid_impact = impact.get(iid, {"useful": 0, "noise": 0})
        if iid_impact["noise"] > LAW_MAX_NOISE_14D:
            failed_reasons.append(f"noise > 0 ({iid_impact['noise']} in 14d)")
        if iid_impact["useful"] < LAW_MIN_USEFUL_14D:
            failed_reasons.append(f"useful < 5 ({iid_impact['useful']} in 14d)")

        # ── Criteria 6: no existing law + Jaccard < 0.50 ─────────────────
        law_path = LAWS_DIR / f"{iid}.txt"
        if law_path.exists() and "archive" not in str(law_path):
            failed_reasons.append(f"law already exists ({iid}.txt)")
        else:
            # Jaccard check against all existing laws
            candidate_content = _derive_law_line(fields)
            for law_id, law_content in existing_laws:
                sim = _jaccard(candidate_content, law_content)
                if sim >= LAW_JACCARD_THRESHOLD:
                    failed_reasons.append(f"duplicate of {law_id} (Jaccard {sim:.2f})")
                    break

        # ── Criteria 7: active law count < LAW_MAX_ACTIVE ────────────────
        # v3.32.0 §4.5: when saturated, propose a deprecation candidate
        # (lowest useful/(1+noise) ratio, age >= 7d) so the operator
        # knows which law to retire via /cx-distill --swap. Engine never
        # auto-swaps — only the operator confirms.
        if active_laws >= LAW_MAX_ACTIVE:
            candidate = _find_least_impactful_law(impact)
            if candidate:
                failed_reasons.append(
                    f"laws == {active_laws}/{LAW_MAX_ACTIVE} saturated; "
                    f"would deprecate {candidate} via "
                    f"/cx-distill --swap {candidate} {iid} --confirm"
                )
            else:
                failed_reasons.append(
                    f"laws == {active_laws}/{LAW_MAX_ACTIVE} saturated; "
                    f"no deprecation candidate (all productive OR < "
                    f"{LAW_DEPRECATE_MIN_AGE_DAYS}d age)"
                )

        if failed_reasons:
            candidates.append({
                "id": iid,
                "confidence": round(conf, 4),
                "reasons": failed_reasons,
            })
            if not dry_run:
                _log_knowledge("candidate", iid, "; ".join(failed_reasons))
        else:
            # All 7 criteria pass — promote!
            law_line = _derive_law_line(fields)
            promoted.append({"id": iid, "confidence": round(conf, 4)})
            if not dry_run:
                LAWS_DIR.mkdir(parents=True, exist_ok=True)
                _atomic_write(law_path, law_line + "\n")
                active_laws += 1
                # Refresh existing laws list for subsequent iterations
                existing_laws.append((iid, law_line))
                _log_knowledge("promoted", iid, f"law written: {law_line[:80]}")

    return promoted, candidates


# ── 4. Auto-validate proposals ───────────────────────────────────────────────

import hashlib as _hashlib


def _load_proposals() -> list[dict]:
    """Load proposals.json. Returns [] on missing/invalid."""
    if not PROPOSALS_FILE.exists():
        return []
    try:
        raw = PROPOSALS_FILE.read_text(encoding="utf-8")
        data = json.loads(raw)
        if isinstance(data, list):
            return data
        return []
    except (OSError, json.JSONDecodeError):
        return []


def _save_proposals(proposals: list[dict]) -> None:
    """Atomically write proposals.json."""
    content = json.dumps(proposals, indent=2, ensure_ascii=False) + "\n"
    _atomic_write(PROPOSALS_FILE, content)


def _instinct_exists(iid: str) -> bool:
    """Return True if an instinct YAML with this id already exists (global or project)."""
    global_path = CORTEX_DIR / "instincts" / "global" / f"{iid}.yaml"
    if global_path.exists():
        return True
    proj_dir = CORTEX_DIR / "projects"
    if proj_dir.is_dir():
        for proj in proj_dir.iterdir():
            candidate = proj / "instincts" / f"{iid}.yaml"
            if candidate.exists():
                return True
    return False


def _yaml_single_quote(s: str) -> str:
    """Escape a value for YAML single-quoted form: double internal apostrophes.

    Per YAML 1.2 §7.3.2, `''` is the only escape inside single-quoted strings.
    Without this, a value like `git push --force-with-lease --no-verify`'s
    apostrophe would close the YAML string and produce invalid frontmatter,
    making the resulting instinct invisible to the runtime parser.
    """
    if s is None:
        return ""
    return str(s).replace("'", "''")


def _proposal_to_instinct_yaml(proposal: dict, today: str) -> str:
    """Generate instinct YAML content from a proposal dict.

    v3.24.0: every regex-bearing or free-text field is now properly
    single-quote-escaped via `_yaml_single_quote`. Pre-v3.24.0 a single
    apostrophe in trigger/action/evidence broke the YAML frontmatter and
    silently produced an invisible instinct (parsed as None by yaml-utils).
    """
    iid = proposal.get("id", "")
    trigger = proposal.get("trigger", "")
    action = proposal.get("action", "")
    conf = float(proposal.get("confidence", 0.50))
    domain = proposal.get("domain", "gotcha")
    scope = proposal.get("scope", "global")
    project_id = proposal.get("project_id", "global")
    project_name = proposal.get("project_name", "cross-project")
    tags = proposal.get("tags", [])
    source = proposal.get("source", "cx-auto-validate")

    # Infer type from domain
    domain_type_map = {
        "gotcha": "gotcha",
        "pattern": "pattern",
        "error-recovery": "gotcha",
        "agent-evolution": "agent",
    }
    inst_type = domain_type_map.get(domain, "pattern")

    tags_yaml = "\n".join(f"  - {_yaml_single_quote(t)}" for t in tags) if tags else "  []"
    if not tags:
        tags_yaml = "[]"

    evidence_line = f"  - '{_yaml_single_quote(today)}: Auto-validated from proposal at conf {conf:.2f}'"

    lines = [
        "---",
        f"id: {iid}",
        f"trigger: '{_yaml_single_quote(trigger)}'",
        f"action: '{_yaml_single_quote(action)}'",
        f"confidence: {conf:.4f}",
        f"domain: {domain}",
        f"type: {inst_type}",
        f"source: cx-auto-validate",
        f"scope: {scope}",
        f"project_id: '{_yaml_single_quote(project_id)}'",
        f"project_name: '{_yaml_single_quote(project_name)}'",
        f"tags: {tags_yaml}",
        f"created: '{_yaml_single_quote(today)}'",
        f"first_seen: '{_yaml_single_quote(today)}'",
        f"last_seen: '{_yaml_single_quote(today)}'",
        f"occurrences: 1",
        f"evidence:",
        f"{evidence_line}",
        "---",
        "",
    ]
    return "\n".join(lines)


def _detect_unauthorized_rejections(proposals: list[dict]) -> int:
    """v3.29.0 (Sprint 8 §4.7): restore proposals rejected by unknown sources.

    On 2026-05-05 an unidentified `cx-validate-auto` script bulk-rejected 648
    proposals — git archaeology found no trace (see
    `docs/GHOST-CX-VALIDATE-AUTO.md`). This guard is the preventive mitigation:
    every time `auto_validate_proposals` runs it scans the existing proposals
    file and, if it finds a rejection by an identity NOT in
    `VALIDATE_AUTHORIZED_REJECTERS`, it strips the rejection metadata and
    returns the proposal to `pending` status. The next legitimate validate
    pass will then evaluate the proposal on its merits.

    Mutates `proposals` in-place. Returns the number of restorations.
    """
    restored = 0
    for p in proposals:
        if not isinstance(p, dict):
            continue
        if p.get("status") != "rejected":
            continue
        rejected_by = p.get("rejected_by")
        if rejected_by in VALIDATE_AUTHORIZED_REJECTERS:
            continue
        iid = p.get("id", "<no-id>")
        try:
            _log_knowledge(
                "ghost-restore",
                str(iid),
                f"unauthorized rejecter={rejected_by!r}",
                source="cx-auto-validate",
            )
        except Exception:
            pass
        p["status"] = "pending"
        p.pop("rejected_by", None)
        p.pop("rejected_reason", None)
        p.pop("rejected_at", None)
        restored += 1
    return restored


# v3.31.2 §4.1.B — auto-validate skip-reason instrumentation (no behavior change).

_SKIP_REASON_BUCKETED_PREFIXES = frozenset({
    "orphan-domain",
    "unsafe-trigger",
    "validate_instinct",
})

_AUTO_VALIDATE_SKIPS_LOG_MAX_BYTES = 512 * 1024  # 512KB, mirror of session-learner.js


def _normalize_skip_reason(reason: str) -> str:
    """Bucket high-cardinality `<prefix>:<variable>` reasons by their
    prefix so the breakdown stays readable instead of exploding into
    one bucket per <variable>. Low-cardinality reasons pass through
    unchanged (low-confidence, already-instinct, needs-human-judgment)."""
    if not isinstance(reason, str) or not reason:
        return "unknown"
    head = reason.split(":", 1)[0]
    if head in _SKIP_REASON_BUCKETED_PREFIXES:
        return head
    return reason


def _summarize_skip_reasons(skipped: list[dict]) -> dict[str, int]:
    counter: Counter = Counter()
    for entry in skipped:
        if isinstance(entry, dict):
            reason = entry.get("reason", "unknown")
        else:
            reason = "unknown"
        counter[_normalize_skip_reason(reason)] += 1
    return dict(counter)


def _append_skip_breakdown_log(
    *,
    total: int,
    accepted_count: int,
    skipped_count: int,
    breakdown: dict[str, int],
) -> None:
    """Append one JSONL line to ~/.claude/cortex/log/auto-validate-skips.jsonl.

    Rotates to `.1` when size > 512KB (mirror of session-learner.log rotation
    at hooks/session-learner.js:60-76). Best-effort: any I/O error is
    swallowed — logging must never break auto-validate."""
    log_dir = CORTEX_DIR / "log"
    log_path = log_dir / "auto-validate-skips.jsonl"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        if log_path.exists() and log_path.stat().st_size > _AUTO_VALIDATE_SKIPS_LOG_MAX_BYTES:
            rotated = log_path.with_suffix(log_path.suffix + ".1")
            try:
                if rotated.exists():
                    rotated.unlink()
            except OSError:
                pass
            try:
                log_path.rename(rotated)
            except OSError:
                pass
        record = {
            "ts": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "total": total,
            "accepted": accepted_count,
            "skipped": skipped_count,
            "skip_breakdown": breakdown,
        }
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


# ── v3.32.0 §4.4 — promotion gate HUMAN → AUTO ──────────────────────────

def _log_security_event(event_type: str, detail: str) -> None:
    """Append a security-flavored event to a rotated JSONL so the operator
    can audit fail-closed paths (invalid markers, schema drift, injection
    attempts). Best-effort: any I/O error is swallowed."""
    try:
        SECURITY_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        # Reuse the same 512KB rotation policy as the skip-breakdown log.
        if (
            SECURITY_LOG_FILE.exists()
            and SECURITY_LOG_FILE.stat().st_size > _AUTO_VALIDATE_SKIPS_LOG_MAX_BYTES
        ):
            rotated = SECURITY_LOG_FILE.with_suffix(SECURITY_LOG_FILE.suffix + ".1")
            try:
                if rotated.exists():
                    rotated.unlink()
            except OSError:
                pass
            try:
                SECURITY_LOG_FILE.rename(rotated)
            except OSError:
                pass
        record = {
            "ts": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "event": str(event_type)[:120],
            "detail": str(detail)[:500],
        }
        with open(SECURITY_LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def _load_proposals_history() -> list[dict]:
    """Read proposals-history.jsonl line-by-line. Skips unparseable lines
    without raising so partial corruption does not block the gate.

    Returns: list[dict] of all entries. Empty list when the file does
    not exist OR every line fails to parse. Caller treats empty as
    "no history" (gate returns reviewed=0)."""
    history: list[dict] = []
    if not PROPOSALS_HISTORY_FILE.exists():
        return history
    try:
        with open(PROPOSALS_HISTORY_FILE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    history.append(obj)
    except OSError:
        return []
    return history


def _count_critical_rejections(reviewed: list[dict]) -> int:
    """Count rejections marked critical (security / breaking / injection).

    Two-pass: (a) explicit `rejection_category` enum first; (b) fallback
    keyword heuristic over `rejected_reason` (ES + EN) when the enum is
    absent — covers legacy rejects from before v3.32.0 added the field.
    AD P1-6 absorbed."""
    n = 0
    for entry in reviewed:
        if not isinstance(entry, dict):
            continue
        if entry.get("status") != "rejected":
            continue
        category = entry.get("rejection_category")
        if isinstance(category, str) and category in CRITICAL_REJECTION_CATEGORIES:
            n += 1
            continue
        if category is None:
            reason = entry.get("rejected_reason") or ""
            if isinstance(reason, str):
                low = reason.lower()
                if any(kw in low for kw in CRITICAL_REJECTION_KEYWORDS_FALLBACK):
                    n += 1
    return n


def can_promote_to_auto(detector_source: str) -> tuple[bool, str, dict]:
    """Check HUMAN → AUTO promotion eligibility for one detector source.

    Returns (eligible, reason, stats). `eligible` is True ONLY when ALL
    four gates pass at the AUTO threshold (n ≥ 20). Between 10 and 20
    returns (False, 'visible-only', stats) so /cx-status can surface
    progress without enabling promotion (AD P1-2)."""
    if not isinstance(detector_source, str) or not detector_source:
        return False, "invalid-source", {
            "reviewed_count": 0, "accept_count": 0,
            "distinct_sessions": 0, "critical_count": 0,
        }

    history = _load_proposals_history()
    reviewed = [
        p for p in history
        if isinstance(p, dict)
        and p.get("source") == detector_source
        and p.get("status") in ("accepted", "rejected")
    ]
    accept_count = sum(1 for p in reviewed if p.get("status") == "accepted")
    distinct_sessions = len({
        p.get("session_id", "") for p in reviewed if p.get("session_id")
    })
    critical_count = _count_critical_rejections(reviewed)

    stats = {
        "reviewed_count": len(reviewed),
        "accept_count": accept_count,
        "distinct_sessions": distinct_sessions,
        "critical_count": critical_count,
    }

    n = stats["reviewed_count"]
    if n < PROMOTE_REVIEW_THRESHOLD:
        return False, f"reviewed {n}/{PROMOTE_REVIEW_THRESHOLD} (need review tier)", stats
    if n < PROMOTE_AUTO_THRESHOLD:
        return False, f"visible-only ({n}/{PROMOTE_AUTO_THRESHOLD})", stats

    accept_rate = accept_count / n
    if accept_rate < PROMOTE_ACCEPT_RATE:
        return False, f"accept_rate {accept_rate:.2f} < {PROMOTE_ACCEPT_RATE:.2f}", stats
    if distinct_sessions < PROMOTE_MIN_SESSIONS:
        return False, f"distinct_sessions {distinct_sessions} < {PROMOTE_MIN_SESSIONS}", stats
    if critical_count > 0:
        return False, f"critical_rejections {critical_count} > 0", stats
    return True, "all-gates-pass", stats


def _load_promoted_detectors() -> set[str]:
    """Read .promoted-detectors.json. Fail-closed: any parse/schema error
    returns empty set so HUMAN-gated domains stay HUMAN (AD P0-4).

    NEVER silently treats invalid markers as authorization."""
    if not PROMOTED_DETECTORS_FILE.exists():
        return set()
    try:
        data = json.loads(PROMOTED_DETECTORS_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        _log_security_event("promoted-detectors:read-error", str(e))
        return set()
    if not isinstance(data, dict) or data.get("version") != 1:
        _log_security_event("promoted-detectors:invalid-schema",
                            f"version={data.get('version') if isinstance(data, dict) else 'not-a-dict'}")
        return set()
    promoted = data.get("promoted", [])
    if not isinstance(promoted, list):
        _log_security_event("promoted-detectors:invalid-promoted", str(type(promoted)))
        return set()
    result: set[str] = set()
    src_re = re.compile(r"^[a-z][a-z0-9:_-]{2,80}$")
    for entry in promoted:
        if not isinstance(entry, dict):
            continue
        src = entry.get("source", "")
        if not isinstance(src, str) or not src_re.match(src):
            _log_security_event("promoted-detectors:invalid-source", str(src)[:120])
            continue
        since = entry.get("since", "")
        if not isinstance(since, str):
            _log_security_event("promoted-detectors:invalid-since", src)
            continue
        try:
            _dt.datetime.fromisoformat(since.replace("Z", "+00:00"))
        except (ValueError, TypeError):
            _log_security_event("promoted-detectors:invalid-since", src)
            continue
        result.add(src)
    return result


def manual_promote_detector(
    source: str, confirm: bool = False,
) -> tuple[bool, str, dict]:
    """ÚNICO writer for `.promoted-detectors.json`. Called from
    /cx-promote --auto <source> --confirm — never by the engine, never by
    auto_validate, never by auto_promote_to_law.

    Returns (success, reason, stats_snapshot)."""
    if not confirm:
        return False, "missing --confirm", {}
    eligible, reason, stats = can_promote_to_auto(source)
    if not eligible:
        return False, f"gate-blocked: {reason}", stats

    # Read-modify-write with merge so multiple promotions accumulate.
    existing = {"version": 1, "promoted": []}
    if PROMOTED_DETECTORS_FILE.exists():
        try:
            existing = json.loads(PROMOTED_DETECTORS_FILE.read_text(encoding="utf-8"))
            if not isinstance(existing, dict) or existing.get("version") != 1:
                # Corrupted/schema-drift marker: archive + start fresh so the
                # operator-approved new source isn't lost behind invalid data.
                _log_security_event(
                    "promoted-detectors:marker-rewritten-from-invalid",
                    f"prev-version={existing.get('version') if isinstance(existing, dict) else 'not-dict'}",
                )
                existing = {"version": 1, "promoted": []}
            if not isinstance(existing.get("promoted"), list):
                existing["promoted"] = []
        except (OSError, json.JSONDecodeError) as e:
            _log_security_event("promoted-detectors:marker-rewritten-after-parse-fail", str(e))
            existing = {"version": 1, "promoted": []}

    # Idempotent: skip if already promoted.
    if any(
        isinstance(p, dict) and p.get("source") == source
        for p in existing.get("promoted", [])
    ):
        return True, "already-promoted", stats

    now_iso = _dt.datetime.now(_dt.timezone.utc).isoformat()
    entry = {
        "source": source,
        "since": now_iso,
        "approved_by": "operator",
        "gate_snapshot": {
            "reviewed_count": stats["reviewed_count"],
            "accept_count": stats["accept_count"],
            "accept_rate": round(stats["accept_count"] / max(stats["reviewed_count"], 1), 3),
            "distinct_sessions": stats["distinct_sessions"],
        },
    }
    existing["promoted"].append(entry)
    try:
        PROMOTED_DETECTORS_FILE.parent.mkdir(parents=True, exist_ok=True)
        _atomic_write(PROMOTED_DETECTORS_FILE, json.dumps(existing, ensure_ascii=False, indent=2) + "\n")
    except OSError as e:
        _log_security_event("promoted-detectors:write-error", str(e))
        return False, f"write-error: {e}", stats

    _log_knowledge("promoted-detector", source, f"reviewed={stats['reviewed_count']} "
                    f"accept_rate={stats['accept_count']}/{stats['reviewed_count']}",
                   source="cx-promote")
    return True, "promoted", stats


def auto_validate_proposals(dry_run: bool = False) -> dict:
    """Auto-accept proposals that match whitelist criteria.

    Returns: {"accepted": [{id, conf, domain}], "skipped": [{id, reason}],
              "errors": [], "ghost_restored": int, "skip_breakdown": dict}

    v3.31.2 §4.1.B: emit a `skip_breakdown` summary (Counter of normalized
    skip reasons) in the return dict and append a JSONL row to
    ~/.claude/cortex/log/auto-validate-skips.jsonl (rotated at 512KB) so
    the operator can investigate why AUTO pending proposals stay pending.
    Instrumentation only — no behavior change."""
    today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
    proposals = _load_proposals()

    # v3.29.0 (Sprint 8 §4.7): pre-pass to undo unauthorized rejections before
    # we evaluate anything. Run on the mutable working list so the rest of
    # auto-validate sees the restored 'pending' status this same pass.
    ghost_restored = 0
    if proposals:
        ghost_restored = _detect_unauthorized_rejections(proposals)

    accepted: list[dict] = []
    skipped: list[dict] = []
    errors: list[str] = []

    updated_proposals = list(proposals)  # copy for mutation

    # v3.32.0 §4.4.e — load operator-promoted detectors ONCE. Fail-closed:
    # invalid marker → empty set, every HUMAN-domain proposal stays human.
    promoted_sources = _load_promoted_detectors()

    for i, proposal in enumerate(proposals):
        iid = proposal.get("id", "")
        status = proposal.get("status", "pending")
        conf_raw = proposal.get("confidence", 0.0)
        domain = proposal.get("domain", "")
        source = str(proposal.get("source", ""))

        if status != "pending":
            continue

        try:
            conf = float(conf_raw)
        except (TypeError, ValueError):
            errors.append(f"{iid}: invalid confidence value '{conf_raw}'")
            continue

        # Check skip conditions first (mutually exclusive ordering).
        # v3.32.0 §4.4.e: HUMAN-domain proposal whose `source` is in the
        # operator-approved marker falls through to AUTO path; otherwise
        # the legacy `needs-human-judgment` skip applies.
        if domain in VALIDATE_HUMAN_DOMAINS and source not in promoted_sources:
            skipped.append({"id": iid, "reason": "needs-human-judgment"})
            continue

        if conf < VALIDATE_MIN_CONF:
            skipped.append({"id": iid, "reason": "low-confidence"})
            continue

        if _instinct_exists(iid):
            skipped.append({"id": iid, "reason": "already-instinct"})
            continue

        # v3.29.5 §F1 — Orphan-domain auto-hold. Pre-v3.29.5 a proposal whose
        # domain was neither in VALIDATE_HUMAN_DOMAINS nor VALIDATE_AUTO_DOMAINS
        # was skipped with `needs-human-judgment` but its status stayed
        # `pending` — invisible to /cx-validate (which only surfaces `held`)
        # and never processable. Now we HELD it explicitly with an
        # `orphan-domain:<name>` label so the operator sees the gap.
        if domain not in KNOWN_DOMAINS:
            hold_label = f"orphan-domain:{domain or '<empty>'}"
            skipped.append({"id": iid, "reason": hold_label})
            if not dry_run:
                updated_proposals[i] = dict(proposal)
                updated_proposals[i]["status"] = "held"
                updated_proposals[i]["hold_reason"] = hold_label
                updated_proposals[i]["held_by"] = "cx-auto-validate"
                updated_proposals[i]["held_at"] = today
                _log_knowledge("held", iid, f"reason={hold_label}", source="cx-auto-validate")
            continue

        if domain not in VALIDATE_AUTO_DOMAINS:
            skipped.append({"id": iid, "reason": "needs-human-judgment"})
            continue

        # v3.23.4: validate trigger regex BEFORE creating an instinct that would
        # be silently filtered by the runtime guard. A proposal with an unsafe
        # trigger is HELD (persisted to proposals.json with status=held) so the
        # operator can review and reshape it via /cx-validate. We never want
        # auto-validate to silently drop a proposal.
        trigger_value = str(proposal.get("trigger", "")).strip()
        guard_reason = _guard_unsafe_reason(trigger_value) if trigger_value else "empty"
        if guard_reason:
            hold_label = f"unsafe-trigger:{guard_reason}"
            skipped.append({"id": iid, "reason": hold_label})
            if not dry_run:
                updated_proposals[i] = dict(proposal)
                updated_proposals[i]["status"] = "held"
                updated_proposals[i]["hold_reason"] = hold_label
                updated_proposals[i]["held_by"] = "cx-auto-validate"
                updated_proposals[i]["held_at"] = today
                _log_knowledge("held", iid, f"reason={hold_label}", source="cx-auto-validate")
            continue

        # Accept: write instinct YAML
        scope = proposal.get("scope", "global")
        project_id = proposal.get("project_id", "global")

        if scope == "global" or not project_id or project_id == "global":
            dest_path = CORTEX_DIR / "instincts" / "global" / f"{iid}.yaml"
        else:
            dest_path = CORTEX_DIR / "projects" / project_id / "instincts" / f"{iid}.yaml"

        if not dry_run:
            yaml_content = _proposal_to_instinct_yaml(proposal, today)

            # v3.29.5 §F2 — Validate against BLOCKED_PATTERNS (prompt-injection)
            # + length BEFORE writing the instinct. Pre-v3.29.5 the validation
            # only ran as a CLI tool over already-written files; the auto-create
            # path skipped it entirely. A proposal with "you are now…" in the
            # action could become an active instinct without barrier.
            yaml_ok, yaml_reason = _validate_yaml_content(yaml_content)
            if not yaml_ok:
                reject_label = f"validate_instinct:{yaml_reason}"
                skipped.append({"id": iid, "reason": reject_label})
                updated_proposals[i] = dict(proposal)
                updated_proposals[i]["status"] = "rejected"
                updated_proposals[i]["rejected_by"] = "cx-auto-validate"
                updated_proposals[i]["rejected_at"] = today
                updated_proposals[i]["rejected_reason"] = reject_label
                _log_knowledge("rejected", iid, f"reason={reject_label}", source="cx-auto-validate")
                continue

            _atomic_write(dest_path, yaml_content)

            # Update proposal status
            updated_proposals[i] = dict(proposal)
            updated_proposals[i]["status"] = "accepted"
            updated_proposals[i]["accepted_by"] = "cx-auto-validate"
            updated_proposals[i]["accepted_at"] = today

            _log_knowledge("accepted", iid, f"conf={conf:.2f}", source="cx-auto-validate")

        accepted.append({"id": iid, "conf": conf, "domain": domain})

    has_holds = any(
        isinstance(p, dict) and p.get("status") == "held" and p.get("held_by") == "cx-auto-validate"
        for p in updated_proposals
    )
    # v3.29.5 §F2 — persist also when we mutated proposals to `rejected` via
    # validate_instinct safety gate. Without this the rejection lived only in
    # memory and the proposal stayed `pending` on disk, re-evaluated every
    # run.
    has_auto_rejects = any(
        isinstance(p, dict) and p.get("status") == "rejected"
        and p.get("rejected_by") == "cx-auto-validate"
        for p in updated_proposals
    )
    # v3.29.0: also persist when the ghost-guard restored proposals to pending,
    # otherwise the rejection survives in the on-disk file across runs.
    if not dry_run and (accepted or has_holds or has_auto_rejects or ghost_restored):
        _save_proposals(updated_proposals)

    # v3.31.2 §4.1.B — instrumentation only. Aggregate skip reasons and
    # persist a single row per run so the operator can investigate why
    # AUTO pending proposals stay pending. Behavior of accept/skip/hold
    # paths is unchanged.
    skip_breakdown = _summarize_skip_reasons(skipped)
    if not dry_run:
        _append_skip_breakdown_log(
            total=len(proposals),
            accepted_count=len(accepted),
            skipped_count=len(skipped),
            breakdown=skip_breakdown,
        )

    return {
        "accepted": accepted,
        "skipped": skipped,
        "errors": errors,
        "ghost_restored": ghost_restored,
        "skip_breakdown": skip_breakdown,
    }


# ── 5. Auto-evolve: cluster detection + draft generation ────────────────────

def _all_instinct_records() -> list[dict]:
    """Return list of {fields, path} for all active instincts."""
    records = []
    for path in _all_instinct_paths():
        result = _read_instinct(path)
        if result is None:
            continue
        fields, _ = result
        records.append({"fields": fields, "path": path})
    return records


def _cluster_id(domain: str, instinct_ids: list[str]) -> str:
    """Compute stable cluster id from sorted instinct ids."""
    sorted_ids = sorted(instinct_ids)
    hash8 = _hashlib.sha1("|".join(sorted_ids).encode()).hexdigest()[:8]
    return f"cluster-{domain}-{hash8}"


def _skill_exists_for_cluster(cluster_id: str, domain: str, instinct_ids: list[str]) -> bool:
    """Check if an existing skill covers this cluster."""
    # Check by exact cluster-id directory
    skill_path = SKILLS_DIR / cluster_id / "SKILL.md"
    if skill_path.exists():
        return True

    # Check evolved draft already exists with same content
    draft_path = EVOLVED_SKILLS_DIR / f"{cluster_id}.draft.md"
    if draft_path.exists():
        # Check if instinct set changed by reading source instinct ids from draft
        try:
            content = draft_path.read_text(encoding="utf-8")
            existing_ids: set[str] = set()
            for line in content.splitlines():
                # Lines like: "- <id> (conf: ...)"
                m = re.match(r"^- ([^\s(]+)", line.strip())
                if m:
                    existing_ids.add(m.group(1))
            if existing_ids == set(instinct_ids):
                return True  # Same set — idempotent, skip
        except OSError:
            pass

    return False


def _build_cluster_draft(cluster_id: str, domain: str, records: list[dict], today: str) -> str:
    """Build draft SKILL.md content for a cluster."""
    n = len(records)

    # Collect triggers and actions
    all_triggers: list[str] = []
    all_actions: list[str] = []
    source_lines: list[str] = []

    for r in records:
        f = r["fields"]
        iid = str(f.get("id", ""))
        conf = f.get("confidence", 0.0)
        last_seen = str(f.get("last_seen", "unknown"))
        trigger = str(f.get("trigger", "")).strip()
        action = str(f.get("action", "")).strip()

        if trigger:
            all_triggers.append(trigger)
        if action:
            all_actions.append(action)

        source_lines.append(f"- {iid} (conf: {conf}) — last seen {last_seen}")

    # Deduplicate triggers
    seen_triggers: set[str] = set()
    unique_triggers: list[str] = []
    for t in all_triggers:
        if t not in seen_triggers:
            seen_triggers.add(t)
            unique_triggers.append(t)

    triggers_section = "\n".join(unique_triggers) if unique_triggers else "(none)"
    actions_section = "\n".join(f"- {a}" for a in all_actions) if all_actions else "(none)"
    sources_section = "\n".join(source_lines)

    return f"""---
name: {cluster_id}
description: Auto-generated from {n} instincts in domain {domain}
status: DRAFT — review before installing
generated_at: {today}
---

# {cluster_id} (DRAFT)

Auto-generated cluster from {n} mature instincts (confidence >= {EVOLVE_MIN_CONF}).

## Source instincts

{sources_section}

## Combined triggers

{triggers_section}

## Combined actions

{actions_section}

## To install

cp ~/.claude/cortex/evolved/skills/{cluster_id}.draft.md ~/.claude/skills/{cluster_id}/SKILL.md

## To discard

rm ~/.claude/cortex/evolved/skills/{cluster_id}.draft.md
"""


def auto_evolve_detect(dry_run: bool = False) -> dict:
    """Detect clusters of 3+ mature instincts in same domain. Generate skill drafts.

    Returns: {"drafts_generated": [{cluster_id, instinct_count, draft_path}],
              "skipped": [{cluster_id, reason}]}
    """
    today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
    all_records = _all_instinct_records()

    # Filter to mature instincts
    mature: list[dict] = []
    for r in all_records:
        f = r["fields"]
        conf_raw = f.get("confidence")
        try:
            conf = float(conf_raw)
        except (TypeError, ValueError):
            continue
        if conf >= EVOLVE_MIN_CONF:
            mature.append(r)

    # Group by domain
    by_domain: dict[str, list[dict]] = {}
    for r in mature:
        domain = str(r["fields"].get("domain", "unknown"))
        by_domain.setdefault(domain, []).append(r)

    drafts_generated: list[dict] = []
    skipped: list[dict] = []

    for domain, records in by_domain.items():
        if len(records) < EVOLVE_CLUSTER_MIN:
            continue

        # Compute pairwise Jaccard on trigger + action tokens
        # Build text per record
        texts = []
        for r in records:
            f = r["fields"]
            combined = str(f.get("trigger", "")) + " " + str(f.get("action", ""))
            texts.append(combined)

        # Union-find style clustering via Jaccard
        n = len(records)
        # adjacency: i-j connected if Jaccard >= threshold
        adj: dict[int, set[int]] = {i: set() for i in range(n)}
        for i in range(n):
            for j in range(i + 1, n):
                sim = _jaccard(texts[i], texts[j])
                if sim >= EVOLVE_JACCARD_MIN:
                    adj[i].add(j)
                    adj[j].add(i)

        # BFS to find connected components
        visited: set[int] = set()
        clusters: list[list[int]] = []
        for start in range(n):
            if start in visited:
                continue
            component: list[int] = []
            queue = [start]
            while queue:
                node = queue.pop()
                if node in visited:
                    continue
                visited.add(node)
                component.append(node)
                queue.extend(adj[node] - visited)
            if len(component) >= EVOLVE_CLUSTER_MIN:
                clusters.append(component)

        for component in clusters:
            cluster_records = [records[i] for i in component]
            instinct_ids = [str(r["fields"].get("id", "")) for r in cluster_records]
            cid = _cluster_id(domain, instinct_ids)

            # Check if skill already exists
            if _skill_exists_for_cluster(cid, domain, instinct_ids):
                skipped.append({"cluster_id": cid, "reason": "skill-exists-or-draft-unchanged"})
                continue

            if not dry_run:
                draft_content = _build_cluster_draft(cid, domain, cluster_records, today)
                draft_path = EVOLVED_SKILLS_DIR / f"{cid}.draft.md"
                _atomic_write(draft_path, draft_content)
                _log_knowledge("evolve-draft", cid, f"{len(cluster_records)} instincts", source="cx-auto-evolve")

            drafts_generated.append({
                "cluster_id": cid,
                "instinct_count": len(cluster_records),
                "draft_path": str(EVOLVED_SKILLS_DIR / f"{cid}.draft.md"),
            })

    return {"drafts_generated": drafts_generated, "skipped": skipped}


# ── Candidates markdown file ──────────────────────────────────────────────────

def _write_candidates_file(candidates: list[dict]) -> None:
    """Write ~/.claude/cortex/auto-distill-candidates.md with promotion candidates."""
    if not candidates:
        # Truncate to empty so the maintenance reminder suppresses itself
        CANDIDATES_FILE.parent.mkdir(parents=True, exist_ok=True)
        CANDIDATES_FILE.write_text("", encoding="utf-8")
        return

    today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
    lines = [
        f"# Auto-distill candidates — {today}",
        "",
        "These instincts are almost ready for law promotion but did not meet all 7 criteria.",
        "Run `/cx-distill` to review and manually promote if appropriate.",
        "",
    ]
    for c in candidates:
        lines.append(f"## {c['id']} (conf={c['confidence']})")
        for r in c["reasons"]:
            lines.append(f"- {r}")
        lines.append("")

    CANDIDATES_FILE.parent.mkdir(parents=True, exist_ok=True)
    CANDIDATES_FILE.write_text("\n".join(lines), encoding="utf-8")


# ── Rate-limit marker ─────────────────────────────────────────────────────────

def _is_rate_limited() -> bool:
    """Return True if the last auto-distill ran < 24h ago."""
    if not MARKER_FILE.exists():
        return False
    try:
        age_seconds = time.time() - MARKER_FILE.stat().st_mtime
        return age_seconds < (RATE_LIMIT_HOURS * 3600)
    except OSError:
        return False


def _write_marker() -> None:
    MARKER_FILE.parent.mkdir(parents=True, exist_ok=True)
    MARKER_FILE.write_text(_dt.datetime.now(_dt.timezone.utc).isoformat(), encoding="utf-8")


def _prune_cross_day_tracker():
    """Prune entries older than 365 days from cross-day-tracker.jsonl."""
    tracker_path = CORTEX_DIR / "cross-day-tracker.jsonl"
    if not tracker_path.exists():
        return {"before": 0, "after": 0, "pruned": 0}

    cutoff = (_dt.datetime.now() - _dt.timedelta(days=365)).strftime("%Y-%m-%d")
    kept = []
    before = 0
    # v3.28.5 — also compact same-day same-pattern_id duplicates (parity with
    # Node prune in cross-day-tracker.js). Keeps the first occurrence per
    # (date, pattern_id) pair. Idempotent.
    seen = set()
    try:
        with open(tracker_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                before += 1
                try:
                    entry = json.loads(line)
                    if entry.get("date", "") < cutoff:
                        continue
                    key = f"{entry.get('date', '')}|{entry.get('pattern_id', '')}"
                    if key in seen:
                        continue
                    seen.add(key)
                    kept.append(line)
                except json.JSONDecodeError:
                    continue

        tmp = str(tracker_path) + f".tmp.{os.getpid()}"
        with open(tmp, "w") as f:
            f.write("\n".join(kept) + "\n" if kept else "")
        os.replace(tmp, str(tracker_path))
    except OSError:
        return {"before": before, "after": before, "pruned": 0}

    return {"before": before, "after": len(kept), "pruned": before - len(kept)}


# ── Main entry point ──────────────────────────────────────────────────────────

def run_auto_distill(dry_run: bool = False) -> dict:
    """Single entry point invoked from session-start hook.

    Returns a summary dict:
      {"decayed": int, "archived": int,
       "validated": int, "skipped_validate": int,
       "promoted": int, "candidates": int,
       "evolve_drafts": int,
       "skipped_reason": str | None, "ran_at": iso8601}

    Idempotent: rate-limited to once per 24 h via MARKER_FILE mtime.
    Pipeline order (inside the lock):
      1. apply_decay
      2. archive_decayed
      3. auto_validate_proposals  (emits new instincts before promote sees them)
      4. auto_promote_to_law      (sees newly-validated instincts)
      5. auto_evolve_detect
    """
    ran_at = _dt.datetime.now(_dt.timezone.utc).isoformat()

    # v3.29.0 (Sprint 8 §4.8) kill switch. CORTEX_AUTODISTILL_OFF=1 skips
    # the entire deterministic pipeline (decay, archive, auto-validate,
    # auto-promote-to-law, auto-evolve). Returns BEFORE any state mutation:
    # proposals.json, instinct YAMLs, law .txt files, evolved/ drafts, the
    # candidates markdown, cross-day-tracker prune, AND the .last-auto-distill
    # marker (so the next SessionStart with the kill switch removed runs the
    # pipeline normally instead of being rate-limited away).
    if os.environ.get("CORTEX_AUTODISTILL_OFF", "0") == "1":
        return {
            "decayed": 0, "archived": 0,
            "validated": 0, "skipped_validate": 0,
            "promoted": 0, "candidates": 0,
            "evolve_drafts": 0,
            "skipped_reason": "autodistill-off", "ran_at": ran_at,
        }

    # Rate-limit check
    if _is_rate_limited():
        return {
            "decayed": 0, "archived": 0,
            "validated": 0, "skipped_validate": 0,
            "promoted": 0, "candidates": 0,
            "evolve_drafts": 0,
            "skipped_reason": "rate-limited", "ran_at": ran_at,
        }

    # Concurrency lock (non-blocking)
    lock_fh, acquired = _lock_acquire(nonblocking=True)
    if not acquired:
        return {
            "decayed": 0, "archived": 0,
            "validated": 0, "skipped_validate": 0,
            "promoted": 0, "candidates": 0,
            "evolve_drafts": 0,
            "skipped_reason": "lock-busy", "ran_at": ran_at,
        }

    try:
        # 1. Decay
        decayed = apply_decay(dry_run=dry_run)
        # 2. Archive
        archived = archive_decayed(dry_run=dry_run)
        # 3. Auto-validate proposals (new instincts visible to step 4)
        validate_result = auto_validate_proposals(dry_run=dry_run)
        # 4. Promote to law (sees freshly-validated instincts)
        promoted, candidates = auto_promote_to_law(dry_run=dry_run)
        # 5. Evolve: cluster detection
        evolve_result = auto_evolve_detect(dry_run=dry_run)

        if not dry_run:
            _write_candidates_file(candidates)
            prune_result = _prune_cross_day_tracker()
            if prune_result["pruned"] > 0:
                print(f"Pruned {prune_result['pruned']} cross-day-tracker entries (>365d)")
            _write_marker()

        return {
            "decayed": len(decayed),
            "archived": len(archived),
            "validated": len(validate_result["accepted"]),
            "skipped_validate": len(validate_result["skipped"]),
            "promoted": len(promoted),
            "candidates": len(candidates),
            "evolve_drafts": len(evolve_result["drafts_generated"]),
            "skipped_reason": None,
            "ran_at": ran_at,
        }
    finally:
        _lock_release(lock_fh)


# ── Pipeline stats ────────────────────────────────────────────────────────────

# Alias: domains that auto-validate accepts without human review
WHITELIST_DOMAINS = VALIDATE_AUTO_DOMAINS


def _mtime_iso(path: Path) -> str | None:
    """Return ISO-8601 UTC mtime of *path*, or None if path is missing."""
    try:
        ts = path.stat().st_mtime
        return _dt.datetime.fromtimestamp(ts, tz=_dt.timezone.utc).isoformat()
    except OSError:
        return None


def _iter_knowledge_log(since: _dt.date | None = None):
    """Yield parsed knowledge-log lines as dicts within the optional date window.

    Line format: ``YYYY-MM-DD | <event> | <id> | <detail> | <source>``
    """
    if not KNOWLEDGE_LOG.exists():
        return
    try:
        with open(KNOWLEDGE_LOG, "r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw or raw.startswith("#"):
                    continue
                parts = [p.strip() for p in raw.split("|")]
                if len(parts) < 5:
                    continue
                date_str, event, iid, detail, source = parts[0], parts[1], parts[2], parts[3], parts[4]
                try:
                    line_date = _dt.date.fromisoformat(date_str[:10])
                except ValueError:
                    continue
                if since is not None and line_date < since:
                    continue
                yield {"date": line_date, "event": event, "id": iid, "detail": detail, "source": source}
    except OSError:
        pass


def compute_pipeline_stats(days: int = 14) -> dict:
    """Return a snapshot of pipeline activity over the last *days* days.

    Pure function: reads files, writes nothing.
    All counters default to 0 if the relevant files are missing.
    """
    today = _dt.date.today()
    since = today - _dt.timedelta(days=days - 1)  # inclusive window

    # ── Validate stats ────────────────────────────────────────────────────────
    auto_accepted = 0
    manual_accepted = 0
    manual_rejected = 0

    for entry in _iter_knowledge_log(since=since):
        ev = entry["event"]
        src = entry["source"]
        if ev == "accepted" and src == "cx-auto-validate":
            auto_accepted += 1
        elif ev in {"created", "accepted", "promoted"} and src == "cx-validate":
            manual_accepted += 1
        elif ev == "rejected" and src == "cx-validate":
            manual_rejected += 1

    proposals = _load_proposals()
    pending = [p for p in proposals if p.get("status", "pending") == "pending"]
    held = [p for p in proposals if p.get("status") == "held"]
    pending_count = len(pending)
    held_count = len(held)
    pending_by_domain: dict[str, int] = {}
    for p in pending:
        d = str(p.get("domain", "unknown"))
        pending_by_domain[d] = pending_by_domain.get(d, 0) + 1

    pending_in_whitelist = sum(
        cnt for dom, cnt in pending_by_domain.items() if dom in WHITELIST_DOMAINS
    )
    pending_outside_whitelist = pending_count - pending_in_whitelist

    # ── Promote stats ─────────────────────────────────────────────────────────
    auto_promoted = 0
    manual_promoted = 0

    for entry in _iter_knowledge_log(since=since):
        ev = entry["event"]
        src = entry["source"]
        if ev == "promoted" and src == "cx-auto-distill":
            auto_promoted += 1
        elif ev in {"law", "promoted"} and src == "cx-distill":
            manual_promoted += 1

    # candidates queued = non-empty candidates file, count ## headers
    candidates_queued = 0
    if CANDIDATES_FILE.exists():
        try:
            text = CANDIDATES_FILE.read_text(encoding="utf-8")
            candidates_queued = sum(1 for ln in text.splitlines() if ln.startswith("## "))
        except OSError:
            pass

    active_laws = _active_law_count()

    # ── Evolve stats ──────────────────────────────────────────────────────────
    auto_drafts_generated = 0
    manual_evolved = 0

    for entry in _iter_knowledge_log(since=since):
        ev = entry["event"]
        src = entry["source"]
        if ev == "evolve-draft" and src == "cx-auto-evolve":
            auto_drafts_generated += 1
        elif ev == "evolved" and src == "cx-evolve":
            manual_evolved += 1

    drafts_pending_install = 0
    manual_drafts_pending = 0
    if EVOLVED_SKILLS_DIR.is_dir():
        all_mds = list(EVOLVED_SKILLS_DIR.glob("*.md"))
        cluster_drafts = [f for f in all_mds if f.name.startswith("cluster-") and f.name.endswith(".draft.md")]
        drafts_pending_install = len(cluster_drafts)
        manual_drafts_pending = len(all_mds) - len(cluster_drafts)

    # ── Decay / archive stats ─────────────────────────────────────────────────
    decayed_count = 0
    archived_count = 0

    for entry in _iter_knowledge_log(since=since):
        ev = entry["event"]
        src = entry["source"]
        if ev == "decayed" and src == "cx-auto-distill":
            decayed_count += 1
        elif ev == "archived" and src in {"cx-auto-distill", "cx-validate"}:
            archived_count += 1

    # ── Last runs ─────────────────────────────────────────────────────────────
    daily_dir = CORTEX_DIR / "daily-summaries"
    today_summary = daily_dir / f"{today.isoformat()}.md"
    last_eod_path = CORTEX_DIR / ".last-eod"
    eod_path = today_summary if today_summary.exists() else last_eod_path

    analyze_path1 = CORTEX_DIR / ".last-learn-count"
    analyze_path2 = CORTEX_DIR / ".learn-pending"
    # Pick whichever exists (prefer .last-learn-count, fall back to .learn-pending)
    if analyze_path1.exists():
        analyze_path = analyze_path1
    elif analyze_path2.exists():
        analyze_path = analyze_path2
    else:
        analyze_path = analyze_path1  # missing — _mtime_iso returns None

    return {
        "window_days": days,
        "as_of": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "validate": {
            "auto_accepted": auto_accepted,
            "manual_accepted": manual_accepted,
            "manual_rejected": manual_rejected,
            "pending": pending_count,
            "held": held_count,
            "pending_by_domain": pending_by_domain,
            "pending_in_whitelist": pending_in_whitelist,
            "pending_outside_whitelist": pending_outside_whitelist,
        },
        "promote": {
            "auto_promoted": auto_promoted,
            "manual_promoted": manual_promoted,
            "candidates_queued": candidates_queued,
            "active_laws": active_laws,
            "law_cap": LAW_MAX_ACTIVE,
        },
        "evolve": {
            "auto_drafts_generated": auto_drafts_generated,
            "manual_evolved": manual_evolved,
            "drafts_pending_install": drafts_pending_install,
            "manual_drafts_pending": manual_drafts_pending,
        },
        "decay": {
            "decayed": decayed_count,
            "archived": archived_count,
        },
        "last_runs": {
            "auto_distill": _mtime_iso(MARKER_FILE),
            "analyze": _mtime_iso(analyze_path),
            "manual_distill": _mtime_iso(CORTEX_DIR / ".last-distill"),
            "audit": _mtime_iso(CORTEX_DIR / ".last-audit"),
            "eod": _mtime_iso(eod_path),
        },
    }


def _fmt_ts(ts: str | None) -> str:
    """Format an ISO timestamp for human display, or 'never'."""
    if ts is None:
        return "never"
    return ts


def _cmd_pipeline_stats(days: int, as_json: bool) -> None:
    stats = compute_pipeline_stats(days=days)
    if as_json:
        print(json.dumps(stats, indent=2, default=str))
        return

    v = stats["validate"]
    pr = stats["promote"]
    ev = stats["evolve"]
    dc = stats["decay"]
    lr = stats["last_runs"]

    v_activity = "" if any([v["auto_accepted"], v["manual_accepted"], v["manual_rejected"], v["pending"], v["held"]]) else " (no activity)"
    pr_activity = "" if any([pr["auto_promoted"], pr["manual_promoted"], pr["candidates_queued"]]) else " (no activity)"
    ev_activity = "" if any([ev["auto_drafts_generated"], ev["manual_evolved"], ev["drafts_pending_install"], ev["manual_drafts_pending"]]) else " (no activity)"
    dc_activity = "" if any([dc["decayed"], dc["archived"]]) else " (no activity)"

    sep = "─" * 49

    lines = [
        f"CORTEX KNOWLEDGE PIPELINE — last {days} days",
        sep,
        f"  As of:  {stats['as_of']}",
        "",
        f"VALIDATE:{v_activity}",
        f"  ✓ Auto-accepted:    {v['auto_accepted']} proposals → instincts (cx-auto-validate)",
        f"  ✓ Manual accepted:  {v['manual_accepted']} proposals (cx-validate)",
        f"  ✗ Manual rejected:  {v['manual_rejected']} proposals",
        f"  ⚠ Queue depth:      {v['pending']} pending, {v['held']} held (unsafe trigger)",
    ]

    if v["pending_by_domain"]:
        for domain, count in sorted(v["pending_by_domain"].items()):
            tag = "✅ whitelist" if domain in WHITELIST_DOMAINS else "❌ needs judgment"
            lines.append(f"      {domain}: {count}  [{tag}]")

    lines += [
        "",
        f"PROMOTE (instincts → laws):{pr_activity}",
        f"  ✓ Auto-promoted:    {pr['auto_promoted']} instincts (cx-auto-distill)",
        f"  ✓ Manual promoted:  {pr['manual_promoted']} instincts (cx-distill)",
        f"  ⚠ Candidates queued: {pr['candidates_queued']}",
        f"  · Active laws:      {pr['active_laws']}/{pr['law_cap']}",
        "",
        f"EVOLVE (instincts → skills):{ev_activity}",
        f"  ✓ Auto-drafts:      {ev['auto_drafts_generated']} generated (cx-auto-evolve)",
        f"  ✓ Manual evolved:   {ev['manual_evolved']} skills (cx-evolve)",
        f"  ⚠ Drafts pending:   {ev['drafts_pending_install']} at evolved/skills/cluster-*.draft.md",
        f"  · Manual artifacts: {ev['manual_drafts_pending']} at evolved/skills/*.md",
        "",
        f"MAINTENANCE:{dc_activity}",
        f"  · Decayed:    {dc['decayed']} instincts (-0.05 each)",
        f"  · Archived:   {dc['archived']} instincts (conf < 0.10)",
        "",
        "LAST RUNS:",
        f"  · auto-distill:   {_fmt_ts(lr['auto_distill'])}",
        f"  · analyze:        {_fmt_ts(lr['analyze'])}",
        f"  · manual distill: {_fmt_ts(lr['manual_distill'])}",
        f"  · audit:          {_fmt_ts(lr['audit'])}",
        f"  · eod:            {_fmt_ts(lr['eod'])}",
    ]

    print("\n".join(lines))


# ── CLI ───────────────────────────────────────────────────────────────────────

def _cmd_auto(dry_run: bool) -> None:
    summary = run_auto_distill(dry_run=dry_run)
    prefix = "[DRY-RUN] " if dry_run else ""
    if summary.get("skipped_reason"):
        print(f"{prefix}Skipped: {summary['skipped_reason']}")
        return
    print(f"{prefix}Auto-distill complete ({summary['ran_at']}):")
    print(f"  decayed        : {summary['decayed']}")
    print(f"  archived       : {summary['archived']}")
    print(f"  validated      : {summary['validated']}")
    print(f"  skipped_validate: {summary['skipped_validate']}")
    print(f"  promoted       : {summary['promoted']}")
    print(f"  candidates     : {summary['candidates']}")
    print(f"  evolve_drafts  : {summary['evolve_drafts']}")


def _cmd_decay(dry_run: bool) -> None:
    changed = apply_decay(dry_run=dry_run)
    prefix = "[DRY-RUN] " if dry_run else ""
    print(f"{prefix}Decay applied to {len(changed)} instinct(s):")
    for c in changed:
        print(f"  {c['id']}: {c['old_conf']:.4f} → {c['new_conf']:.4f} ({c['days_unused']}d unused)")


def _cmd_promote(dry_run: bool) -> None:
    promoted, candidates = auto_promote_to_law(dry_run=dry_run)
    prefix = "[DRY-RUN] " if dry_run else ""
    print(f"{prefix}Promoted {len(promoted)} instinct(s) to law:")
    for p in promoted:
        print(f"  {p['id']} (conf={p['confidence']})")
    print(f"\n{prefix}Candidates (almost ready, {len(candidates)} total):")
    for c in candidates:
        print(f"  {c['id']} (conf={c['confidence']}) — {'; '.join(c['reasons'])}")


def _cmd_status() -> None:
    promoted, candidates = auto_promote_to_law(dry_run=True)
    active_laws = _active_law_count()
    print(f"Active laws: {active_laws}/{LAW_MAX_ACTIVE}")
    print(f"Promotion candidates: {len(candidates)}")
    for c in candidates:
        print(f"  {c['id']} (conf={c['confidence']}) — {'; '.join(c['reasons'])}")
    if _is_rate_limited():
        print("\nRate-limit: active (last run < 24h ago)")
    else:
        print("\nRate-limit: clear (ready to run)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="distill_engine",
        description="fs-cortex auto-distillation engine (Sprint 6/7)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_auto = sub.add_parser("auto", help="Full auto pass (decay + archive + promote)")
    p_auto.add_argument("--dry-run", action="store_true")

    p_decay = sub.add_parser("decay", help="Apply confidence decay only")
    p_decay.add_argument("--dry-run", action="store_true")

    p_promote = sub.add_parser("promote", help="Check promotion candidates")
    p_promote.add_argument("--dry-run", action="store_true")

    sub.add_parser("status", help="Show current candidates and rate-limit state")

    p_pipeline = sub.add_parser(
        "pipeline-stats",
        help="Show pipeline activity dashboard (Sprint 7.1+)",
    )
    p_pipeline.add_argument(
        "--days", type=int, default=14, metavar="N",
        help="Lookback window in days (default: 14)",
    )
    p_pipeline.add_argument(
        "--json", dest="as_json", action="store_true",
        help="Machine-readable JSON output",
    )

    args = parser.parse_args(argv)

    if args.cmd == "auto":
        _cmd_auto(args.dry_run)
    elif args.cmd == "decay":
        _cmd_decay(args.dry_run)
    elif args.cmd == "promote":
        _cmd_promote(args.dry_run)
    elif args.cmd == "status":
        _cmd_status()
    elif args.cmd == "pipeline-stats":
        _cmd_pipeline_stats(days=args.days, as_json=args.as_json)

    return 0


if __name__ == "__main__":
    sys.exit(main())
