#!/usr/bin/env bash
# test_promotion_gate.sh — v3.32.0 §4.4 promotion gate HUMAN → AUTO
# Validates: can_promote_to_auto thresholds, n=10 visibility tier,
# rejection_category enum + fallback heuristic, fail-closed marker reader.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Promotion Gate Tests (v3.32.0 §4.4) ==="
echo ""

_py_patch() {
  local tdir="$1"
  cat <<PYEOF
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$tdir'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$tdir')
de.PROPOSALS_HISTORY_FILE = de.CORTEX_DIR / 'proposals-history.jsonl'
de.PROMOTED_DETECTORS_FILE = de.CORTEX_DIR / '.promoted-detectors.json'
de.SECURITY_LOG_FILE = de.CORTEX_DIR / 'log' / 'security-events.jsonl'
PYEOF
}

_seed_history() {
  # _seed_history <file> <source> <accepted_n> <rejected_n> <distinct_sessions>
  #               <critical_enum_n> <critical_legacy_n>
  HIST_FILE="$1" HIST_SRC="$2" HIST_ACC="$3" HIST_REJ="$4" \
  HIST_SES="$5" HIST_CRIT_ENUM="$6" HIST_CRIT_LEGACY="$7" \
  python3 - <<'PYEOF'
import json, os, pathlib
path = pathlib.Path(os.environ["HIST_FILE"])
path.parent.mkdir(parents=True, exist_ok=True)
source = os.environ["HIST_SRC"]
accepted = int(os.environ["HIST_ACC"])
rejected = int(os.environ["HIST_REJ"])
sessions = int(os.environ["HIST_SES"])
crit_enum = int(os.environ["HIST_CRIT_ENUM"])
crit_legacy = int(os.environ["HIST_CRIT_LEGACY"])
session_ids = [f"sess-{i}" for i in range(sessions)]
lines = []
for i in range(accepted):
    sid = session_ids[i % len(session_ids)] if session_ids else f"sess-{i}"
    lines.append(json.dumps({
        "id": f"acc-{i}", "status": "accepted",
        "source": source, "accepted_at": "2026-05-20",
        "accepted_by": "cx-validate", "session_id": sid,
    }))
for i in range(rejected):
    sid = session_ids[i % len(session_ids)] if session_ids else f"sess-r-{i}"
    if i < crit_enum:
        lines.append(json.dumps({
            "id": f"rej-c-{i}", "status": "rejected", "source": source,
            "rejected_at": "2026-05-21", "rejected_by": "cx-validate",
            "session_id": sid, "rejection_category": "security",
            "rejected_reason": "looks-fine-but-tagged",
        }))
    elif i < crit_enum + crit_legacy:
        lines.append(json.dumps({
            "id": f"rej-L-{i}", "status": "rejected", "source": source,
            "rejected_at": "2026-05-21", "rejected_by": "cx-validate",
            "session_id": sid, "rejection_category": None,
            "rejected_reason": "Esto es un problema de seguridad serio",
        }))
    else:
        lines.append(json.dumps({
            "id": f"rej-{i}", "status": "rejected", "source": source,
            "rejected_at": "2026-05-21", "rejected_by": "cx-validate",
            "session_id": sid, "rejection_category": "noise",
            "rejected_reason": "too-vague",
        }))
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYEOF
}

# ── Test 1: source-not-in-history → reviewed 0/10 ────────────────────────────
echo "--- Test 1: source-not-in-history ---"
T1="$(mktemp -d -t promo-t1-XXXXXX)"
export CORTEX_DIR="$T1"
# Empty / no history file at all.
result=$(python3 - <<PYEOF
$(_py_patch "$T1")
eligible, reason, stats = de.can_promote_to_auto("session-learner:not-seen")
print(f"elig={eligible} n={stats['reviewed_count']} reason={reason}")
PYEOF
)
if echo "$result" | grep -q "elig=False n=0 reason=reviewed 0/10"; then
  pass "source-not-in-history: blocked with reviewed 0/10"
else
  fail "source-not-in-history: got '$result'"
fi
rm -rf "$T1"

# ── Test 2: n=10 visibility tier ─────────────────────────────────────────────
echo "--- Test 2: visibility-tier-n10 ---"
T2="$(mktemp -d -t promo-t2-XXXXXX)"
export CORTEX_DIR="$T2"
_seed_history "$T2/proposals-history.jsonl" "session-learner:correction" 10 0 3 0 0
result=$(python3 - <<PYEOF
$(_py_patch "$T2")
eligible, reason, stats = de.can_promote_to_auto("session-learner:correction")
print(f"elig={eligible} n={stats['reviewed_count']} reason={reason}")
PYEOF
)
if echo "$result" | grep -q "elig=False n=10 reason=visible-only (10/20)"; then
  pass "visibility-tier-n10: blocked with visible-only (10/20)"
else
  fail "visibility-tier-n10: got '$result'"
fi
rm -rf "$T2"

# ── Test 3: accept_rate-below-0.70 ───────────────────────────────────────────
echo "--- Test 3: accept-rate-below ---"
T3="$(mktemp -d -t promo-t3-XXXXXX)"
export CORTEX_DIR="$T3"
# 13 accepted + 7 rejected = 20 total, accept_rate = 0.65
_seed_history "$T3/proposals-history.jsonl" "session-learner:coupling" 13 7 3 0 0
result=$(python3 - <<PYEOF
$(_py_patch "$T3")
eligible, reason, stats = de.can_promote_to_auto("session-learner:coupling")
print(f"elig={eligible} reason={reason}")
PYEOF
)
if echo "$result" | grep -q "elig=False reason=accept_rate 0.65 < 0.70"; then
  pass "accept-rate-below: blocked with accept_rate 0.65 < 0.70"
else
  fail "accept-rate-below: got '$result'"
fi
rm -rf "$T3"

# ── Test 4: distinct-sessions-below ──────────────────────────────────────────
echo "--- Test 4: distinct-sessions-below ---"
T4="$(mktemp -d -t promo-t4-XXXXXX)"
export CORTEX_DIR="$T4"
# 16 accepted + 4 noise rejected = 20, accept_rate=0.80, sessions=2
_seed_history "$T4/proposals-history.jsonl" "session-learner:agent-quality" 16 4 2 0 0
result=$(python3 - <<PYEOF
$(_py_patch "$T4")
eligible, reason, stats = de.can_promote_to_auto("session-learner:agent-quality")
print(f"elig={eligible} reason={reason}")
PYEOF
)
if echo "$result" | grep -q "elig=False reason=distinct_sessions 2 < 3"; then
  pass "distinct-sessions-below: blocked with distinct_sessions 2 < 3"
else
  fail "distinct-sessions-below: got '$result'"
fi
rm -rf "$T4"

# ── Test 5: critical-rejection-enum ──────────────────────────────────────────
echo "--- Test 5: critical-rejection-enum ---"
T5="$(mktemp -d -t promo-t5-XXXXXX)"
export CORTEX_DIR="$T5"
# 16 accepted + 1 critical-enum + 3 noise = 20, rate=0.80, sessions=3
_seed_history "$T5/proposals-history.jsonl" "session-learner:correction" 16 4 3 1 0
result=$(python3 - <<PYEOF
$(_py_patch "$T5")
eligible, reason, stats = de.can_promote_to_auto("session-learner:correction")
print(f"elig={eligible} reason={reason}")
PYEOF
)
if echo "$result" | grep -q "elig=False reason=critical_rejections 1 > 0"; then
  pass "critical-rejection-enum: blocked with critical_rejections 1 > 0"
else
  fail "critical-rejection-enum: got '$result'"
fi
rm -rf "$T5"

# ── Test 6: critical-rejection-fallback (legacy ES keyword) ─────────────────
echo "--- Test 6: critical-rejection-fallback ---"
T6="$(mktemp -d -t promo-t6-XXXXXX)"
export CORTEX_DIR="$T6"
# 16 accepted + 1 critical-legacy ("seguridad") + 3 noise = 20
_seed_history "$T6/proposals-history.jsonl" "session-learner:coupling" 16 4 3 0 1
result=$(python3 - <<PYEOF
$(_py_patch "$T6")
eligible, reason, stats = de.can_promote_to_auto("session-learner:coupling")
print(f"elig={eligible} reason={reason} critical={stats['critical_count']}")
PYEOF
)
if echo "$result" | grep -q "elig=False reason=critical_rejections 1 > 0 critical=1"; then
  pass "critical-rejection-fallback: legacy 'seguridad' detected via heuristic (AD P1-6)"
else
  fail "critical-rejection-fallback: got '$result'"
fi
rm -rf "$T6"

# ── Test 7: all-gates-pass ───────────────────────────────────────────────────
echo "--- Test 7: all-gates-pass ---"
T7="$(mktemp -d -t promo-t7-XXXXXX)"
export CORTEX_DIR="$T7"
# 19 accepted + 5 noise = 24 reviewed, rate=19/24≈0.79, sessions=4, critical=0
_seed_history "$T7/proposals-history.jsonl" "session-learner:correction" 19 5 4 0 0
result=$(python3 - <<PYEOF
$(_py_patch "$T7")
eligible, reason, stats = de.can_promote_to_auto("session-learner:correction")
print(f"elig={eligible} reason={reason} n={stats['reviewed_count']} acc={stats['accept_count']} ses={stats['distinct_sessions']}")
PYEOF
)
if echo "$result" | grep -q "elig=True reason=all-gates-pass n=24 acc=19 ses=4"; then
  pass "all-gates-pass: n=24 accept=19 sessions=4 critical=0 → eligible"
else
  fail "all-gates-pass: got '$result'"
fi
rm -rf "$T7"

# ── Test 8: marker fail-closed (corrupted JSON) ─────────────────────────────
echo "--- Test 8: marker-fail-closed ---"
T8="$(mktemp -d -t promo-t8-XXXXXX)"
export CORTEX_DIR="$T8"
# Write a deliberately broken marker
printf '{"version": 1, "promoted": [{"source": "session-learner:correction", "since' > "$T8/.promoted-detectors.json"
# Also: write a valid marker file with wrong schema version
mkdir -p "$T8/alt"
echo '{"version": 99, "promoted": [{"source": "x:y", "since": "2026-05-20T00:00:00Z"}]}' > "$T8/alt/.promoted-detectors.json"
result=$(python3 - <<PYEOF
$(_py_patch "$T8")
# Pass 1: corrupted JSON → empty set
got1 = de._load_promoted_detectors()
# Pass 2: wrong schema version → empty set (point engine at alt marker)
de.PROMOTED_DETECTORS_FILE = de.CORTEX_DIR / 'alt' / '.promoted-detectors.json'
got2 = de._load_promoted_detectors()
# Pass 3: VALID marker → populates set
de.PROMOTED_DETECTORS_FILE = de.CORTEX_DIR / 'valid.json'
de.PROMOTED_DETECTORS_FILE.write_text(
    '{"version": 1, "promoted": [{"source": "session-learner:correction", '
    '"since": "2026-05-20T00:00:00Z", "approved_by": "operator"}]}',
    encoding="utf-8",
)
got3 = de._load_promoted_detectors()
print(f"corrupted={sorted(got1)} bad_version={sorted(got2)} valid={sorted(got3)}")
PYEOF
)
if echo "$result" | grep -q "corrupted=\[\] bad_version=\[\] valid=\['session-learner:correction'\]"; then
  pass "marker-fail-closed: corrupted + bad-version → empty set (AD P0-4); valid marker populates"
else
  fail "marker-fail-closed: got '$result'"
fi
rm -rf "$T8"

# ── v3.32.0 §4.4 quick wins (PR #44 review feedback) ────────────────────────

# ── Test 9: confirm=False blocks the write ──────────────────────────────────
echo "--- Test 9: confirm-false-blocks-write ---"
T9="$(mktemp -d -t promo-t9-XXXXXX)"
export CORTEX_DIR="$T9"
_seed_history "$T9/proposals-history.jsonl" "session-learner:correction" 22 3 4 0 0
result=$(python3 - <<PYEOF
$(_py_patch "$T9")
ok, reason, stats = de.manual_promote_detector("session-learner:correction", confirm=False)
marker_written = de.PROMOTED_DETECTORS_FILE.exists()
print(f"ok={ok} reason={reason} marker={marker_written}")
PYEOF
)
if echo "$result" | grep -q "ok=False reason=missing --confirm marker=False"; then
  pass "confirm-false-blocks-write: missing --confirm → (False, 'missing --confirm'); no marker on disk"
else
  fail "confirm-false-blocks-write: got '$result'"
fi
rm -rf "$T9"

# ── Test 10: idempotent double-promote ──────────────────────────────────────
echo "--- Test 10: idempotent-double-promote ---"
T10="$(mktemp -d -t promo-t10-XXXXXX)"
export CORTEX_DIR="$T10"
_seed_history "$T10/proposals-history.jsonl" "session-learner:correction" 22 3 4 0 0
result=$(python3 - <<PYEOF
$(_py_patch "$T10")
import json as _j
ok1, reason1, _ = de.manual_promote_detector("session-learner:correction", confirm=True)
ok2, reason2, _ = de.manual_promote_detector("session-learner:correction", confirm=True)
data = _j.loads(de.PROMOTED_DETECTORS_FILE.read_text(encoding="utf-8"))
n_entries = len([
    e for e in data.get("promoted", [])
    if isinstance(e, dict) and e.get("source") == "session-learner:correction"
])
print(f"first=({ok1},{reason1}) second=({ok2},{reason2}) entries={n_entries}")
PYEOF
)
if echo "$result" | grep -qE "first=\(True,promoted\) second=\(True,already-promoted\) entries=1"; then
  pass "idempotent-double-promote: 2nd call → 'already-promoted'; marker still has 1 entry"
else
  fail "idempotent-double-promote: got '$result'"
fi
rm -rf "$T10"

# ── Test 11: corrupted marker preserved by rename-archive ───────────────────
echo "--- Test 11: corrupt-marker-archive ---"
T11="$(mktemp -d -t promo-t11-XXXXXX)"
export CORTEX_DIR="$T11"
_seed_history "$T11/proposals-history.jsonl" "session-learner:correction" 22 3 4 0 0
# Seed a marker with a partial / corrupt JSON (deliberate)
ORIG_CONTENT='{"version": 1, "promoted": [{"source": "OLD-source-not-lost", "since'
printf '%s' "$ORIG_CONTENT" > "$T11/.promoted-detectors.json"
result=$(python3 - <<PYEOF
$(_py_patch "$T11")
import json as _j, os
ok, reason, _ = de.manual_promote_detector("session-learner:correction", confirm=True)
# After the call: marker exists with new entry; archive .corrupt-* exists
# with the original (corrupt) content preserved verbatim.
marker_after = _j.loads(de.PROMOTED_DETECTORS_FILE.read_text(encoding="utf-8"))
has_new = any(e.get("source") == "session-learner:correction"
              for e in marker_after.get("promoted", []) if isinstance(e, dict))
archive_files = [
    f for f in os.listdir(str(de.CORTEX_DIR))
    if f.startswith(".promoted-detectors.json.corrupt-")
]
archive_content = ""
if archive_files:
    archive_content = (de.CORTEX_DIR / archive_files[0]).read_text(encoding="utf-8")
preserved = "OLD-source-not-lost" in archive_content
print(f"ok={ok} reason={reason} new_in_marker={has_new} archives={len(archive_files)} preserved={preserved}")
PYEOF
)
if echo "$result" | grep -q "ok=True reason=promoted new_in_marker=True archives=1 preserved=True"; then
  pass "corrupt-marker-archive: corrupt original renamed to .corrupt-<ts>; content preserved verbatim; new marker written"
else
  fail "corrupt-marker-archive: got '$result'"
fi
rm -rf "$T11"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
