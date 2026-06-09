#!/usr/bin/env bash
# Storage rotation tests — issue #56.2 (v3.35.1)
# Covers: impact_log.py rotate() rename-first rewrite (loss-proof split,
# no-op pre-scan, idempotency, permissions) + storage-rotation.js gates
# (size, 24h marker, tracker prune wiring) + learner Step 5f wiring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMPACT_PY="$PROJECT_ROOT/hooks/lib/impact_log.py"
ROTATION_JS="$PROJECT_ROOT/hooks/lib/storage-rotation.js"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Storage Rotation Tests ==="
echo ""

# Helper: seed an impact.jsonl with N old (45d) + M recent (1d) events.
# Deterministic timestamps via python3 (portable — no BSD/GNU date flags).
seed_impact() { # $1=cortex_dir $2=n_old $3=n_recent
  python3 - "$1" "$2" "$3" <<'PYEOF'
import datetime as dt, json, os, sys
cortex, n_old, n_recent = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(cortex, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)
fmt = "%Y-%m-%dT%H:%M:%SZ"
with open(os.path.join(cortex, "impact.jsonl"), "a") as fh:
    for i in range(n_old):
        ts = (now - dt.timedelta(days=45, minutes=i)).strftime(fmt)
        fh.write(json.dumps({"v": 1, "ts": ts, "ev": "inject", "iid": f"old-{i}"}) + "\n")
    for i in range(n_recent):
        ts = (now - dt.timedelta(days=1, minutes=i)).strftime(fmt)
        fh.write(json.dumps({"v": 1, "ts": ts, "ev": "inject", "iid": f"new-{i}"}) + "\n")
PYEOF
}

count_lines() { # $1=file — non-empty lines, 0 if missing
  [ -f "$1" ] && grep -c . "$1" || echo 0
}

# ── rotate(): rename-first split ─────────────────────────────────────

echo "--- impact_log.py rotate ---"

S1=$(mktemp -d)
seed_impact "$S1" 3 2
printf 'this is not json\n' >> "$S1/impact.jsonl"
out=$(CORTEX_DIR="$S1" python3 "$IMPACT_PY" rotate)
echo "$out" | grep -q "archived 3 events" && pass "rotate archives 3 old events" || fail "rotate output: $out"

active_lines=$(count_lines "$S1/impact.jsonl")
[ "$active_lines" = "3" ] && pass "active keeps 2 recent + 1 malformed" || fail "active has $active_lines lines (want 3)"

archive_file=$(ls "$S1"/impact.archive/impact-*.jsonl 2>/dev/null | head -1)
[ -n "$archive_file" ] && pass "archive file created" || fail "no archive file"

archive_lines=$(count_lines "$archive_file")
[ "$archive_lines" = "3" ] && pass "archive holds exactly the 3 old events" || fail "archive has $archive_lines lines (want 3)"

# No-loss invariant: 6 lines in == active + archive out
total_after=$((active_lines + archive_lines))
[ "$total_after" = "6" ] && pass "no-loss invariant (6 in = $total_after out)" || fail "no-loss: 6 in, $total_after out"

grep -q '"iid": "old-0"' "$archive_file" 2>/dev/null || grep -q '"iid":"old-0"' "$archive_file" \
  && pass "old event content in archive" || fail "old-0 not found in archive"
grep -q 'not json' "$S1/impact.jsonl" && pass "malformed line preserved in active" || fail "malformed line lost"

# Permissions (portable check via python3, no GNU/BSD stat flags)
perm_active=$(python3 -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$S1/impact.jsonl")
[ "$perm_active" = "0o600" ] && pass "rebuilt active file is 0600" || fail "active perms $perm_active"
perm_archive=$(python3 -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$archive_file")
[ "$perm_archive" = "0o600" ] && pass "archive file is 0600" || fail "archive perms $perm_archive"

# Idempotency: immediate second run archives nothing, creates no 2nd file
out2=$(CORTEX_DIR="$S1" python3 "$IMPACT_PY" rotate)
echo "$out2" | grep -q "archived 0 events" && pass "second rotate is a no-op" || fail "second rotate: $out2"
n_archives=$(ls "$S1"/impact.archive/impact-*.jsonl 2>/dev/null | wc -l | tr -d ' ')
[ "$n_archives" = "1" ] && pass "no second archive file" || fail "$n_archives archive files"
rm -rf "$S1"

# All-recent file → pre-scan returns early, file untouched, no archive dir
S2=$(mktemp -d)
seed_impact "$S2" 0 2
before=$(count_lines "$S2/impact.jsonl")
out=$(CORTEX_DIR="$S2" python3 "$IMPACT_PY" rotate)
echo "$out" | grep -q "archived 0 events" && pass "all-recent → archived 0" || fail "all-recent: $out"
[ ! -d "$S2/impact.archive" ] && pass "pre-scan skips archive dir creation" || fail "archive dir created on no-op"
after=$(count_lines "$S2/impact.jsonl")
[ "$before" = "$after" ] && pass "all-recent file untouched" || fail "file changed $before → $after"
rm -rf "$S2"

# Only-malformed file → no-op, nothing lost
S3=$(mktemp -d)
mkdir -p "$S3"
printf 'garbage1\ngarbage2\n' > "$S3/impact.jsonl"
out=$(CORTEX_DIR="$S3" python3 "$IMPACT_PY" rotate)
echo "$out" | grep -q "archived 0 events" && pass "only-malformed → archived 0" || fail "only-malformed: $out"
[ "$(count_lines "$S3/impact.jsonl")" = "2" ] && pass "malformed-only file preserved" || fail "malformed-only file altered"
rm -rf "$S3"

echo ""
echo "--- storage-rotation.js gates ---"

# Size + marker gates: tiny threshold → rotate runs, marker written
S4=$(mktemp -d)
seed_impact "$S4" 2 1
res=$(CORTEX_DIR="$S4" CORTEX_ROTATE_SYNC=1 CORTEX_IMPACT_ROTATE_MB=0.0000001 CORTEX_TRACKER_PRUNE_MB=999999 \
  node -e "console.log(JSON.stringify(require('$ROTATION_JS').maybeRotateStorage()))")
echo "$res" | grep -q '"ran":true' && pass "maybeRotateStorage runs (no marker)" || fail "run result: $res"
echo "$res" | grep -q 'archived 2 events' && pass "impact rotate invoked via module" || fail "impact result: $res"
[ -f "$S4/.last-storage-rotate" ] && pass "24h marker written" || fail "marker missing"
n_archives=$(ls "$S4"/impact.archive/impact-*.jsonl 2>/dev/null | wc -l | tr -d ' ')
[ "$n_archives" = "1" ] && pass "module created 1 archive file" || fail "$n_archives archive files"

# Fresh marker → second call skipped entirely
res2=$(CORTEX_DIR="$S4" CORTEX_ROTATE_SYNC=1 CORTEX_IMPACT_ROTATE_MB=0.0000001 \
  node -e "console.log(JSON.stringify(require('$ROTATION_JS').maybeRotateStorage()))")
echo "$res2" | grep -q '"ran":false' && pass "marker gates second run within 24h" || fail "marker gate: $res2"
rm -rf "$S4"

# Below size threshold → nothing rotated, marker still written
S5=$(mktemp -d)
seed_impact "$S5" 2 1
res=$(CORTEX_DIR="$S5" CORTEX_ROTATE_SYNC=1 node -e "console.log(JSON.stringify(require('$ROTATION_JS').maybeRotateStorage()))")
echo "$res" | grep -q '"impact":null' && pass "default 10MB gate skips small file" || fail "size gate: $res"
[ ! -d "$S5/impact.archive" ] && pass "no archive below threshold" || fail "archive created below threshold"
[ -f "$S5/.last-storage-rotate" ] && pass "marker written even when idle" || fail "idle marker missing"
rm -rf "$S5"

# Tracker prune wiring: same-day duplicates + >365d entry
S6=$(mktemp -d)
mkdir -p "$S6"
python3 - "$S6" <<'PYEOF'
import datetime as dt, json, os, sys
cortex = sys.argv[1]
today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
lines = [
    {"date": "2020-01-01", "pattern_id": "ancient", "trigger_norm": "ancient trigger"},
    {"date": today, "pattern_id": "dup-1", "trigger_norm": "dup trigger one"},
    {"date": today, "pattern_id": "dup-1", "trigger_norm": "dup trigger one"},
    {"date": today, "pattern_id": "keep-2", "trigger_norm": "keep trigger two"},
]
with open(os.path.join(cortex, "cross-day-tracker.jsonl"), "w") as fh:
    for l in lines:
        fh.write(json.dumps(l) + "\n")
PYEOF
res=$(CORTEX_DIR="$S6" CORTEX_ROTATE_SYNC=1 CORTEX_IMPACT_ROTATE_MB=999999 CORTEX_TRACKER_PRUNE_MB=0.0000001 \
  node -e "console.log(JSON.stringify(require('$ROTATION_JS').maybeRotateStorage()))")
echo "$res" | grep -q '"pruned":2' && pass "tracker prune drops >365d + same-day dup" || fail "tracker prune: $res"
tracker_lines=$(count_lines "$S6/cross-day-tracker.jsonl")
[ "$tracker_lines" = "2" ] && pass "tracker keeps 2 entries" || fail "tracker has $tracker_lines (want 2)"
rm -rf "$S6"

echo ""
echo "--- learner wiring ---"

grep -q "storage-rotation" "$PROJECT_ROOT/hooks/session-learner.js" \
  && pass "session-learner.js Step 5f requires storage-rotation" || fail "learner wiring missing"
node -e "require('$ROTATION_JS')" 2>/dev/null && pass "module loads standalone" || fail "module load error"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
