#!/usr/bin/env python3
"""
impact_log.py — Impact funnel writer + metrics computation.

Events in ~/.claude/cortex/impact.jsonl (one JSON per line):
  {"v":1,"ts":"...","ev":"inject","iid":"...","tool":"...","pid":"...","sid":"...","conf":0.75}
  {"v":1,"ts":"...","ev":"follow","iid":"...","sid":"...","followed":true,"err_after":false,"win":3}
  {"v":1,"ts":"...","ev":"reject","iid":"...","sid":"...","reason":"unrelated"}
  {"v":1,"ts":"...","ev":"feedback","iid":"...","sid":"...","rating":"useful"}
  {"v":1,"ts":"...","ev":"outcome","iid":"...","sid":"...","error_within_10":false}

Canonical metrics (see docs/IMPACT-METRICS.md):
  useful_event = (feedback.rating == "useful")
               OR (follow.followed == true AND follow.err_after == false)
  noise_event  = (feedback.rating == "noise")
               OR (follow.followed == false AND reject.reason == "unrelated")
  useful_ratio = count(useful) / count(inject)
  noise_ratio  = count(noise)  / count(inject)
  health_ratio = useful_ratio / max(noise_ratio, 0.01)

CLI:
  python3 impact_log.py stats [--days N] [--json]
  python3 impact_log.py tail [-n N]
  python3 impact_log.py rotate
  python3 impact_log.py log --event inject --iid <id> --tool Bash --sid <sid>
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

CORTEX_DIR = Path(os.environ.get("CORTEX_DIR", str(Path.home() / ".claude" / "cortex")))
IMPACT_FILE = CORTEX_DIR / "impact.jsonl"
FEEDBACK_FILE = CORTEX_DIR / "feedback.jsonl"
ARCHIVE_DIR = CORTEX_DIR / "impact.archive"
ROTATION_DAYS = 30

# Events with `follow` are emitted by session-learner after reconstructing
# the "did the next tool call respect the instinct?" signal.
VALID_EVENTS = {"inject", "follow", "reject", "feedback", "outcome"}
VALID_RATINGS = {"useful", "noise", "ignore"}
VALID_SOURCES = {"user", "agent"}
DEFAULT_SOURCE = "user"


# ── writer ──────────────────────────────────────────────────────────────────

def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _atomic_append(path: Path, line: str) -> None:
    """Append one line atomically. Best-effort lock via O_APPEND (POSIX) / exclusive open retry (Windows)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = line.rstrip("\n") + "\n"
    for attempt in range(5):
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(data)
            return
        except OSError:
            time.sleep(0.05 * (attempt + 1))
    # Last-resort silent fail — impact logging must never block the session.
    sys.stderr.write(f"[cortex:impact_log] failed to append to {path}\n")


def log_event(event: str, **fields: Any) -> None:
    """Append one canonical impact event."""
    if event not in VALID_EVENTS:
        raise ValueError(f"invalid event {event!r}; expected one of {VALID_EVENTS}")
    payload: dict[str, Any] = {"v": SCHEMA_VERSION, "ts": _now_iso(), "ev": event}
    for key, value in fields.items():
        if value is None:
            continue
        payload[key] = value
    _atomic_append(IMPACT_FILE, json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def _normalize_iid(iid: str) -> str:
    """v3.19.4: auto-correct the `reflex-<id>` typo to canonical `reflex:<id>`.

    Inject events use `reflex:<id>` (colon) as the canonical form. Pre-v3.19.4 the
    `/cx-feedback-auto` command and ad-hoc CLI users sometimes wrote `reflex-<id>`
    (hyphen), which split the impact dashboard into two phantom rows per reflex
    and prevented top-useful/top-noise rankings from aggregating correctly.
    """
    if isinstance(iid, str) and iid.startswith("reflex-"):
        # Only rewrite when the segment after "reflex-" matches a known reflex id
        # shape (alphanum + dashes). Anything else stays untouched so genuine ids
        # like `reflex-auto-disable` (knowledge-log marker) are not mangled.
        candidate = "reflex:" + iid[len("reflex-"):]
        sys.stderr.write(
            f"[cortex:impact_log] normalizing iid {iid!r} -> {candidate!r}\n"
        )
        return candidate
    return iid


def log_feedback(
    instinct_id: str,
    rating: str,
    sid: str | None = None,
    note: str | None = None,
    source: str = DEFAULT_SOURCE,
) -> None:
    """Convenience shortcut invoked by /cx-feedback and /cx-feedback-auto.

    `source` distinguishes human ratings (`user`, default) from agent self-ratings
    (`agent`). Sprint 0.5 Gate uses only `useful_ratio_user`. See docs/AGENT-FEEDBACK.md.
    """
    if rating not in VALID_RATINGS:
        raise ValueError(f"rating must be one of {VALID_RATINGS}")
    if source not in VALID_SOURCES:
        raise ValueError(f"source must be one of {VALID_SOURCES}")
    instinct_id = _normalize_iid(instinct_id)
    log_event("feedback", iid=instinct_id, sid=sid, rating=rating, note=note, source=source)
    # Also mirror to feedback.jsonl for quick sampling (doesn't need mixing with funnel events).
    _atomic_append(
        FEEDBACK_FILE,
        json.dumps(
            {
                "v": SCHEMA_VERSION,
                "ts": _now_iso(),
                "iid": instinct_id,
                "sid": sid,
                "rating": rating,
                "note": note,
                "source": source,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        ),
    )


# ── reader ──────────────────────────────────────────────────────────────────

def _iter_events(path: Path = IMPACT_FILE, since_days: int | None = None):
    if not path.exists():
        return
    cutoff: _dt.datetime | None = None
    if since_days is not None:
        cutoff = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=since_days)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
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
                    when = _dt.datetime.strptime(ts_raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=_dt.timezone.utc)
                except ValueError:
                    continue
                if when < cutoff:
                    continue
            yield obj


def compute_metrics(days: int = 14) -> dict[str, Any]:
    """
    Canonical metrics. Returns a dict ready to print or JSON-serialize.

    Splits feedback events by `source` ("user" vs "agent"). Sprint 0.5 Gate
    reads only the `_user` ratios; `_agent` ratios are diagnostic. See
    docs/AGENT-FEEDBACK.md for rationale.

    Output shape:
      {
        "period_days": 14,
        "totals": {"inject": N, "follow": M, ...},
        "useful_events": X,           # legacy aggregate
        "noise_events": Y,            # legacy aggregate
        "useful_ratio": 0.00-1.00,    # legacy aggregate (user+agent)
        "noise_ratio":  0.00-1.00,
        "health_ratio": 0.00-inf,
        "useful_ratio_user":  0.00-1.00,
        "noise_ratio_user":   0.00-1.00,
        "health_ratio_user":  0.00-inf,
        "useful_ratio_agent": 0.00-1.00,
        "noise_ratio_agent":  0.00-1.00,
        "health_ratio_agent": 0.00-inf,
        "top_useful":   [(iid, count), ...],
        "top_noisy":    [(iid, count), ...],
      }
    """
    counts: dict[str, int] = {k: 0 for k in VALID_EVENTS}
    per_instinct_useful: dict[str, int] = {}
    per_instinct_noise: dict[str, int] = {}

    # Split tallies by source. Implicit follow/reject events count as `user`
    # because they reflect the user's actual next action.
    useful_user = 0
    useful_agent = 0
    noise_user = 0
    noise_agent = 0

    for ev in _iter_events(since_days=days):
        kind = ev.get("ev")
        if kind in counts:
            counts[kind] += 1
        iid = ev.get("iid")
        if not iid:
            continue

        useful_hit = False
        noise_hit = False
        # Pre-v3.17.0 events lack `source`; default to user for back-compat.
        source = ev.get("source", DEFAULT_SOURCE)
        if source not in VALID_SOURCES:
            source = DEFAULT_SOURCE

        if kind == "feedback":
            rating = ev.get("rating")
            if rating == "useful":
                useful_hit = True
            elif rating == "noise":
                noise_hit = True
        elif kind == "follow":
            # Follow events are derived from the user's next tool call.
            source = "user"
            if ev.get("followed") is True and not ev.get("err_after"):
                useful_hit = True
            elif ev.get("followed") is False:
                noise_hit = True
        elif kind == "reject":
            source = "user"
            noise_hit = True

        if useful_hit:
            per_instinct_useful[iid] = per_instinct_useful.get(iid, 0) + 1
            if source == "agent":
                useful_agent += 1
            else:
                useful_user += 1
        if noise_hit:
            per_instinct_noise[iid] = per_instinct_noise.get(iid, 0) + 1
            if source == "agent":
                noise_agent += 1
            else:
                noise_user += 1

    inject_total = counts["inject"] or 1  # avoid zero-division
    has_inject = bool(counts["inject"])
    useful_total = sum(per_instinct_useful.values())
    noise_total = sum(per_instinct_noise.values())

    useful_ratio = useful_total / inject_total if has_inject else 0.0
    noise_ratio = noise_total / inject_total if has_inject else 0.0
    health_ratio = useful_ratio / max(noise_ratio, 0.01)

    useful_ratio_user = useful_user / inject_total if has_inject else 0.0
    noise_ratio_user = noise_user / inject_total if has_inject else 0.0
    health_ratio_user = useful_ratio_user / max(noise_ratio_user, 0.01)

    useful_ratio_agent = useful_agent / inject_total if has_inject else 0.0
    noise_ratio_agent = noise_agent / inject_total if has_inject else 0.0
    health_ratio_agent = useful_ratio_agent / max(noise_ratio_agent, 0.01)

    top_useful = sorted(per_instinct_useful.items(), key=lambda kv: -kv[1])[:10]
    top_noisy = sorted(per_instinct_noise.items(), key=lambda kv: -kv[1])[:10]

    return {
        "period_days": days,
        "totals": counts,
        "useful_events": useful_total,
        "noise_events": noise_total,
        "useful_ratio": round(useful_ratio, 4),
        "noise_ratio": round(noise_ratio, 4),
        "health_ratio": round(health_ratio, 4),
        "useful_ratio_user": round(useful_ratio_user, 4),
        "noise_ratio_user": round(noise_ratio_user, 4),
        "health_ratio_user": round(health_ratio_user, 4),
        "useful_ratio_agent": round(useful_ratio_agent, 4),
        "noise_ratio_agent": round(noise_ratio_agent, 4),
        "health_ratio_agent": round(health_ratio_agent, 4),
        "top_useful": top_useful,
        "top_noisy": top_noisy,
    }


def gate_recommendation(metrics: dict[str, Any]) -> str:
    """GO/PARTIAL/NO-GO per the Sprint 0.5 gate in the v4.0 plan.

    Uses `useful_ratio_user` and `health_ratio_user` (v3.17.0+). Agent
    self-ratings are excluded from gate input by design — see
    docs/AGENT-FEEDBACK.md.
    """
    ur = metrics.get("useful_ratio_user", metrics["useful_ratio"])
    hr = metrics.get("health_ratio_user", metrics["health_ratio"])
    if ur >= 0.25 and hr >= 1.5:
        return "GO"
    if ur >= 0.10 or hr >= 1.0:
        return "PARTIAL"
    return "NO-GO"


# ── outcome ranking (Sprint 5, v3.20.0) ─────────────────────────────────────

NUDGE_BOOST_RATIO = 0.85   # ratio at/above which an iid earns +0.05 confidence
NUDGE_DECAY_RATIO = 0.30   # ratio at/below which an iid loses 0.05 confidence
NUDGE_DELTA = 0.05
NUDGE_MIN_CONF = 0.10
NUDGE_MAX_CONF = 0.99
NUDGE_MIN_OUTCOMES = 5     # require >=N outcome events before nudging


def compute_outcome_ranking(days: int = 14, min_outcomes: int = NUDGE_MIN_OUTCOMES) -> dict:
    """Per-iid outcome cleanliness ratio + suggested confidence nudge.

    For each iid that emitted at least `min_outcomes` outcome events in the
    window, compute:
      outcome_clean_ratio = count(error_within_10 == False) / count(outcome)

    And map ratio → nudge:
      ratio >= NUDGE_BOOST_RATIO  →  +NUDGE_DELTA  (confidence boost candidate)
      ratio <= NUDGE_DECAY_RATIO  →  -NUDGE_DELTA  (confidence decay candidate)
      otherwise                   →  0             (held — no signal yet)

    Returns:
      {
        "<iid>": {
          "outcome_total": int,
          "outcome_clean": int,    # error_within_10 == False
          "outcome_error": int,    # error_within_10 == True
          "ratio": float,          # 0.00-1.00
          "nudge": float,          # -NUDGE_DELTA, 0, +NUDGE_DELTA
        },
        ...
      }
    """
    per_iid: dict[str, dict] = {}
    for ev in _iter_events(since_days=days):
        if ev.get("ev") != "outcome":
            continue
        iid = ev.get("iid")
        if not iid:
            continue
        bucket = per_iid.setdefault(
            iid, {"outcome_total": 0, "outcome_clean": 0, "outcome_error": 0}
        )
        bucket["outcome_total"] += 1
        if ev.get("error_within_10") is True:
            bucket["outcome_error"] += 1
        else:
            bucket["outcome_clean"] += 1

    rankings: dict[str, dict] = {}
    for iid, b in per_iid.items():
        if b["outcome_total"] < min_outcomes:
            continue
        ratio = b["outcome_clean"] / b["outcome_total"]
        if ratio >= NUDGE_BOOST_RATIO:
            nudge = NUDGE_DELTA
        elif ratio <= NUDGE_DECAY_RATIO:
            nudge = -NUDGE_DELTA
        else:
            nudge = 0.0
        rankings[iid] = {
            **b,
            "ratio": round(ratio, 4),
            "nudge": nudge,
        }
    return rankings


# ── nudge application — instinct YAML frontmatter (Sprint 5) ────────────────

# Match `confidence: 0.XY` in YAML frontmatter, with optional quotes.
_CONF_RE = re.compile(
    r'^(?P<lead>confidence\s*:\s*)["\']?(?P<val>\d+(?:\.\d+)?)["\']?\s*$',
    re.MULTILINE,
)
_ID_RE = re.compile(
    r'^id\s*:\s*["\']?(?P<val>[^"\'\n]+?)["\']?\s*$',
    re.MULTILINE,
)


def _instinct_yaml_paths():
    """Yield Path of every instinct YAML known to this Cortex install."""
    global_dir = CORTEX_DIR / "instincts" / "global"
    if global_dir.is_dir():
        for p in sorted(global_dir.glob("*.yaml")):
            yield p
    projects_dir = CORTEX_DIR / "projects"
    if projects_dir.is_dir():
        for proj in sorted(projects_dir.iterdir()):
            inst_dir = proj / "instincts"
            if inst_dir.is_dir():
                for p in sorted(inst_dir.glob("*.yaml")):
                    yield p


def _read_yaml_id_and_conf(path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None, None, None
    if not text.startswith("---"):
        return None, None, text
    end = text.find("---", 3)
    if end < 0:
        return None, None, text
    front = text[3:end]
    iid_m = _ID_RE.search(front)
    conf_m = _CONF_RE.search(front)
    iid = iid_m.group("val").strip() if iid_m else None
    try:
        conf = float(conf_m.group("val")) if conf_m else None
    except ValueError:
        conf = None
    return iid, conf, text


def apply_outcome_nudges(rankings: dict, dry_run: bool = False) -> list[dict]:
    """Walk every instinct YAML and apply nudges from `rankings`.

    Reflex iids (`reflex:*`) are skipped — reflexes have their own
    enabled/usefulCount/noiseCount accounting, not a confidence field.

    Returns a list of {iid, path, before, after, nudge} for every change
    that was applied (or would be in dry-run).
    """
    applied: list[dict] = []
    for path in _instinct_yaml_paths():
        iid, conf, text = _read_yaml_id_and_conf(path)
        if not iid or conf is None:
            continue
        if iid.startswith("reflex:"):
            continue
        rec = rankings.get(iid)
        if not rec or not rec.get("nudge"):
            continue
        nudge = float(rec["nudge"])
        new_conf = max(NUDGE_MIN_CONF, min(NUDGE_MAX_CONF, conf + nudge))
        if abs(new_conf - conf) < 1e-6:
            continue
        applied.append(
            {"iid": iid, "path": str(path), "before": round(conf, 4),
             "after": round(new_conf, 4), "nudge": nudge}
        )
        if dry_run:
            continue
        new_text = _CONF_RE.sub(
            lambda m: f"{m.group('lead')}{new_conf:.4f}", text, count=1
        )
        tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
        tmp.write_text(new_text, encoding="utf-8")
        tmp.replace(path)
    return applied


def log_nudges_to_knowledge(applied: list[dict]) -> None:
    """Append one knowledge-log line per nudge."""
    if not applied:
        return
    log_path = CORTEX_DIR / "knowledge-log.md"
    today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
    lines = []
    for a in applied:
        lines.append(
            f"{today} | outcome-nudge | {a['iid']} | "
            f"conf {a['before']:.4f} → {a['after']:.4f} ({a['nudge']:+.2f}) | "
            f"impact-funnel\n"
        )
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.writelines(lines)


# ── rotation ────────────────────────────────────────────────────────────────

def rotate(days: int = ROTATION_DAYS) -> int:
    """Archive events older than `days`. Returns archived event count."""
    if not IMPACT_FILE.exists():
        return 0
    cutoff = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=days)
    kept: list[str] = []
    archived: list[str] = []
    with open(IMPACT_FILE, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw_strip = raw.strip()
            if not raw_strip:
                continue
            try:
                obj = json.loads(raw_strip)
                when = _dt.datetime.strptime(obj.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ").replace(
                    tzinfo=_dt.timezone.utc
                )
            except (json.JSONDecodeError, ValueError):
                kept.append(raw)
                continue
            if when < cutoff:
                archived.append(raw)
            else:
                kept.append(raw)

    if archived:
        ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
        stamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        archive_path = ARCHIVE_DIR / f"impact-{stamp}.jsonl"
        with open(archive_path, "w", encoding="utf-8") as fh:
            fh.writelines(archived)
        tmp = IMPACT_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.writelines(kept)
        tmp.replace(IMPACT_FILE)
    return len(archived)


# ── CLI ─────────────────────────────────────────────────────────────────────

def _print_stats(days: int, as_json: bool) -> None:
    metrics = compute_metrics(days=days)
    gate = gate_recommendation(metrics)
    if as_json:
        print(json.dumps({**metrics, "gate": gate}, indent=2, ensure_ascii=False))
        return

    print(f"\nIMPACT FUNNEL — last {metrics['period_days']} days")
    print("─" * 52)
    totals = metrics["totals"]
    print(f"  inject   events : {totals['inject']}")
    print(f"  follow   events : {totals['follow']}")
    print(f"  reject   events : {totals['reject']}")
    print(f"  feedback events : {totals['feedback']}")
    print(f"  outcome  events : {totals['outcome']}")
    print()
    print(f"  useful events   : {metrics['useful_events']}")
    print(f"  noise  events   : {metrics['noise_events']}")
    print(f"  useful_ratio    : {metrics['useful_ratio']:.4f}")
    print(f"  noise_ratio     : {metrics['noise_ratio']:.4f}")
    print(f"  health_ratio    : {metrics['health_ratio']:.4f}")
    print()
    print(f"  user  → useful_ratio: {metrics.get('useful_ratio_user', 0):.4f}  "
          f"noise_ratio: {metrics.get('noise_ratio_user', 0):.4f}  "
          f"health: {metrics.get('health_ratio_user', 0):.4f}")
    print(f"  agent → useful_ratio: {metrics.get('useful_ratio_agent', 0):.4f}  "
          f"noise_ratio: {metrics.get('noise_ratio_agent', 0):.4f}  "
          f"health: {metrics.get('health_ratio_agent', 0):.4f}")
    print()
    print(f"  Sprint 0.5 gate : {gate}  (uses _user ratios only)")
    print(f"    criteria      : GO ≥0.25·1.5  PARTIAL ≥0.10·1.0  NO-GO <0.10 or <1.0")
    print()
    if metrics["top_useful"]:
        print("  Top useful instincts:")
        for iid, count in metrics["top_useful"]:
            print(f"    {count:>4}  {iid}")
    if metrics["top_noisy"]:
        print("\n  Top noisy instincts (candidates to deprecate):")
        for iid, count in metrics["top_noisy"]:
            print(f"    {count:>4}  {iid}")
    if not metrics["top_useful"] and not metrics["top_noisy"] and not totals["inject"]:
        print("  No data yet. Run a few sessions and re-check.")


def _print_tail(n: int) -> None:
    if not IMPACT_FILE.exists():
        print(f"(no impact.jsonl at {IMPACT_FILE})")
        return
    lines = IMPACT_FILE.read_text(encoding="utf-8", errors="replace").splitlines()[-n:]
    for line in lines:
        print(line)


def _cli_log(args: argparse.Namespace) -> None:
    extra: dict[str, Any] = {}
    for key, value in vars(args).items():
        if key in {"cmd", "event"} or value is None:
            continue
        extra[key] = value
    log_event(args.event, **extra)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="impact_log", description="fs-cortex impact funnel tool")
    sub = parser.add_subparsers(dest="cmd", required=True)

    s_stats = sub.add_parser("stats", help="compute funnel metrics")
    s_stats.add_argument("--days", type=int, default=14)
    s_stats.add_argument("--json", action="store_true")

    s_tail = sub.add_parser("tail", help="show last N events")
    s_tail.add_argument("-n", type=int, default=20)

    sub.add_parser("rotate", help=f"archive events older than {ROTATION_DAYS} days")

    s_rank = sub.add_parser("outcome-ranking",
                            help="per-iid outcome cleanliness + suggested confidence nudge")
    s_rank.add_argument("--days", type=int, default=14)
    s_rank.add_argument("--min-outcomes", type=int, default=NUDGE_MIN_OUTCOMES)
    s_rank.add_argument("--json", action="store_true")

    s_nudge = sub.add_parser("outcome-nudge",
                             help="apply outcome-ranking nudges to instinct YAMLs (Sprint 5)")
    s_nudge.add_argument("--days", type=int, default=14)
    s_nudge.add_argument("--min-outcomes", type=int, default=NUDGE_MIN_OUTCOMES)
    s_nudge.add_argument("--apply", action="store_true",
                         help="actually write YAML changes (default: dry-run)")
    s_nudge.add_argument("--json", action="store_true")

    s_log = sub.add_parser("log", help="append one impact event (for scripts/tests)")
    s_log.add_argument("--event", required=True, choices=sorted(VALID_EVENTS))
    s_log.add_argument("--iid")
    s_log.add_argument("--tool")
    s_log.add_argument("--pid")
    s_log.add_argument("--sid")
    s_log.add_argument("--conf", type=float)
    s_log.add_argument("--followed", type=lambda x: x.lower() == "true")
    s_log.add_argument("--err_after", type=lambda x: x.lower() == "true")
    s_log.add_argument("--rating", choices=sorted(VALID_RATINGS))
    s_log.add_argument("--reason")
    s_log.add_argument("--note")
    s_log.add_argument("--source", choices=sorted(VALID_SOURCES),
                       help="Origin of the event (default: user; agent for /cx-feedback-auto)")

    args = parser.parse_args(argv)

    if args.cmd == "stats":
        _print_stats(args.days, args.json)
    elif args.cmd == "tail":
        _print_tail(args.n)
    elif args.cmd == "rotate":
        archived = rotate()
        print(f"archived {archived} events older than {ROTATION_DAYS} days")
    elif args.cmd == "outcome-ranking":
        rankings = compute_outcome_ranking(days=args.days, min_outcomes=args.min_outcomes)
        if args.json:
            print(json.dumps(rankings, indent=2, ensure_ascii=False))
        else:
            if not rankings:
                print(f"No iids met the min-outcomes={args.min_outcomes} bar in the last {args.days} days.")
            else:
                print(f"\nOUTCOME RANKING — last {args.days} days, min outcomes={args.min_outcomes}")
                print("─" * 70)
                items = sorted(rankings.items(), key=lambda kv: (-kv[1]["nudge"], -kv[1]["ratio"]))
                for iid, r in items:
                    print(f"  {r['outcome_clean']:>4}/{r['outcome_total']:<4} clean  "
                          f"ratio={r['ratio']:.4f}  nudge={r['nudge']:+.2f}  {iid}")
    elif args.cmd == "outcome-nudge":
        rankings = compute_outcome_ranking(days=args.days, min_outcomes=args.min_outcomes)
        applied = apply_outcome_nudges(rankings, dry_run=not args.apply)
        if args.apply and applied:
            log_nudges_to_knowledge(applied)
        if args.json:
            print(json.dumps({"applied": applied, "dry_run": not args.apply}, indent=2))
        else:
            tag = "would apply" if not args.apply else "applied"
            print(f"\n{tag} {len(applied)} nudge(s)")
            for a in applied:
                print(f"  {a['iid']:<45} {a['before']:.4f} → {a['after']:.4f}  ({a['nudge']:+.2f})")
            if not args.apply and applied:
                print("\n(dry-run — pass --apply to persist + log to knowledge-log.md)")
    elif args.cmd == "log":
        _cli_log(args)

    return 0


if __name__ == "__main__":
    sys.exit(main())
