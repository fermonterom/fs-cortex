---
name: cx-maintain
description: Deterministic maintenance pass — decay, dedup, purge, promotion, storage rotation, health check. Zero questions, cron-able.
command: true
---

# /cx-maintain

## What it does

The single deterministic maintenance pass for Cortex v4 (`docs/DESIGN-V4.md` §5).
**Zero decisions, zero questions, zero AskUserQuestion.** Either everything below
runs and prints a report, or a step is skipped with a one-line reason — nothing
ever waits on the user. Idempotent: running it twice in a row is safe (each
sub-step guards its own idempotency: `last_decay_at`, the `.last-auto-distill`
marker, size-gated storage rotation, etc.).
When the law cap is saturated, promotion now auto-swaps under deterministic
guards; the retired law cascades back to the instinct pool (`law_eligible:
false`, v4.3.1) instead of dying in archive; stale pending proposals expire
after 30 days.

Replaces the manual judgment calls that used to live in `/cx-analyze`,
`/cx-distill`, `/cx-dream`, `/cx-promote`, `/cx-backfill` (deterministic parts
only — see stub files for the mapping). This command **invokes the existing
engine functions** in `hooks/lib/distill_engine.py`, `hooks/lib/dream_cycle.py`
and `hooks/lib/storage-rotation.js` — it does not reimplement decay, promotion
criteria, or rotation thresholds. If those engines change their gates, this
command's output changes with them automatically.

Writes `~/.claude/cortex/.review-digest.json` — the accumulated digest that
`/cx-review` can present on demand and that `hooks/session-start.py` uses for
the informative one-line `[cx] maintain:` badge (swaps + expiries + queue;
silenced automatically 48h after the pass — it reports, it never assigns work).

## Usage

```
/cx-maintain             # Full pass, writes state, prints report
/cx-maintain --dry-run   # Same computation, no writes (still writes nothing,
                          # including the digest — pure preview)
```

### Cron / launchd — `bin/cx-maintain.sh`, no LLM needed

**Recommended path for unattended scheduling.** `bin/cx-maintain.sh` is a
plain bash script — no `claude -p`, no model call, no tokens spent — that
mirrors this command's Implementation section byte-for-byte against the
SAME engine functions. It resolves the engine lib dir from the installed
hooks (`~/.claude/hooks/cortex/lib`) with a fallback to the repo's own
`hooks/lib` when running from a checkout, guards against overlapping runs
with its own mkdir-based lock, and exits 0 on a clean pass:

```bash
bin/cx-maintain.sh              # full pass, writes state, prints report
bin/cx-maintain.sh --dry-run    # same computation, no writes
```

```cron
0 4 * * 0 /path/to/fs-cortex/bin/cx-maintain.sh >> ~/.claude/cortex/log/cx-maintain-cron.log 2>&1
```

See `docs/MIGRATION-V4.md` §"Scheduling `/cx-maintain` weekly" for the
launchd plist equivalent. Prefer `bin/cx-maintain.sh` over `claude -p
"/cx-maintain"` for any unattended schedule — same steps, same output
contract, zero token cost. `claude -p "/cx-maintain"` remains a valid
interactive/manual invocation.

Weekly is the suggested cadence (the daily "maintain-lite" — decay + rotation +
the fast engine pass — already runs automatically at every SessionStart via
`run_auto_distill()`, see `hooks/session-start.py`). Running `/cx-maintain`
more often than daily is harmless (idempotent) but wasteful — most sub-steps
no-op on a same-day rerun.

## Implementation

Run this as a **single Bash call** (Python heredoc). Do not split into multiple
tool calls — that reintroduces judgment between steps, which this command must
not have. Report exactly what the script prints; do not editorialize, do not
ask the user anything, do not add recommendations of your own.

This exact sequence is also packaged as `bin/cx-maintain.sh` — ejecutable sin
LLM vía `bin/cx-maintain.sh`, es la vía recomendada para cron/launchd (see
"Cron / launchd" above). The Python heredoc below and that script MUST stay
in sync; if you change one, change the other in the same commit.

```bash
CORTEX_DIR="${CORTEX_DIR:-$HOME/.claude/cortex}"
LIB_DIR="${CORTEX_LIB_DIR:-$HOME/.claude/hooks/cortex/lib}"
DRY_RUN=0
[ "$1" = "--dry-run" ] && DRY_RUN=1

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
decayed = archived = promoted = candidates = expired = []
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
            expired = de.expire_stale_proposals(dry_run=DRY_RUN)
            evolve_result = de.auto_evolve_detect(dry_run=DRY_RUN)
            evolve_drafts = len(evolve_result.get("drafts_generated", []))
            swapped = sum(1 for p in promoted if p.get("swapped_out"))
            engine_ok = True
            report["steps"].append({"name": "engine-pass", "ok": True, "detail":
                f"decayed={len(decayed)} archived={len(archived)} validated={validated} "
                f"skipped_validate={skipped_validate} promoted={len(promoted)} "
                f"(swapped={swapped}) candidates={len(candidates)} expired={len(expired)} "
                f"evolve_drafts={evolve_drafts}"})
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
            "swaps_last_run": [
                {"in": p.get("id"), "out": p.get("swapped_out")}
                for p in (promoted or [])
                if p.get("swapped_out")
            ],
            "expired_last_run": len(expired or []),
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
