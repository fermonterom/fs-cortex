#!/usr/bin/env python3
"""
distill_engine.py — Auto-distillation engine (Sprint 7, v3.23.0).

Deterministic parts of the distillation pipeline that run automatically at
SessionStart (once per 24 h, idempotent) without any human judgment:
  1. Confidence decay  (-0.05 per 30 days unused)
  2. Archive low-confidence instincts (< 0.10)
  3. Auto-validate proposals that meet whitelist criteria (Sprint 7)
  4. Promote mature instincts to laws (v4 deterministic 4-criteria gate —
     see auto_promote_to_law docstring / DESIGN-V4.md §3)
  5. Auto-evolve: detect clusters of mature instincts, generate skill drafts (Sprint 7)

Public API
----------
  run_auto_distill(dry_run=False) -> dict
  apply_decay(now=None, dry_run=False) -> list[dict]
  archive_decayed(threshold=0.10, dry_run=False) -> list[str]
  auto_validate_proposals(dry_run=False) -> dict
  auto_promote_to_law(dry_run=False) -> tuple[list[dict], list[dict]]
  auto_evolve_detect(dry_run=False) -> dict
  law_audit() -> dict  # v4.2.0 §C4 — post-promotion legibility audit

CLI
---
  python3 distill_engine.py auto [--dry-run]
  python3 distill_engine.py decay [--dry-run]
  python3 distill_engine.py promote [--dry-run]
  python3 distill_engine.py law-audit [--json]
  python3 distill_engine.py status
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shutil
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
import file_lock as _file_lock  # issue #49 — cross-runtime advisory lock

# ── Environment & paths ─────────────────────────────────────────────────────

CORTEX_DIR = Path(os.environ.get("CORTEX_DIR", str(Path.home() / ".claude" / "cortex")))
INSTINCTS_DIR = CORTEX_DIR / "instincts" / "global"
LAWS_DIR = CORTEX_DIR / "laws"
IMPACT_FILE = CORTEX_DIR / "impact.jsonl"
KNOWLEDGE_LOG = CORTEX_DIR / "knowledge-log.md"
CANDIDATES_FILE = CORTEX_DIR / "auto-distill-candidates.md"
MARKER_FILE = CORTEX_DIR / ".last-auto-distill"
LOCK_FILE = CORTEX_DIR / ".distill-engine.lock"
# Issue #49 — shared cross-runtime lock for proposals-history.jsonl and
# instinct-tracking.json. The Node Stop hook
# (hooks/lib/proposals-storage.js + hooks/session-learner.js) takes the SAME
# lockfile via fs.openSync(path, 'wx'); coordination is at the filesystem
# level. Distinct from LOCK_FILE (which only serializes the Python engine).
HISTORY_LOCK_FILE = CORTEX_DIR / ".proposals-history.lock"
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
# Written by impact_log.py's apply_outcome_nudges (schema v2, see that
# module's _load_nudge_state docstring). Read/pruned here too (reap_stale_
# nudge_state) via its own path constant rather than importing impact_log,
# to keep this module's write surface self-contained.
NUDGE_STATE_FILE = CORTEX_DIR / "nudge-state.json"
# v4.2.0 §C4 (DESIGN-laws-v4.2.md): tier classification for laws, consumed
# by session-start.py's principle/tool split and read here for law_audit().
# Absent id -> defaults to "principle" (never hidden), same retrocompat rule
# session-start.py uses.
LAWS_META_FILE = LAWS_DIR / "laws-meta.json"
# v4.2.0 §C4: law_audit() writes its per-run snapshot here so Fernando gets
# periodic legibility to prune the laws layer by hand with data instead of
# an unmeasurable auto-feedback signal (see DESIGN-laws-v4.2.md §C4).
LAW_AUDIT_FILE = CORTEX_DIR / ".law-audit.json"

RATE_LIMIT_HOURS = 24
DECAY_PER_30_DAYS = 0.05
DECAY_PERIOD_DAYS = 30
ARCHIVE_THRESHOLD = 0.10
# nudge-state.json reaper (P2 audit 2026-07-04): a saturated instinct
# (last_direction == "saturated", i.e. it hit NUDGE_MAX_CONF and stopped
# receiving nudges) with no fresh outcome cohort for NUDGE_STALE_DAYS is
# stuck at ceiling confidence forever, since apply_outcome_nudges only
# advances it when a new cohort arrives. reap_stale_nudge_state() applies
# a one-off decay so it re-enters the normal decay/nudge cycle instead of
# being cemented at 0.99. Entries whose last_event_ts itself is older than
# NUDGE_STALE_DAYS (stale regardless of saturation) get the same treatment.
NUDGE_STALE_DAYS = 60
NUDGE_SATURATED_STALE_DAYS = 7
NUDGE_REAP_DECAY = 0.10
LAW_THRESHOLD_CONF = 0.95
LAW_SUSTAINED_DAYS = 14
LAW_MIN_PROJECTS = 3  # v4 (2026-07-02, DESIGN-V4.md §3): restored 1 → 3.
                      # v3.24.0 had lowered this to 1 because the old gate
                      # combo (LAW_SUSTAINED_DAYS + LAW_MIN_DISTINCT_SESSIONS
                      # + LAW_MIN_USEFUL_14D) already guaranteed quality and
                      # a 3-project floor was a permanent dead-end for
                      # solo-project knowledge. v4 drops that whole combo
                      # (see auto_promote_to_law docstring) and needs
                      # `projects_seen` to carry the universality signal on
                      # its own — a law fires at EVERY SessionStart, so
                      # cross-project evidence is the deliberate bar now.
LAW_MIN_USEFUL_14D = 5  # v4: no longer read by auto_promote_to_law (kept —
                        # referenced by legacy tests / possible future reuse).
LAW_MAX_NOISE_14D = 0
LAW_MIN_OCCURRENCES_V4 = 10  # v4 (DESIGN-V4.md §3): post-fix occurrence
                             # counter. `occurrences` pre-v4 was inflated by
                             # upstream tracking bugs and is not trustworthy;
                             # `occurrences_v4` starts at 0 per-instinct
                             # (lazy migration, see _ensure_occurrences_v4)
                             # and is incremented by the normal tracking
                             # pipeline going forward.
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
LAW_MAX_CHARS = 200  # v3.35.2 (#56.1): was 120 — mid-sentence cuts shipped laws with incomplete instructions
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
# v3.37.0: 'agent-evolution' moved AUTO → HUMAN. Those proposals are operator
# TODOs ("consider /cx-evolve") — auto-validating them minted 19 instincts
# with bare 'Agent' triggers that injected the same recommendation on every
# Agent call (2026-06 corpus audit, SPAM_TRIGGER bucket).
# v4 (2026-07-02, DESIGN-V4.md §2 / CLAUDE.md item 5): 'error-recovery' moved
# AUTO → HUMAN. `session-learner.js`'s error-recovery detector still confuses
# normal subprocess output (grep headers, npm warn, codex CLI banners) with
# real failures (audit-cortex-2026-07-02.md follow-up #6, observe.py not yet
# fixed in this file's scope) — auto-accepting that domain kept minting
# gotcha-basura instincts. Human review via /cx-review gates it now.
VALIDATE_AUTO_DOMAINS = {"gotcha", "pattern"}
# v3.29.0 (Sprint 8 §4.1): added 'coupling' + 'agent-quality'. Pre-v3.29.0 these
# were orphan domains — emitted by detectFileCoupling + detectAgentSubtypes but
# absent from every whitelist, so every proposal fell through to
# `needs-human-judgment` skip and never produced an instinct. Registering them
# here lets the operator review them via `/cx-validate` and decide manually
# (human-gated, exactly as the Sprint 8 detector overhaul intends).
VALIDATE_HUMAN_DOMAINS = {"correction", "user-preference", "decision", "workflow",
                          "coupling", "agent-quality", "agent-evolution",
                          "error-recovery"}

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

# v3.37.0 — once-per-run guard for the law-cap stall knowledge entry.
_LAW_CAP_STALL_LOGGED = {"done": False}

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


def _write_locked(fn):
    """Serialize a write-path engine operation under the shared advisory lock
    (issue #45). Blocks until our turn so a manual swap / promote / demote never
    races a concurrent auto-distill or another manual op. This serializes the
    Python engine against itself; the Stop hook's append to
    proposals-history.jsonl is a separate cross-runtime race (issue #49)."""
    import functools

    @functools.wraps(fn)
    def _wrapper(*args, **kwargs):
        fh, _ = _lock_acquire(nonblocking=False)
        try:
            return fn(*args, **kwargs)
        finally:
            _lock_release(fh)

    return _wrapper


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

def _count_distinct_projects(fields: dict, iid: str, tracking_data: dict | None = None) -> int:
    """Count distinct project hashes where this instinct has been seen.

    AD fix #2 (2026-07-02): injector-engine.js writes `projects_seen[]` into
    instinct-tracking.json on every PreToolUse match (the live, cross-project
    signal — see injector-engine.js:462-470), but this function pre-fix only
    looked at the YAML's own `projects_seen` field and the filesystem — both
    of which stay empty for instincts that only ever matched via the
    injector's inline tracking. Result: the law-promotion gate's Criteria 2
    (`>= LAW_MIN_PROJECTS distinct projects`) was structurally unreachable
    for exactly the instincts it's meant to detect. Fusing in
    instinct-tracking.json closes that gap; the three sources are deduped
    into one set.
    """
    seen: set[str] = set()

    # From the YAML itself
    pid = str(fields.get("project_id", "")).strip()
    if pid:
        seen.add(pid)

    # From projects_seen[] list field (YAML)
    ps = fields.get("projects_seen")
    if isinstance(ps, list):
        for p in ps:
            s = str(p).strip()
            if s:
                seen.add(s)

    # From instinct-tracking.json's projects_seen[] (injector-engine.js,
    # PreToolUse-time writes — AD fix #2).
    if tracking_data is None:
        tracking_data = _load_instinct_tracking()
    if isinstance(tracking_data, dict):
        entry = tracking_data.get(iid)
        if isinstance(entry, dict):
            tracked_ps = entry.get("projects_seen")
            if isinstance(tracked_ps, list):
                for p in tracked_ps:
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


@_write_locked
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

    # v4.2.0 §C1 (DESIGN-laws-v4.2.md): archive the source instinct on every
    # law-creation path, not just auto_promote_to_law. Pre-fix, manual swap
    # promotion left the source instinct YAML live in instincts/global/ after
    # writing the law file, so it kept firing as a PreToolUse instinct AND
    # injecting at every SessionStart as a law — the exact double-injection
    # bug DESIGN-laws-v4.2.md §"Contexto y evidencia" measured (41 + 17
    # redundant injections). Same archive convention auto_promote_to_law uses.
    if new_instinct_path.exists():
        archive_dir = new_instinct_path.parent / "archive"
        ts_date = today.strftime("%Y%m%d")
        archive_dest = archive_dir / f"{new_iid}.promoted-to-law-{ts_date}.yaml"
        try:
            archive_dir.mkdir(parents=True, exist_ok=True)
            new_instinct_path.rename(archive_dest)
            _log_knowledge(
                "archived", new_iid,
                f"promoted to law via swap; source archived as {archive_dest.name}",
                source="cx-distill-swap",
            )
        except OSError as e:
            _log_knowledge(
                "archive-failed", new_iid,
                f"law promoted via swap but source archive failed: {e}",
                source="cx-distill-swap",
            )

    _log_knowledge(
        "swap-promoted", new_iid,
        f"archived={deprecate_iid} archive_file={archive_path.name}",
        source="cx-distill-swap",
    )
    return True, (
        f"swapped: {deprecate_iid} → archive/{archive_path.name}; "
        f"{new_iid} promoted (conf={conf:.2f})"
    )


@_write_locked
def demote_law_to_domain(
    law_id: str,
    dry_run: bool = False,
) -> tuple[bool, str]:
    """Demote a Domain law back to the instinct cohort (v3.34 Core/Domain split).

    Inverse of promotion: the law stops being injected at every SessionStart and
    re-joins the relevance-gated instinct pool (injected via PreToolUse only when
    its `trigger` matches). Steps:
      1. Locate the instinct yaml backing this law (global/ first, archive/ as
         fallback). If NONE exists, REFUSE — we never invent a trigger, because a
         law with no usable trigger would silently stop injecting entirely.
      2. Refuse if the backing yaml has no `trigger` (same silent-drop risk).
      3. Ensure the yaml lives in instincts/global/ with `law_eligible: false`
         so `auto_promote_to_law` never re-promotes it back to a law.
      4. Archive laws/<id>.txt → laws/archive/<id>.<ts>.txt (reversible).

    Returns (success, human-readable reason)."""
    law_path = LAWS_DIR / f"{law_id}.txt"
    if not law_path.exists() or "archive" in str(law_path):
        return False, f"law not found: {law_id}.txt"

    instincts_archive = INSTINCTS_DIR.parent / "archive"
    global_yaml = INSTINCTS_DIR / f"{law_id}.yaml"
    archive_yaml = instincts_archive / f"{law_id}.yaml"
    src_yaml: Path | None = None
    restore_from_archive = False
    if global_yaml.exists():
        src_yaml = global_yaml
    elif archive_yaml.exists():
        src_yaml = archive_yaml
        restore_from_archive = True
    if src_yaml is None:
        return False, (
            f"no instinct yaml backing for {law_id}; materialize it (with a "
            f"validated trigger) before demoting — refusing to invent one"
        )

    result = _read_instinct(src_yaml)
    if result is None:
        return False, f"instinct yaml unreadable: {law_id}"
    _fields, text = result
    if not str(_fields.get("trigger", "")).strip():
        return False, (
            f"instinct yaml for {law_id} has no trigger; it would never inject "
            f"as a Domain instinct — refusing to demote"
        )

    if dry_run:
        return True, (
            f"dry-run: would archive law {law_id} and keep instinct in global/ "
            f"with law_eligible:false"
        )

    # 1. Ensure the instinct yaml is in global/ flagged law_eligible:false.
    new_text = _set_frontmatter_field(text, "law_eligible", "false")
    INSTINCTS_DIR.mkdir(parents=True, exist_ok=True)
    try:
        _atomic_write(global_yaml, new_text)
    except OSError as e:
        return False, f"write instinct yaml failed: {e}"
    if restore_from_archive:
        try:
            archive_yaml.unlink()
        except OSError:
            pass  # archive copy left behind is harmless

    # 2. Archive the law .txt (reversible — kept in laws/archive/).
    archive_dir = LAWS_DIR / "archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
    archive_path = archive_dir / f"{law_id}.{ts}.txt"
    try:
        law_content = law_path.read_text(encoding="utf-8")
        _atomic_write(archive_path, law_content)
        law_path.unlink()
    except OSError as e:
        return False, f"archive law failed: {e}"

    _log_knowledge(
        "demoted-to-domain", law_id,
        f"archive_file={archive_path.name}",
        source="cx-distill-demote",
    )
    return True, (
        f"demoted {law_id}: law → archive/{archive_path.name}; instinct active "
        f"in global/ (law_eligible:false)"
    )


def _law_content_for_jaccard(law_path: Path) -> str:
    """Read first line of a law file for Jaccard comparison."""
    try:
        return law_path.read_text(encoding="utf-8").split("\n")[0].strip()
    except OSError:
        return ""


def _load_laws_meta() -> dict:
    """Load laws/laws-meta.json. Returns {} on missing/invalid (retrocompat:
    caller defaults every id's tier to 'principle', same rule session-start.py
    applies when the meta-file is absent or an id has no entry)."""
    if not LAWS_META_FILE.exists():
        return {}
    try:
        data = json.loads(LAWS_META_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    laws = data.get("laws")
    return laws if isinstance(laws, dict) else {}


def law_audit() -> dict:
    """Post-promotion audit of the active laws layer (v4.2.0 §C4).

    DESIGN-laws-v4.2.md §"Contexto y evidencia": promotion TO a law is
    statistically gated (auto_promote_to_law's 4 criteria), but once a law
    is written nothing measures its ongoing value — "feedback congelado
    post-promoción". This gives a human (Fernando) periodic legibility to
    prune the laws layer with data, rather than an auto-feedback signal that
    the DESIGN doc's adversarial review confirmed is unmeasurable without a
    trigger (a law always injects, so "was it followed" can't be attributed).

    For every active (non-archived) law in laws/*.txt, returns:
      - id:                     law filename stem
      - tier:                   from laws/laws-meta.json, default "principle"
                                (retrocompat — never hides an unclassified law)
      - age_days:               days since the .txt file's mtime
      - dup_active_instinct:    True if an instinct YAML with the same id is
                                 still live in instincts/global/ or any
                                 projects/*/instincts/ (the exact C1 bug this
                                 module's fix targets — a law with a live
                                 twin instinct double-injects)
      - backing_instinct_noise: useful/(1+noise) ratio over the last 14 days
                                 of impact.jsonl for this id, or None if the
                                 id has no impact data at all (distinct from
                                 a real 0.0 ratio)

    Returns {"as_of": <iso date>, "laws": [ ...per-law dicts... ]}. Also
    writes the same payload to LAW_AUDIT_FILE (~/.claude/cortex/.law-audit.json)
    as a side effect, mirroring compute_pipeline_stats's read-only shape but
    persisted so a periodic runner (cx-maintain) can diff runs without
    recomputing.
    """
    today = _dt.date.today()
    meta = _load_laws_meta()
    impact = _impact_per_iid(days=14)

    # Same "alive" definition _all_instinct_paths()/prune_instinct_tracking()
    # use elsewhere in this module: a non-archived instinct YAML with this id
    # in instincts/global/ or any projects/*/instincts/.
    alive_instinct_ids = {p.stem for p in _all_instinct_paths()}

    entries: list[dict] = []
    if LAWS_DIR.is_dir():
        for law_path in sorted(LAWS_DIR.glob("*.txt")):
            if "archive" in str(law_path):
                continue
            iid = law_path.stem
            tier = "principle"
            meta_entry = meta.get(iid)
            if isinstance(meta_entry, dict) and meta_entry.get("tier"):
                tier = str(meta_entry["tier"])

            iid_impact = impact.get(iid)
            if iid_impact is None:
                noise_ratio = None
            else:
                useful = int(iid_impact.get("useful", 0) or 0)
                noise = int(iid_impact.get("noise", 0) or 0)
                noise_ratio = round(useful / (1 + noise), 4)

            entries.append({
                "id": iid,
                "tier": tier,
                "age_days": _law_age_days(law_path, today),
                "dup_active_instinct": iid in alive_instinct_ids,
                "backing_instinct_noise": noise_ratio,
            })

    result = {"as_of": today.isoformat(), "laws": entries}
    try:
        _atomic_write(LAW_AUDIT_FILE, json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    except OSError:
        pass
    return result


# v4 (2026-07-02, DESIGN-V4.md §3, audit-cortex-2026-07-02.md follow-up #1):
# a trigger is frequently a raw regex ("Bash|Edit|Write", "Read.*\\(file_path")
# rather than prose. The old `trigger[:40]` blind char-slice truncated those
# mid-pattern and shipped laws with a dangling `|` or an unclosed paren —
# unreadable and, worse, looked like an unterminated regex to a human
# skimming the law file. Any metacharacter typical of a tool-name alternation
# routes to a prose summary (tool name only) instead of a char slice.
_REGEX_METACHAR_RE = re.compile(r'[|()\\[\]^$*+?{}]')
_TRIGGER_TOOL_NAME_RE = re.compile(r'^([A-Za-z][A-Za-z0-9_]*)')


def _summarize_trigger(trigger: str) -> str:
    """Return a prose-safe trigger phrase, never a raw/truncated regex.

    - Regex-looking trigger (contains alternation/group/anchor metachars):
      collapse to "<ToolName> se ejecuta" — the tool name is the only part
      of a compiled matcher trigger that is meaningful prose on its own.
    - Plain-text trigger: cut at a word boundary (rfind ' '), matching the
      same policy the LAW_MAX_CHARS cut below already applies — never a
      hard char slice that can land mid-word.
    """
    trigger = trigger.strip()
    if not trigger:
        return ""
    if _REGEX_METACHAR_RE.search(trigger):
        m = _TRIGGER_TOOL_NAME_RE.match(trigger)
        tool = m.group(1) if m else "la herramienta"
        return f"se usa {tool}"
    if len(trigger) <= 40:
        return trigger
    cut = trigger.rfind(" ", 0, 40)
    if cut <= 0:
        cut = 40  # no usable word boundary in the first 40 chars — hard cut
    return trigger[:cut].rstrip(" ,;:")


def _derive_law_line(fields: dict) -> str:
    """Derive a ≤200-char one-liner for the law file from the instinct.

    v3.35.2 (#56.1): cap raised 120 → 200 and truncation now cuts at a word
    boundary, so a derived law never ends mid-word with a dangling clause.
    v4 (2026-07-02): trigger truncation routed through `_summarize_trigger`
    so a regex trigger is never embedded raw/truncated (follow-up #1).
    """
    action = str(fields.get("action", "")).strip()
    trigger = str(fields.get("trigger", "")).strip()

    # If action already starts with imperative style, use as-is
    if re.match(r'^(Always|Never|Use|Avoid|When|If|Do|Don\'t|Run|Check|Set|Add|Call|Write)', action, re.IGNORECASE):
        line = action
    else:
        # Build "When <trigger>, <action>"
        short_trigger = _summarize_trigger(trigger)
        if short_trigger:
            line = f"When {short_trigger}, {action}"
        else:
            line = action

    if len(line) > LAW_MAX_CHARS:
        cut = line.rfind(" ", 0, LAW_MAX_CHARS)
        if cut < LAW_MAX_CHARS // 2:
            cut = LAW_MAX_CHARS - 1  # no usable word boundary — hard cut
        line = line[:cut].rstrip(" ,;:") + "…"
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


# v4 — once-per-run guard so a missing impact.jsonl only logs one knowledge
# entry per auto_promote_to_law pass instead of once per skipped instinct.
_IMPACT_LOG_SKIP_LOGGED = {"done": False}


def _ensure_occurrences_v4(fields: dict, text: str, dry_run: bool) -> tuple[int, str]:
    """Lazily migrate the legacy `occurrences` counter to `occurrences_v4`.

    DESIGN-V4.md §3: pre-v4 `occurrences` was inflated by upstream tracking
    bugs and is not a trustworthy maturity signal. v4 resets the counter —
    `occurrences_v4` starts at 0 and is incremented by the normal tracking
    pipeline going forward; the old value survives as `occurrences_legacy`
    for forensics but is never read again by the promotion gate. Migration
    is lazy: it only touches a yaml the moment auto_promote_to_law visits
    it, never a bulk rewrite of every instinct file.

    Returns (occurrences_v4, possibly-updated text). Caller is responsible
    for the atomic write (guarded by `dry_run`, matching every other
    in-place mutation in this function).
    """
    if "occurrences_v4" in fields:
        try:
            return int(fields["occurrences_v4"]), text
        except (TypeError, ValueError):
            return 0, text

    legacy_val = fields.get("occurrences", 0)
    try:
        legacy_val = int(legacy_val)
    except (TypeError, ValueError):
        legacy_val = 0

    if dry_run:
        return 0, text

    new_text = _set_frontmatter_field(text, "occurrences_legacy", legacy_val)
    new_text = _remove_frontmatter_field(new_text, "occurrences")
    new_text = _set_frontmatter_field(new_text, "occurrences_v4", 0)
    return 0, new_text


def auto_promote_to_law(
    dry_run: bool = False,
) -> tuple[list[dict], list[dict]]:
    """Deterministic law promotion gate (v4 — DESIGN-V4.md §3).

    Promotes an instinct to a law when ALL of:
      - confidence >= LAW_THRESHOLD_CONF (0.95)
      - seen in >= LAW_MIN_PROJECTS distinct projects (3)
      - occurrences_v4 >= LAW_MIN_OCCURRENCES_V4 (10, post-fix counter —
        see `_ensure_occurrences_v4`)
      - no noise feedback in the last 14 days, per impact.jsonl; if the
        impact log itself is not accessible the check is SKIPPED (not
        failed) and the skip is logged once per run

    `law_eligible: false` is respected as an explicit human veto (an
    instinct demoted from a law must never be re-promoted). `law_eligible:
    true` is NOT required — the old opt-in flag ("Criteria 8") is gone;
    statistical maturity across the 4 criteria above is now sufficient by
    design (P3 — "reglas objetivas sustituyen a flags manuales que nadie
    pone").

    Two structural constraints are preserved from the pre-v4 gate (not
    maturity criteria, just "can't do it right now"): no duplicate law
    (exact id collision or Jaccard >= LAW_JACCARD_THRESHOLD against an
    existing law) and active law count < LAW_MAX_ACTIVE (with the existing
    deprecation-candidate surfacing via _find_least_impactful_law).

    The old sustained-14-day-since-threshold field, the >=3-distinct-
    sessions gate and the useful>=5-in-14d gate are gone: DESIGN-V4.md §3
    only lists the 4 criteria above as "TODAS" required, and P4 ("menos
    artefactos, mejores") explicitly retires the flags nobody read.

    Returns (promoted, candidates) where:
      promoted   = instincts that now have a law file (source yaml archived)
      candidates = instincts that almost qualify (for surfacing to user)
    """
    today = _dt.datetime.now(_dt.timezone.utc).date()
    impact = _impact_per_iid(days=14)
    impact_log_accessible = IMPACT_FILE.exists()
    active_laws = _active_law_count()
    # AD fix #2 — loaded once per run and passed to _count_distinct_projects
    # so instinct-tracking.json's projects_seen[] (injector-engine.js writes)
    # counts toward Criteria 2 without a per-instinct file read.
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

        # v3.34 Core/Domain split, preserved in v4: an instinct explicitly
        # demoted from a law (law_eligible:false) must never be re-promoted,
        # or the split unravels on the next maintain cycle. Skip it
        # entirely (not even a candidate). `law_eligible:true` no longer
        # has a role here — see docstring.
        if str(fields.get("law_eligible", "")).strip().lower() == "false":
            continue

        conf = fields.get("confidence")
        try:
            conf = float(conf)
        except (TypeError, ValueError):
            continue

        # ── v4 lazy migration: occurrences → occurrences_legacy + occurrences_v4
        occurrences_v4, migrated_text = _ensure_occurrences_v4(fields, text, dry_run)
        if migrated_text != text:
            text = migrated_text
            if not dry_run:
                _atomic_write(path, text)

        failed_reasons: list[str] = []

        # ── Criteria 1: confidence >= 0.95 ────────────────────────────────
        if conf < LAW_THRESHOLD_CONF:
            # Not even a candidate — don't clutter the list.
            continue

        # ── Criteria 2: >= LAW_MIN_PROJECTS distinct projects ─────────────
        proj_count = _count_distinct_projects(fields, iid, tracking_data)
        if proj_count < LAW_MIN_PROJECTS:
            failed_reasons.append(f"projects < {LAW_MIN_PROJECTS} ({proj_count} seen)")

        # ── Criteria 3: occurrences_v4 >= LAW_MIN_OCCURRENCES_V4 ──────────
        if occurrences_v4 < LAW_MIN_OCCURRENCES_V4:
            failed_reasons.append(
                f"occurrences_v4 < {LAW_MIN_OCCURRENCES_V4} ({occurrences_v4})"
            )

        # ── Criteria 4: no noise feedback in 14d ──────────────────────────
        if impact_log_accessible:
            iid_impact = impact.get(iid, {"useful": 0, "noise": 0})
            if iid_impact["noise"] > LAW_MAX_NOISE_14D:
                failed_reasons.append(f"noise > 0 ({iid_impact['noise']} in 14d)")
        elif not _IMPACT_LOG_SKIP_LOGGED.get("done"):
            # impact.jsonl missing/unreadable — skip this specific check
            # rather than failing every candidate on infra absence.
            _log_knowledge(
                "impact-log-unavailable", "-",
                "impact.jsonl not accessible; noise-14d check skipped this pass",
                source="cx-auto-promote",
            )
            _IMPACT_LOG_SKIP_LOGGED["done"] = True

        # ── Structural: no existing law + Jaccard < 0.50 ──────────────────
        law_path = LAWS_DIR / f"{iid}.txt"
        if law_path.exists() and "archive" not in str(law_path):
            failed_reasons.append(f"law already exists ({iid}.txt)")
        else:
            candidate_content = _derive_law_line(fields)
            for law_id, law_content in existing_laws:
                sim = _jaccard(candidate_content, law_content)
                if sim >= LAW_JACCARD_THRESHOLD:
                    failed_reasons.append(f"duplicate of {law_id} (Jaccard {sim:.2f})")
                    break

        # ── Structural: active law count < LAW_MAX_ACTIVE ─────────────────
        # v3.32.0 §4.5, kept in v4: when saturated, propose a deprecation
        # candidate (lowest useful/(1+noise) ratio, age >= 7d) so the
        # operator knows which law to retire via the existing swap
        # mechanism. Engine never auto-swaps — only the operator confirms.
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
                # v3.37.0 — surface the stall in the knowledge timeline (once
                # per run). Saturated cap + nothing deprecable means the
                # promotion pipeline is deadlocked until laws age past
                # LAW_DEPRECATE_MIN_AGE_DAYS; before this entry the operator
                # had no persistent signal that promotions were being dropped.
                if not _LAW_CAP_STALL_LOGGED.get("done"):
                    _log_knowledge(
                        "law-cap-stall", iid,
                        f"laws {active_laws}/{LAW_MAX_ACTIVE} saturated, no deprecation candidate",
                        source="cx-auto-distill",
                    )
                    _LAW_CAP_STALL_LOGGED["done"] = True

        if failed_reasons:
            candidates.append({
                "id": iid,
                "confidence": round(conf, 4),
                "reasons": failed_reasons,
            })
            if not dry_run:
                _log_knowledge("candidate", iid, "; ".join(failed_reasons))
        else:
            # All criteria pass — promote!
            law_line = _derive_law_line(fields)
            promoted.append({"id": iid, "confidence": round(conf, 4)})
            if not dry_run:
                LAWS_DIR.mkdir(parents=True, exist_ok=True)
                _atomic_write(law_path, law_line + "\n")
                active_laws += 1
                # Refresh existing laws list for subsequent iterations
                existing_laws.append((iid, law_line))
                _log_knowledge("promoted", iid, f"law written: {law_line[:80]}")

                # v4 item 3 (DESIGN-V4.md §3): auto-archive the source
                # instinct after a successful promotion, same convention
                # the 2026-07-02 manual cleanup used
                # (`<id>.promoted-to-law-<YYYYMMDD>.yaml`).
                archive_dir = path.parent / "archive"
                ts = today.strftime("%Y%m%d")
                archive_dest = archive_dir / f"{iid}.promoted-to-law-{ts}.yaml"
                try:
                    archive_dir.mkdir(parents=True, exist_ok=True)
                    path.rename(archive_dest)
                    _log_knowledge(
                        "archived", iid,
                        f"promoted to law; source archived as {archive_dest.name}",
                        source="cx-auto-promote",
                    )
                except OSError as e:
                    _log_knowledge(
                        "archive-failed", iid,
                        f"law promoted but source archive failed: {e}",
                        source="cx-auto-promote",
                    )

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

    # v3.35.2 (#56 audit): the first list item must start on its OWN line.
    # The old join put it inline after the key (`tags:   - 'x'`), which the
    # tolerant engine parser accepted but strict YAML rejects — 27 live
    # instinct files shipped malformed before this fix.
    tags_yaml = (
        "\n" + "\n".join(f"  - {_yaml_single_quote(t)}" for t in tags)
        if tags
        else " []"
    )

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
        f"tags:{tags_yaml}",
        f"created: '{_yaml_single_quote(today)}'",
        f"first_seen: '{_yaml_single_quote(today)}'",
        f"last_seen: '{_yaml_single_quote(today)}'",
        f"occurrences: 1",
        # AD fix #3 (2026-07-02) — DESIGN-V4.md §2: "un instinct nuevo nace
        # como draft y solo pasa a confirmed ... con >=5 ocurrencias en >=3
        # sesiones". Pre-fix this generator (used by cx-auto-validate) never
        # wrote `status`, so parse_yaml_frontmatter/session-learner.js
        # treated the instinct as already-confirmed (grandfather default —
        # see cx-status.md's load_instincts) and it injected immediately
        # with zero tracked occurrences, skipping the draft gate entirely.
        f"status: draft",
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
        try:
            os.chmod(log_path, 0o600)  # #47 — logs are operator-only
        except OSError:
            pass
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
        try:
            os.chmod(SECURITY_LOG_FILE, 0o600)  # #47 — security log is operator-only
        except OSError:
            pass
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


def _proposal_session(p: dict) -> str:
    """Canonical proposal session field with legacy fallbacks."""
    if not isinstance(p, dict):
        return ""
    sid = p.get("session_id") or p.get("session") or (p.get("_incident") or {}).get("sid") or ""
    sid_norm = str(sid).strip()
    if sid_norm.lower() == "unknown":
        return ""
    return sid_norm


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
    distinct_sessions = len({_proposal_session(p) for p in reviewed if _proposal_session(p)})
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


def _archive_corrupted_marker(content: str | None, reason: str) -> None:
    """Rename a corrupted .promoted-detectors.json to
    `<file>.corrupt-<UTC-ts>` so the operator can recover the prior
    state instead of seeing it silently overwritten with an empty
    marker. Falls back to writing `content` to the archive path if the
    rename fails (because the original file may already be gone after
    the read).

    Best-effort: any I/O error is swallowed and security-logged."""
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    archive_path = PROMOTED_DETECTORS_FILE.with_name(
        PROMOTED_DETECTORS_FILE.name + f".corrupt-{ts}"
    )
    moved = False
    if PROMOTED_DETECTORS_FILE.exists():
        try:
            PROMOTED_DETECTORS_FILE.rename(archive_path)
            moved = True
        except OSError:
            pass
    if not moved and content is not None:
        try:
            _atomic_write(archive_path, content)
            moved = True
        except OSError:
            pass
    _log_security_event(
        "promoted-detectors:archived-corrupt-marker",
        f"reason={reason} archive={archive_path.name if moved else 'NOT-WRITTEN'}",
    )


@_write_locked
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
        prev_content: str | None = None
        try:
            prev_content = PROMOTED_DETECTORS_FILE.read_text(encoding="utf-8")
            existing = json.loads(prev_content)
        except (OSError, json.JSONDecodeError) as e:
            _archive_corrupted_marker(prev_content, reason=f"parse-fail:{e}")
            existing = {"version": 1, "promoted": []}
        else:
            if not isinstance(existing, dict) or existing.get("version") != 1:
                # Schema-drift / unknown version: preserve original by
                # rename-archive (review-quick-win) so the operator-approved
                # data isn't silently lost.
                _archive_corrupted_marker(
                    prev_content,
                    reason=f"prev-version={existing.get('version') if isinstance(existing, dict) else 'not-dict'}",
                )
                existing = {"version": 1, "promoted": []}
            elif not isinstance(existing.get("promoted"), list):
                # Schema right but `promoted` field wrong type: also archive.
                _archive_corrupted_marker(
                    prev_content,
                    reason=f"promoted-not-list:{type(existing.get('promoted')).__name__}",
                )
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

        # v3.32.0 §4.4.e: also honor promoted_sources here so a HUMAN-
        # domain proposal with an operator-promoted source falls through
        # to the AUTO accept path (otherwise the first skip is bypassed
        # but this second one would still block it).
        if domain not in VALIDATE_AUTO_DOMAINS and source not in promoted_sources:
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


# ── Candidates markdown file (v4: deprecated no-op) ────────────────────────

def _write_candidates_file(candidates: list[dict]) -> None:
    """DEPRECATED no-op (v4, DESIGN-V4.md §3, item 4).

    Pre-v4 this wrote ~/.claude/cortex/auto-distill-candidates.md — a
    mailbox nobody read (§1 of DESIGN-V4.md: "era un buzón que nadie
    leía"). v4 promotion is a deterministic 4-criteria gate (see
    `auto_promote_to_law`); an instinct that doesn't meet it is simply not
    a candidate, full stop — there's nothing to review in a separate file.
    `run_auto_distill` still calls this (kept for call-site compatibility)
    but the body is now a no-op; any pre-existing candidates file is left
    untouched on disk for the operator to remove manually.
    """
    return


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


def prune_instinct_tracking(dry_run: bool = False) -> dict:
    """Drop instinct-tracking.json entries whose instinct no longer exists.

    injector-engine.js appends to this file on every PreToolUse match but
    never removes an entry when the backing YAML is archived, promoted to
    a law, or manually deleted — so the file grows with dead tracking data
    forever (P2 audit 2026-07-04). An id counts as "alive" if an active
    (non-archived) instinct YAML with that id exists in global/ or any
    projects/*/instincts/ — same definition _all_instinct_paths() already
    uses everywhere else in this module.

    Returns {"before": int, "after": int, "pruned": int}.
    """
    tracking = _load_instinct_tracking()
    if not tracking:
        return {"before": 0, "after": 0, "pruned": 0}

    alive_ids = {p.stem for p in _all_instinct_paths()}
    before = len(tracking)
    kept = {iid: rec for iid, rec in tracking.items() if iid in alive_ids}
    pruned = before - len(kept)

    if pruned and not dry_run:
        _atomic_write(INSTINCT_TRACKING_FILE, json.dumps(kept, indent=2, ensure_ascii=False) + "\n")
        _log_knowledge(
            "pruned-tracking", "-",
            f"removed {pruned} dead instinct-tracking.json entries (no backing yaml)",
            source="cx-auto-distill",
        )

    return {"before": before, "after": len(kept), "pruned": pruned}


def reap_stale_nudge_state(dry_run: bool = False) -> dict:
    """Un-cement saturated instincts stuck at NUDGE_MAX_CONF (0.99) forever.

    apply_outcome_nudges() (hooks/lib/impact_log.py) only advances an iid's
    nudge-state entry when a NEW outcome cohort arrives; a high-confidence
    instinct that stops generating fresh outcome feedback stays saturated
    at conf 0.99 with a frozen `last_direction: "saturated"` marker
    indefinitely (P2 audit 2026-07-04). This reaper, meant to be invoked
    from maintain alongside the rest of the auto-distill pipeline, applies
    a one-off -NUDGE_REAP_DECAY (0.10) to the backing instinct YAML's
    confidence and resets the nudge-state entry's direction so the
    instinct re-enters the normal decay/nudge cycle instead of being
    cemented, for any entry where:
      - last_event_ts is older than NUDGE_STALE_DAYS (60d), regardless of
        saturation, OR
      - last_direction == "saturated" AND last_nudge_ts is older than
        NUDGE_SATURATED_STALE_DAYS (7d)

    Reads/writes ~/.claude/cortex/nudge-state.json directly (own path
    constant, no import of impact_log) to keep this module's write
    surface self-contained; the schema (version 2, `iids: {<iid>: {...}}`)
    is impact_log.py's, treated here as a stable on-disk contract.

    Returns {"before": int, "reaped": int} where "before" is the number of
    entries considered saturated/stale-eligible before reaping.
    """
    if not NUDGE_STATE_FILE.exists():
        return {"before": 0, "reaped": 0}
    try:
        state = json.loads(NUDGE_STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"before": 0, "reaped": 0}
    if not isinstance(state, dict):
        return {"before": 0, "reaped": 0}
    iids_state = state.get("iids")
    if not isinstance(iids_state, dict) or not iids_state:
        return {"before": 0, "reaped": 0}

    now = _dt.datetime.now(_dt.timezone.utc)
    stale_cutoff = now - _dt.timedelta(days=NUDGE_STALE_DAYS)
    saturated_cutoff = now - _dt.timedelta(days=NUDGE_SATURATED_STALE_DAYS)

    def _parse_ts(raw: str) -> _dt.datetime | None:
        try:
            return _dt.datetime.strptime(raw[:19], "%Y-%m-%dT%H:%M:%S").replace(
                tzinfo=_dt.timezone.utc
            )
        except (ValueError, TypeError):
            return None

    eligible: list[str] = []
    for iid, rec in iids_state.items():
        if not isinstance(rec, dict):
            continue
        last_event = _parse_ts(str(rec.get("last_event_ts", "")))
        last_nudge = _parse_ts(str(rec.get("last_nudge_ts", "")))
        is_stale_event = last_event is not None and last_event < stale_cutoff
        is_stale_saturated = (
            str(rec.get("last_direction", "")) == "saturated"
            and last_nudge is not None
            and last_nudge < saturated_cutoff
        )
        if is_stale_event or is_stale_saturated:
            eligible.append(iid)

    before = len(eligible)
    if not eligible:
        return {"before": 0, "reaped": 0}

    reaped = 0
    if dry_run:
        return {"before": before, "reaped": 0}

    # Build an id → path index once, reusing the same discovery already
    # used for tracking/decay elsewhere in this module.
    path_by_id = {p.stem: p for p in _all_instinct_paths()}
    today_iso = now.isoformat()

    for iid in eligible:
        path = path_by_id.get(iid)
        if path is None:
            # No backing YAML (already archived/promoted) — just drop the
            # stale nudge-state entry, nothing to decay.
            iids_state.pop(iid, None)
            reaped += 1
            continue
        result = _read_instinct(path)
        if result is None:
            continue
        fields, text = result
        conf = fields.get("confidence")
        try:
            conf = float(conf)
        except (TypeError, ValueError):
            continue
        new_conf = max(0.0, round(conf - NUDGE_REAP_DECAY, 4))
        new_text = re.sub(
            r'^(confidence\s*:\s*)["\']?[\d.]+["\']?\s*$',
            lambda m: f"confidence: {new_conf:.4f}",
            text,
            count=1,
            flags=re.MULTILINE,
        )
        _atomic_write(path, new_text)
        iids_state[iid] = {
            **iids_state.get(iid, {}),
            "last_direction": "reaped",
            "last_nudge_ts": today_iso,
            "conf_at_last_nudge": new_conf,
        }
        _log_knowledge(
            "reaped-nudge", iid,
            f"conf {conf:.4f} → {new_conf:.4f} (stale nudge-state, -{NUDGE_REAP_DECAY:.2f})",
            source="cx-auto-distill",
        )
        reaped += 1

    if reaped:
        _save = json.dumps(state, indent=2, ensure_ascii=False) + "\n"
        _atomic_write(NUDGE_STATE_FILE, _save)

    return {"before": before, "reaped": reaped}


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
            tracking_prune_result = prune_instinct_tracking()
            if tracking_prune_result["pruned"] > 0:
                print(f"Pruned {tracking_prune_result['pruned']} dead instinct-tracking.json entries")
            reap_result = reap_stale_nudge_state()
            if reap_result["reaped"] > 0:
                print(f"Reaped {reap_result['reaped']} stale/saturated nudge-state entries")
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


def _cmd_prune_tracking(dry_run: bool) -> None:
    result = prune_instinct_tracking(dry_run=dry_run)
    prefix = "[DRY-RUN] " if dry_run else ""
    print(f"{prefix}instinct-tracking.json: {result['before']} → {result['after']} "
          f"({result['pruned']} pruned, no backing instinct)")


def _cmd_reap_nudges(dry_run: bool) -> None:
    result = reap_stale_nudge_state(dry_run=dry_run)
    prefix = "[DRY-RUN] " if dry_run else ""
    print(f"{prefix}nudge-state.json: {result['before']} stale/saturated entr"
          f"{'y' if result['before'] == 1 else 'ies'} found, {result['reaped']} reaped "
          f"(-{NUDGE_REAP_DECAY:.2f} conf, direction reset)")


def _cmd_law_audit(as_json: bool) -> None:
    result = law_audit()
    if as_json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return
    laws = result["laws"]
    print(f"Law audit ({result['as_of']}) — {len(laws)} active law(s), "
          f"written to {LAW_AUDIT_FILE}:")
    for entry in laws:
        dup = "DUP-INSTINCT" if entry["dup_active_instinct"] else ""
        noise = "n/a" if entry["backing_instinct_noise"] is None else f"{entry['backing_instinct_noise']:.2f}"
        print(f"  {entry['id']} [{entry['tier']}] age={entry['age_days']}d "
              f"noise_ratio={noise} {dup}".rstrip())


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


def backfill_session_data(dry_run: bool = True) -> dict:
    """v3.33.0 C5: normalize session fields + selectively rebuild tracking sessions.

    v3.35.0 / issue #49: when ``dry_run=False`` the write path takes the
    shared cross-runtime lock (``HISTORY_LOCK_FILE``) so the Node Stop hook
    cannot append to ``proposals-history.jsonl`` or flush
    ``instinct-tracking.json`` between our stat-guard and ``os.replace``.
    Both files use the SAME lock — they belong to one critical section in
    the Stop hook flow. Tracking now has a (size, mtime_ns) guard too (P2
    of #49).
    """
    history = _load_proposals_history()
    tracking = _load_instinct_tracking()
    raw_history_lines: list[str] = []
    history_stat_before: tuple[int, int] | None = None
    tracking_stat_before: tuple[int, int] | None = None
    if PROPOSALS_HISTORY_FILE.exists():
        st = PROPOSALS_HISTORY_FILE.stat()
        history_stat_before = (st.st_size, st.st_mtime_ns)
        with open(PROPOSALS_HISTORY_FILE, encoding="utf-8") as fh:
            raw_history_lines = fh.read().splitlines()
    if INSTINCT_TRACKING_FILE.exists():
        st = INSTINCT_TRACKING_FILE.stat()
        tracking_stat_before = (st.st_size, st.st_mtime_ns)

    def _sessions_by_source(items: list[dict]) -> dict[str, int]:
        out: dict[str, set[str]] = {}
        for e in items:
            if not isinstance(e, dict):
                continue
            src = str(e.get("source", "")).strip()
            sid = _proposal_session(e)
            if not src or not sid:
                continue
            out.setdefault(src, set()).add(sid)
        return {k: len(v) for k, v in out.items()}

    before_sessions = _sessions_by_source(history)

    normalized = 0
    normalized_history: list[dict] = []
    for entry in history:
        if not isinstance(entry, dict):
            normalized_history.append(entry)
            continue
        current = dict(entry)
        if not current.get("session_id"):
            legacy = str(current.get("session", "")).strip()
            if legacy:
                current["session_id"] = legacy
                normalized += 1
        normalized_history.append(current)

    conf_by_iid: dict[str, float] = {}
    for path in _all_instinct_paths():
        parsed = _read_instinct(path)
        if not parsed:
            continue
        fields, _ = parsed
        iid = str(fields.get("id", "")).strip()
        if not iid:
            continue
        try:
            conf_by_iid[iid] = float(fields.get("confidence", 0.0))
        except (TypeError, ValueError):
            conf_by_iid[iid] = 0.0

    accepted_by_iid: dict[str, list[dict]] = {}
    for entry in normalized_history:
        if not isinstance(entry, dict) or entry.get("status") != "accepted":
            continue
        iid = str(entry.get("id", "")).strip()
        if iid:
            accepted_by_iid.setdefault(iid, []).append(entry)

    rebuilt = 0
    eligible = 0
    if isinstance(tracking, dict):
        for iid, entry in tracking.items():
            if not isinstance(entry, dict) or entry.get("sessions") != []:
                continue
            accepted = accepted_by_iid.get(iid, [])
            distinct = []
            seen = set()
            for item in accepted:
                sid = _proposal_session(item)
                if sid and sid not in seen:
                    seen.add(sid)
                    distinct.append(sid)
            distinct = distinct[-20:]
            if len(distinct) < LAW_MIN_DISTINCT_SESSIONS:
                continue
            if conf_by_iid.get(iid, 0.0) < LAW_THRESHOLD_CONF:
                continue
            source = str(accepted[0].get("source", "")).strip() if accepted else ""
            reviewed = [
                p for p in normalized_history
                if isinstance(p, dict)
                and p.get("source") == source
                and p.get("status") in ("accepted", "rejected")
            ]
            if _count_critical_rejections(reviewed) != 0:
                continue
            entry["sessions"] = distinct
            rebuilt += 1
            eligible += 1

    after_sessions = _sessions_by_source(normalized_history)
    backup_dir = CORTEX_DIR / "archive" / f"backfill-{_dt.datetime.now(_dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    backup_files: list[str] = []
    wrote_history = False
    wrote_tracking = False

    if not dry_run:
        backup_dir.mkdir(parents=True, exist_ok=True)
        if PROPOSALS_HISTORY_FILE.exists():
            dst = backup_dir / PROPOSALS_HISTORY_FILE.name
            shutil.copy2(PROPOSALS_HISTORY_FILE, dst)
            backup_files.append(str(dst))
        if INSTINCT_TRACKING_FILE.exists():
            dst = backup_dir / INSTINCT_TRACKING_FILE.name
            shutil.copy2(INSTINCT_TRACKING_FILE, dst)
            backup_files.append(str(dst))

        # Issue #49 — acquire the cross-runtime lock BEFORE the stat re-check
        # so the Node Stop hook cannot append/flush between the check and our
        # os.replace. Backfill is operator-driven and rare; 15 s timeout is
        # plenty (the Stop hook critical section is <50 ms typically).
        lock_token = _file_lock.acquire(str(HISTORY_LOCK_FILE), timeout_ms=15000, stale_ms=30000)
        if lock_token is None:
            raise RuntimeError(
                "backfill: could not acquire proposals-history.lock within 15s; "
                "another writer (Stop hook or concurrent backfill) is active — retry later"
            )

        try:
            # AD P1-2 fix: validate BOTH guards before any os.replace, then
            # apply history first and tracking second; if the tracking
            # replace fails, restore history from the backup we copied above
            # so we never leave the pair in an inconsistent state.

            history_payload: str | None = None
            tracking_payload: str | None = None

            if normalized != 0:
                PROPOSALS_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
                out_lines: list[str] = []
                for idx, line in enumerate(raw_history_lines):
                    # AD P0-2 fix: refresh the lock mtime every 1000 lines so a
                    # large-corpus backfill does not look stale to a concurrent
                    # stealer after stale_ms.
                    if idx and idx % 1000 == 0:
                        _file_lock.refresh(lock_token)
                    if not line.strip():
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        out_lines.append(line)
                        continue
                    if not isinstance(obj, dict):
                        out_lines.append(line)
                        continue
                    if obj.get("session_id"):
                        out_lines.append(line)
                        continue
                    legacy = str(obj.get("session", "")).strip()
                    if not legacy:
                        out_lines.append(line)
                        continue
                    updated = dict(obj)
                    updated["session_id"] = legacy
                    out_lines.append(json.dumps(updated, ensure_ascii=False))
                history_payload = ("\n".join(out_lines) + "\n") if out_lines else ""

            if rebuilt != 0:
                INSTINCT_TRACKING_FILE.parent.mkdir(parents=True, exist_ok=True)
                tracking_payload = json.dumps(tracking, indent=2, ensure_ascii=False) + "\n"

            # Re-stat both files under the lock — belt + suspenders for any
            # writer that bypassed the lock (e.g. a stale legacy install).
            if history_payload is not None and history_stat_before is not None:
                if not PROPOSALS_HISTORY_FILE.exists():
                    raise RuntimeError("backfill: history changed during run, aborted — no data written; re-run")
                st_now = PROPOSALS_HISTORY_FILE.stat()
                if (st_now.st_size, st_now.st_mtime_ns) != history_stat_before:
                    raise RuntimeError("backfill: history changed during run, aborted — no data written; re-run")
            if tracking_payload is not None and tracking_stat_before is not None:
                if not INSTINCT_TRACKING_FILE.exists():
                    raise RuntimeError("backfill: tracking changed during run, aborted — no data written; re-run")
                st_now = INSTINCT_TRACKING_FILE.stat()
                if (st_now.st_size, st_now.st_mtime_ns) != tracking_stat_before:
                    raise RuntimeError("backfill: tracking changed during run, aborted — no data written; re-run")

            if history_payload is not None:
                _atomic_write(PROPOSALS_HISTORY_FILE, history_payload)
                wrote_history = True

            if tracking_payload is not None:
                try:
                    _atomic_write(INSTINCT_TRACKING_FILE, tracking_payload)
                    wrote_tracking = True
                except Exception:
                    # AD P1-2: tracking write failed AFTER history was already
                    # replaced. Restore history from the backup so the pair
                    # stays consistent, then re-raise.
                    if wrote_history:
                        hist_backup = backup_dir / PROPOSALS_HISTORY_FILE.name
                        if hist_backup.exists():
                            try:
                                shutil.copy2(hist_backup, PROPOSALS_HISTORY_FILE)
                                wrote_history = False
                            except OSError:
                                # AD round 3 P2 (accepted, documented risk):
                                # double fault — tracking write failed AND the
                                # history restore failed. History is now the
                                # new content while tracking is unchanged
                                # (slightly inconsistent pair). This requires
                                # two simultaneous disk faults; the pre-write
                                # backup remains in `backup_dir` for manual
                                # recovery. Re-raise the original failure.
                                pass
                    raise
        finally:
            _file_lock.release(lock_token)

    return {
        "dry_run": dry_run,
        "normalized": normalized,
        "tracking_rebuilt": rebuilt,
        "newly_eligible": eligible,
        "before_distinct_sessions_by_source": before_sessions,
        "after_distinct_sessions_by_source": after_sessions,
        "backup_dir": str(backup_dir),
        "backup_files": backup_files,
        "wrote_history": wrote_history,
        "wrote_tracking": wrote_tracking,
    }


def _cmd_backfill(apply: bool) -> None:
    # v3.35.0 / issue #49: --apply is now safe to run. The write path takes
    # the shared cross-runtime HISTORY_LOCK_FILE so the Node Stop hook
    # (proposals-storage._appendHistory + session-learner._flushTracking)
    # cannot interleave with our os.replace. Re-stat-under-lock + atomic
    # write give us belt + suspenders. Backup copies of both files land in
    # CORTEX_DIR/archive/backfill-<ISO> before any write.
    out = backfill_session_data(dry_run=not apply)
    prefix = "" if apply else "[DRY-RUN] "
    label = "Backfill applied:" if apply else "Backfill preview (no files written):"
    print(f"{prefix}{label}")
    print(f"  normalized       : {out['normalized']}")
    print(f"  tracking_rebuilt : {out['tracking_rebuilt']}")
    print(f"  newly_eligible   : {out['newly_eligible']}")
    if apply:
        print(f"  wrote_history    : {out['wrote_history']}")
        print(f"  wrote_tracking   : {out['wrote_tracking']}")
        if out.get("backup_files"):
            print(f"  backup_dir       : {out['backup_dir']}")


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

    p_prune_tracking = sub.add_parser(
        "prune-tracking",
        help="Remove instinct-tracking.json entries with no backing instinct YAML",
    )
    p_prune_tracking.add_argument("--dry-run", action="store_true")

    p_reap_nudges = sub.add_parser(
        "reap-nudges",
        help="Decay stale/saturated nudge-state.json entries so they re-enter the nudge cycle",
    )
    p_reap_nudges.add_argument("--dry-run", action="store_true")

    p_law_audit = sub.add_parser(
        "law-audit",
        help="Post-promotion audit of active laws (tier, age, dup instinct, noise ratio)",
    )
    p_law_audit.add_argument(
        "--json", dest="as_json", action="store_true",
        help="Machine-readable JSON output",
    )

    p_backfill = sub.add_parser("backfill", help="Recover legacy session_id/session fields and rebuild tracking sessions (preview by default; --apply writes)")
    p_backfill.add_argument("--apply", action="store_true", help="Write changes (atomically + cross-runtime locked since v3.35.0 / issue #49)")

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
    elif args.cmd == "prune-tracking":
        _cmd_prune_tracking(args.dry_run)
    elif args.cmd == "reap-nudges":
        _cmd_reap_nudges(args.dry_run)
    elif args.cmd == "law-audit":
        _cmd_law_audit(args.as_json)
    elif args.cmd == "backfill":
        _cmd_backfill(args.apply)
    elif args.cmd == "status":
        _cmd_status()
    elif args.cmd == "pipeline-stats":
        _cmd_pipeline_stats(days=args.days, as_json=args.as_json)

    return 0


if __name__ == "__main__":
    sys.exit(main())
