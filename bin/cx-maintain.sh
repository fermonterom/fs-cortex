#!/usr/bin/env bash
# bin/cx-maintain.sh — Deterministic /cx-maintain pass, runnable WITHOUT an LLM.
#
# Same contract as commands/cx-maintain.md's Implementation block (Cortex v4,
# docs/DESIGN-V4.md §5): decay, archive, auto-validate, deterministic
# law-promotion, evolve-detect (engine pass) → Jaccard dedup by
# (scope, project_id, domain) → storage rotation → proposals↔instincts
# reconciliation → health check → .review-digest.json → .last-distill /
# .last-dream markers. Zero questions, zero LLM calls — safe for cron/launchd.
#
# This script MUST stay a byte-for-byte behavioral mirror of the Python
# heredoc in commands/cx-maintain.md. If that spec changes (new step, engine
# function rename, gate change), update both in the same commit — see
# instinct pattern-cortex-commands-md-features-pair.
#
# Usage:
#   bin/cx-maintain.sh              # full pass, writes state, prints report
#   bin/cx-maintain.sh --dry-run    # same computation, no writes anywhere
#
# Env overrides (mainly for tests — see tests/test_cx_maintain_runner.sh):
#   CORTEX_DIR       data dir, default ~/.claude/cortex
#   CORTEX_LIB_DIR   engine lib dir, default: installed hooks, falls back to
#                    the repo's own hooks/lib if not installed
#   CX_MAINTAIN_LOCK_STALE_SEC   seconds before a stale runner lock is stolen
#                                 (default 1800 = 30 min)
#
# macOS BSD `date`/`mktemp` compatible. No GNU-only flags used anywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CORTEX_DIR="${CORTEX_DIR:-$HOME/.claude/cortex}"

INSTALLED_LIB_DIR="$HOME/.claude/hooks/cortex/lib"
REPO_LIB_DIR="$REPO_ROOT/hooks/lib"
if [ -n "${CORTEX_LIB_DIR:-}" ]; then
  LIB_DIR="$CORTEX_LIB_DIR"
elif [ -f "$INSTALLED_LIB_DIR/distill_engine.py" ]; then
  LIB_DIR="$INSTALLED_LIB_DIR"
else
  LIB_DIR="$REPO_LIB_DIR"
fi

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

log "cx-maintain runner starting (dry_run=$DRY_RUN)"
log "CORTEX_DIR=$CORTEX_DIR"
log "LIB_DIR=$LIB_DIR"

if [ ! -f "$LIB_DIR/distill_engine.py" ]; then
  log "ERROR: distill_engine.py not found under $LIB_DIR (neither installed nor repo copy) — nothing to run"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  log "ERROR: python3 not found on PATH — cx-maintain requires it"
  exit 1
fi

mkdir -p "$CORTEX_DIR"

# ── Runner-level lock ────────────────────────────────────────────────────────
# Separate from distill_engine's own advisory flock (which only guards the
# engine-pass step). This one guards the WHOLE script against an overlapping
# cron/launchd invocation (e.g. a slow storage-rotation run still going when
# the next scheduled tick fires). Portable mkdir-based lock (atomic on every
# POSIX fs, no flock(1) needed — flock(1) does not ship on macOS).
LOCK_DIR="$CORTEX_DIR/.cx-maintain-runner.lock"
STALE_SEC="${CX_MAINTAIN_LOCK_STALE_SEC:-1800}"

release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Someone else holds it. Steal if stale (crashed run left it behind).
  lock_age=99999
  if [ -d "$LOCK_DIR" ]; then
    lock_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    lock_age=$(( now_epoch - lock_mtime ))
  fi
  if [ "$lock_age" -ge "$STALE_SEC" ]; then
    log "Stale runner lock (${lock_age}s old, >= ${STALE_SEC}s) — stealing"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null || { log "Could not steal lock — another run just started, skipping"; exit 0; }
  else
    log "Another cx-maintain runner is active (lock ${lock_age}s old) — skipping this run, safe to rerun later"
    exit 0
  fi
fi
trap release_lock EXIT

set +e
CORTEX_DIR="$CORTEX_DIR" LIB_DIR="$LIB_DIR" DRY_RUN="$DRY_RUN" python3 - <<'PYEOF'
import json, os, re, sys, time
from datetime import date, datetime, timezone
from pathlib import Path

CORTEX_DIR = Path(os.environ["CORTEX_DIR"])
LIB_DIR = os.environ["LIB_DIR"]
DRY_RUN = os.environ.get("DRY_RUN") == "1"

sys.path.insert(0, LIB_DIR)

report = {"steps": [], "errors": []}

def step(name):
    def deco(fn):
        try:
            out = fn()
            report["steps"].append({"name": name, "ok": True, "detail": out})
        except Exception as e:
            report["steps"].append({"name": name, "ok": False, "detail": str(e)})
            report["errors"].append(f"{name}: {e}")
        return report["steps"][-1]
    return deco

# ── Step 1: engine pass (decay + purge + auto-validate + promote + evolve) ──
# All under distill_engine's own lock so this never races SessionStart's
# daily auto-distill or session-learner.js's Stop hook. Calls the SAME
# public functions run_auto_distill() calls internally, but bypasses its
# 24h rate limiter — a deliberate /cx-maintain run should always execute,
# not silently no-op because SessionStart already ran today.
decayed = archived = promoted = candidates = []
validated = skipped_validate = evolve_drafts = 0
engine_ok = False
try:
    import distill_engine as de
    lock_fh, acquired = de._lock_acquire(nonblocking=True)
    if not acquired:
        report["steps"].append({"name": "engine-pass", "ok": False,
                                 "detail": "lock busy (another distill process running) — skipped, safe to rerun"})
    else:
        try:
            decayed = de.apply_decay(dry_run=DRY_RUN)
            archived = de.archive_decayed(dry_run=DRY_RUN)
            validate_result = de.auto_validate_proposals(dry_run=DRY_RUN)
            validated = len(validate_result.get("accepted", []))
            skipped_validate = len(validate_result.get("skipped", []))
            promoted, candidates = de.auto_promote_to_law(dry_run=DRY_RUN)
            evolve_result = de.auto_evolve_detect(dry_run=DRY_RUN)
            evolve_drafts = len(evolve_result.get("drafts_generated", []))
            engine_ok = True
            report["steps"].append({"name": "engine-pass", "ok": True, "detail":
                f"decayed={len(decayed)} archived={len(archived)} validated={validated} "
                f"skipped_validate={skipped_validate} promoted={len(promoted)} "
                f"candidates={len(candidates)} evolve_drafts={evolve_drafts}"})
        finally:
            de._lock_release(lock_fh)
except Exception as e:
    report["steps"].append({"name": "engine-pass", "ok": False, "detail": str(e)})
    report["errors"].append(f"engine-pass: {e}")

# ── Step 2: dedup Jaccard (dream_cycle.dedup_instincts, threshold 0.80) ──
# Groups by (scope, project_id, domain) so global instincts never dedup
# against project-scoped ones and unrelated domains never collide. Archives
# the losers using the SAME convention as archive_decayed (rename into a
# sibling archive/ dir), so they stay recoverable, not deleted.
dedup_archived = []
try:
    import distill_engine as de
    import dream_cycle as dc
    groups = {}
    for path in de._all_instinct_paths():
        result = de._read_instinct(path)
        if result is None:
            continue
        fields, _text = result
        key = (fields.get("scope", "?"), fields.get("project_id", "?"), fields.get("domain", "?"))
        groups.setdefault(key, []).append({
            "id": fields.get("id", path.stem),
            "action": fields.get("action", ""),
            "confidence": float(fields.get("confidence", 0) or 0),
            "_path": path,
        })
    for key, items in groups.items():
        if len(items) < 2:
            continue
        kept = dc.dedup_instincts(items, threshold=0.80)
        kept_ids = {k["id"] for k in kept}
        for it in items:
            if it["id"] in kept_ids:
                continue
            if not DRY_RUN:
                dest_dir = it["_path"].parent / "archive"
                dest_dir.mkdir(parents=True, exist_ok=True)
                it["_path"].rename(dest_dir / it["_path"].name)
                de._log_knowledge("dedup-archived", it["id"],
                                   f"jaccard>=0.80 duplicate within domain={key[2]}", source="cx-maintain")
            dedup_archived.append(it["id"])
    report["steps"].append({"name": "dedup-jaccard", "ok": True,
                             "detail": f"archived {len(dedup_archived)} duplicate(s): {dedup_archived[:10]}"})
except Exception as e:
    report["steps"].append({"name": "dedup-jaccard", "ok": False, "detail": str(e)})
    report["errors"].append(f"dedup-jaccard: {e}")

# ── Step 3: storage rotation (storage-rotation.js, size+marker gated) ──
rotation_out = ""
try:
    import subprocess
    node_snippet = (
        "const r=require(process.env.LIB_DIR+'/storage-rotation.js');"
        "const lines=[];"
        "r.maybeRotateStorage(l=>lines.push(l));"
        "console.log(JSON.stringify(lines));"
    )
    env = dict(os.environ)
    if not DRY_RUN:
        cp = subprocess.run(["node", "-e", node_snippet], env=env,
                             capture_output=True, text=True, timeout=30)
        rotation_out = cp.stdout.strip() or cp.stderr.strip()
    else:
        rotation_out = "(dry-run: rotation skipped)"
    report["steps"].append({"name": "storage-rotation", "ok": True, "detail": rotation_out})
except Exception as e:
    report["steps"].append({"name": "storage-rotation", "ok": False, "detail": str(e)})
    report["errors"].append(f"storage-rotation: {e}")

# ── Step 4: reconciliation proposals-history ↔ instincts ──
# If the LATEST known status for a proposal id is "rejected" (checked across
# proposals-history.jsonl in append order, then proposals.json for any live
# leftovers) but an ACTIVE instinct YAML with that id still exists, archive
# it. Closes the gap left by the deprecated /cx-downvote (no longer wired to
# archival) and by any manual proposals.json edits.
reconciled = []
try:
    import distill_engine as de
    latest_status = {}
    hist_file = CORTEX_DIR / "proposals-history.jsonl"
    if hist_file.exists():
        with open(hist_file, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                pid = obj.get("id")
                if pid:
                    latest_status[pid] = obj.get("status")
    props_file = CORTEX_DIR / "proposals.json"
    if props_file.exists():
        try:
            arr = json.loads(props_file.read_text(encoding="utf-8"))
            if isinstance(arr, list):
                for obj in arr:
                    if isinstance(obj, dict) and obj.get("id"):
                        latest_status[obj["id"]] = obj.get("status")
        except Exception:
            pass

    rejected_ids = {pid for pid, st in latest_status.items() if st == "rejected"}
    if rejected_ids:
        for path in de._all_instinct_paths():
            if path.stem not in rejected_ids:
                continue
            result = de._read_instinct(path)
            if result is None:
                continue
            fields, _text = result
            iid = str(fields.get("id", path.stem))
            if not DRY_RUN:
                dest_dir = path.parent / "archive"
                dest_dir.mkdir(parents=True, exist_ok=True)
                path.rename(dest_dir / path.name)
                de._log_knowledge("archived-reconciled", iid,
                                   "latest proposal status=rejected but instinct still active", source="cx-maintain")
            reconciled.append(iid)
    report["steps"].append({"name": "reconcile-proposals-instincts", "ok": True,
                             "detail": f"archived {len(reconciled)} instinct(s): {reconciled[:10]}"})
except Exception as e:
    report["steps"].append({"name": "reconcile-proposals-instincts", "ok": False, "detail": str(e)})
    report["errors"].append(f"reconcile: {e}")

# ── Step 5: health check + counts ──
health = {"laws_active": 0, "laws_cap": 15, "instincts_draft": 0, "instincts_confirmed": 0,
          "instincts_archived": 0, "proposals_pending_human": 0, "proposals_pending_auto": 0,
          "reflexes_noisy": 0, "law_deprecation_candidate": None}
try:
    import distill_engine as de
    health["laws_active"] = de._active_law_count()
    health["laws_cap"] = de.LAW_MAX_ACTIVE

    for path in de._all_instinct_paths():
        result = de._read_instinct(path)
        if result is None:
            continue
        fields, _text = result
        status = str(fields.get("status", "confirmed")).strip().lower() or "confirmed"
        if status == "draft":
            health["instincts_draft"] += 1
        else:
            health["instincts_confirmed"] += 1
    for pattern_dir in [CORTEX_DIR / "instincts" / "global" / "archive"] + \
                       list((CORTEX_DIR / "projects").glob("*/instincts/archive")):
        if pattern_dir.is_dir():
            health["instincts_archived"] += sum(1 for _ in pattern_dir.glob("*.yaml"))

    props_file = CORTEX_DIR / "proposals.json"
    if props_file.exists():
        try:
            arr = json.loads(props_file.read_text(encoding="utf-8"))
            if isinstance(arr, list):
                for p in arr:
                    if not isinstance(p, dict) or p.get("status", "pending") != "pending":
                        continue
                    if p.get("domain") in de.VALIDATE_AUTO_DOMAINS:
                        health["proposals_pending_auto"] += 1
                    else:
                        health["proposals_pending_human"] += 1
        except Exception:
            pass

    try:
        reflexes = json.loads((CORTEX_DIR / "reflexes.json").read_text(encoding="utf-8")).get("reflexes", [])
        for r in reflexes:
            fire, useful, noise = r.get("fireCount", 0), r.get("usefulCount", 0), r.get("noiseCount", 0)
            if noise >= 3 and fire >= 10 and useful < noise:
                health["reflexes_noisy"] += 1
    except Exception:
        pass

    try:
        impact = de._impact_per_iid(days=14)
        health["law_deprecation_candidate"] = de._find_least_impactful_law(impact)
    except Exception:
        pass

    report["steps"].append({"name": "health-check", "ok": True, "detail": health})
except Exception as e:
    report["steps"].append({"name": "health-check", "ok": False, "detail": str(e)})
    report["errors"].append(f"health-check: {e}")

# ── Step 6: write the /cx-review digest (successor to auto-distill-candidates.md) ──
digest_written = False
if not DRY_RUN:
    try:
        digest = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "proposals_human_gated": health["proposals_pending_human"],
            "instincts_draft_total": health["instincts_draft"],
            "law_candidates": [{"id": c["id"], "reasons": c.get("reasons", [])[:2]} for c in (candidates or [])[:20]],
            "law_deprecation_candidate": health["law_deprecation_candidate"],
            "laws_active": health["laws_active"],
            "laws_cap": health["laws_cap"],
        }
        digest["total_items"] = (
            digest["proposals_human_gated"]
            + len(digest["law_candidates"])
            + (1 if digest["law_deprecation_candidate"] else 0)
        )
        tmp = CORTEX_DIR / ".review-digest.json.tmp"
        tmp.write_text(json.dumps(digest, indent=2), encoding="utf-8")
        os.replace(tmp, CORTEX_DIR / ".review-digest.json")
        digest_written = True
        report["steps"].append({"name": "write-digest", "ok": True,
                                 "detail": f"total_items={digest['total_items']}"})
    except Exception as e:
        report["steps"].append({"name": "write-digest", "ok": False, "detail": str(e)})
        report["errors"].append(f"write-digest: {e}")
else:
    report["steps"].append({"name": "write-digest", "ok": True, "detail": "(dry-run: not written)"})

# ── Step 7: compat markers .last-distill / .last-dream + learn markers ──
# v4.2.2: also reset the learn markers. observe.py touches .learn-pending
# every LEARN_THRESHOLD observations, but nothing cleared it after
# /cx-analyze retired in v4 — so SessionStart's "N+ new observations, run
# /cx-maintain" banner nagged forever, even right after a pass. Snapshot the
# current observation total into .last-learn-count, zero .obs-count and drop
# the flag, so check_learn_pending() measures "since last maintenance" again.
if not DRY_RUN:
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        (CORTEX_DIR / ".last-distill").write_text(now_iso + "\n", encoding="utf-8")
        (CORTEX_DIR / ".last-dream").write_text(now_iso + "\n", encoding="utf-8")
        total_obs = 0
        for obs_file in (CORTEX_DIR / "projects").glob("*/observations.jsonl"):
            try:
                with open(obs_file, encoding="utf-8") as f:
                    total_obs += sum(1 for _ in f)
            except OSError:
                pass
        for name, value in ((".last-learn-count", str(total_obs)), (".obs-count", "0")):
            tmp = CORTEX_DIR / f"{name}.tmp.{os.getpid()}"
            tmp.write_text(value, encoding="utf-8")
            os.replace(tmp, CORTEX_DIR / name)
        try:
            (CORTEX_DIR / ".learn-pending").unlink()
        except FileNotFoundError:
            pass
        report["steps"].append({"name": "compat-markers", "ok": True,
                                 "detail": f"touched .last-distill, .last-dream; .last-learn-count={total_obs}; .obs-count=0; cleared .learn-pending"})
    except Exception as e:
        report["steps"].append({"name": "compat-markers", "ok": False, "detail": str(e)})
        report["errors"].append(f"compat-markers: {e}")
else:
    report["steps"].append({"name": "compat-markers", "ok": True, "detail": "(dry-run: not touched)"})

# ── Report ──
print("================================================================")
print(f"  CX-MAINTAIN{'  (dry-run)' if DRY_RUN else ''} — {datetime.now().strftime('%Y-%m-%d %H:%M')}")
print("================================================================")
for s in report["steps"]:
    mark = "OK " if s["ok"] else "ERR"
    print(f"  [{mark}] {s['name']}: {s['detail']}")
print("----------------------------------------------------------------")
if report["errors"]:
    print(f"  {len(report['errors'])} step(s) failed — see [ERR] lines above. Other steps still ran.")
else:
    print("  All steps completed cleanly.")
print("================================================================")
PYEOF
PY_RC=$?
set -e

if [ "$PY_RC" -ne 0 ]; then
  log "ERROR: python3 engine pass crashed (rc=$PY_RC) — this is an infra failure, not a normal step error"
  exit "$PY_RC"
fi

log "cx-maintain runner finished cleanly"
exit 0
