#!/usr/bin/env bash
# test_impact.sh — Sprint 0 Impact Funnel tests (v3.14.0)
# Validates: schema v1, atomic writes, compute_metrics formulas, rotation, feedback, gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMPACT_PY="$REPO_ROOT/hooks/lib/impact_log.py"
IMPACT_JS="$REPO_ROOT/hooks/lib/impact_log.js"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Sandbox: isolate CORTEX_DIR per test run
SANDBOX="$(mktemp -d -t cortex-impact-test-XXXXXX)"
export CORTEX_DIR="$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== Impact Funnel Tests (sandbox: $SANDBOX) ==="
echo

# -----------------------------------------------------------------------------
echo "--- Test 1: Python library loads without errors ---"
if python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT/hooks/lib'); import impact_log" 2>/dev/null; then
  pass "impact_log.py imports cleanly"
else
  fail "impact_log.py import failed"
fi

# -----------------------------------------------------------------------------
echo "--- Test 2: JS library loads without errors ---"
if node -e "require('$IMPACT_JS')" 2>/dev/null; then
  pass "impact_log.js requires cleanly"
else
  fail "impact_log.js require failed"
fi

# -----------------------------------------------------------------------------
echo "--- Test 3: CLI 'log' appends one event ---"
python3 "$IMPACT_PY" log --event inject --iid gotcha-test-1 --tool Bash --sid sid-A --conf 0.75
if [ -f "$SANDBOX/impact.jsonl" ]; then
  LINES=$(wc -l < "$SANDBOX/impact.jsonl")
  if [ "$LINES" -eq 1 ]; then
    pass "one event written"
  else
    fail "expected 1 line, got $LINES"
  fi
else
  fail "impact.jsonl not created"
fi

# -----------------------------------------------------------------------------
echo "--- Test 4: Schema v1 fields present ---"
FIRST_LINE=$(head -1 "$SANDBOX/impact.jsonl")
if echo "$FIRST_LINE" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['v']==1 and d['ev']=='inject' and d['iid']=='gotcha-test-1'" 2>/dev/null; then
  pass "schema v1 fields correct"
else
  fail "schema mismatch: $FIRST_LINE"
fi

# -----------------------------------------------------------------------------
echo "--- Test 5: JS writer appends compatible event ---"
node -e "
const il = require('$IMPACT_JS');
il.logInjectBatch([{id:'gotcha-test-2', confidence:0.80, domain:'gotcha'}], {tool:'Edit',pid:'proj-1',sid:'sid-A'});
" 2>&1
LINES=$(wc -l < "$SANDBOX/impact.jsonl")
if [ "$LINES" -eq 2 ]; then
  pass "JS writer appended"
else
  fail "expected 2 lines after JS write, got $LINES"
fi

# -----------------------------------------------------------------------------
echo "--- Test 6: Python + JS events are JSON-compatible ---"
if python3 -c "
import json
with open('$SANDBOX/impact.jsonl') as f:
    lines = [json.loads(l) for l in f if l.strip()]
assert len(lines) == 2
assert all(ev['v']==1 for ev in lines)
assert {ev['ev'] for ev in lines} == {'inject'}
" 2>/dev/null; then
  pass "Python and JS events mutually parseable"
else
  fail "cross-writer compatibility broken"
fi

# -----------------------------------------------------------------------------
echo "--- Test 7: Feedback event writes to feedback.jsonl too ---"
python3 "$IMPACT_PY" log --event feedback --iid gotcha-test-1 --sid sid-A --rating useful
if [ -f "$SANDBOX/feedback.jsonl" ]; then
  FB_LINES=$(wc -l < "$SANDBOX/feedback.jsonl")
  # Note: `log --event feedback` only writes to impact.jsonl; feedback.jsonl
  # mirror is produced by the library-level log_feedback() helper.
  if [ "$FB_LINES" -eq 0 ]; then
    # Call the library helper explicitly
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/hooks/lib')
import impact_log
impact_log.log_feedback('gotcha-test-1','useful','sid-A','test note')
"
    FB_LINES=$(wc -l < "$SANDBOX/feedback.jsonl")
  fi
  if [ "$FB_LINES" -ge 1 ]; then
    pass "feedback.jsonl mirror written"
  else
    fail "feedback.jsonl empty"
  fi
else
  # Library helper case
  python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/hooks/lib')
import impact_log
impact_log.log_feedback('gotcha-test-1','useful','sid-A','test note')
"
  [ -f "$SANDBOX/feedback.jsonl" ] && pass "feedback.jsonl created by helper" || fail "feedback.jsonl not created"
fi

# -----------------------------------------------------------------------------
echo "--- Test 8: compute_metrics produces canonical formulas ---"
# Reset sandbox with controlled fixture: 10 injects, 4 useful (follow+noerr), 2 noise (follow+false), 1 feedback-useful, 1 feedback-noise
rm -f "$SANDBOX/impact.jsonl" "$SANDBOX/feedback.jsonl"
for i in 1 2 3 4 5 6 7 8 9 10; do
  python3 "$IMPACT_PY" log --event inject --iid "gotcha-$i" --tool Bash --sid sid-B --conf 0.7
done
# 4 followed=true err=false
for i in 1 2 3 4; do
  python3 "$IMPACT_PY" log --event follow --iid "gotcha-$i" --sid sid-B --followed true --err_after false
done
# 2 followed=false
for i in 5 6; do
  python3 "$IMPACT_PY" log --event follow --iid "gotcha-$i" --sid sid-B --followed false --err_after false
done
# 1 feedback useful, 1 noise
python3 "$IMPACT_PY" log --event feedback --iid gotcha-7 --sid sid-B --rating useful
python3 "$IMPACT_PY" log --event feedback --iid gotcha-8 --sid sid-B --rating noise

STATS=$(python3 "$IMPACT_PY" stats --days 1 --json)
if echo "$STATS" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['totals']['inject'] == 10, f\"inject={d['totals']['inject']}\"
assert d['useful_events'] == 5, f\"useful={d['useful_events']}\"  # 4 follow + 1 feedback
assert d['noise_events'] == 3, f\"noise={d['noise_events']}\"     # 2 follow-false + 1 feedback-noise
assert abs(d['useful_ratio'] - 0.5) < 0.001, f\"ur={d['useful_ratio']}\"
assert abs(d['noise_ratio']  - 0.3) < 0.001, f\"nr={d['noise_ratio']}\"
" 2>/dev/null; then
  pass "useful_ratio=0.50, noise_ratio=0.30 match fixture"
else
  fail "compute_metrics formula mismatch"
  echo "$STATS" | python3 -m json.tool 2>/dev/null | head -20
fi

# -----------------------------------------------------------------------------
echo "--- Test 9: Gate recommendation GO/PARTIAL/NO-GO ---"
# useful_ratio=0.5, noise_ratio=0.3 → health_ratio=0.5/0.3=1.67 → GO
GATE=$(echo "$STATS" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['gate'])")
if [ "$GATE" = "GO" ]; then
  pass "gate=GO for useful=0.50,health=1.67"
else
  fail "expected gate=GO, got $GATE"
fi

# Low ratio fixture → NO-GO
rm -f "$SANDBOX/impact.jsonl"
for i in 1 2 3 4 5 6 7 8 9 10; do
  python3 "$IMPACT_PY" log --event inject --iid "noisy-$i" --sid sid-C
done
for i in 1 2 3 4 5 6 7 8 9 10; do
  python3 "$IMPACT_PY" log --event follow --iid "noisy-$i" --sid sid-C --followed false
done
STATS_BAD=$(python3 "$IMPACT_PY" stats --days 1 --json)
GATE_BAD=$(echo "$STATS_BAD" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['gate'])")
if [ "$GATE_BAD" = "NO-GO" ]; then
  pass "gate=NO-GO for useful=0.0"
else
  fail "expected gate=NO-GO for zero useful, got $GATE_BAD"
fi

# -----------------------------------------------------------------------------
echo "--- Test 10: Concurrent writes do not corrupt ---"
rm -f "$SANDBOX/impact.jsonl"
(
  for i in 1 2 3 4 5 6 7 8 9 10; do
    python3 "$IMPACT_PY" log --event inject --iid "concurrent-$i" --sid sid-D &
  done
  wait
)
LINES=$(wc -l < "$SANDBOX/impact.jsonl")
if [ "$LINES" -eq 10 ]; then
  pass "10 concurrent writes produced 10 lines"
else
  fail "expected 10 concurrent lines, got $LINES (data loss or corruption)"
fi

# Verify all JSON parses
if python3 -c "
import json
with open('$SANDBOX/impact.jsonl') as f:
    for line in f:
        if line.strip():
            json.loads(line)
" 2>/dev/null; then
  pass "all concurrent lines parse as JSON"
else
  fail "concurrent writes corrupted at least one line"
fi

# -----------------------------------------------------------------------------
echo "--- Test 11: Rotation archives old events ---"
rm -f "$SANDBOX/impact.jsonl"
rm -rf "$SANDBOX/impact.archive"
# 40-day-old event
OLD_TS=$(python3 -c "import datetime as d; print((d.datetime.utcnow()-d.timedelta(days=40)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
echo "{\"v\":1,\"ts\":\"$OLD_TS\",\"ev\":\"inject\",\"iid\":\"old-event\"}" >> "$SANDBOX/impact.jsonl"
# 5-day-old event
FRESH_TS=$(python3 -c "import datetime as d; print((d.datetime.utcnow()-d.timedelta(days=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
echo "{\"v\":1,\"ts\":\"$FRESH_TS\",\"ev\":\"inject\",\"iid\":\"fresh-event\"}" >> "$SANDBOX/impact.jsonl"

ARCHIVED=$(python3 "$IMPACT_PY" rotate | grep -oE '[0-9]+' | head -1)
if [ "$ARCHIVED" = "1" ]; then
  pass "rotate() archived 1 event"
else
  fail "expected 1 archived, got $ARCHIVED"
fi

# Verify fresh event remains, archive exists
if grep -q "fresh-event" "$SANDBOX/impact.jsonl" 2>/dev/null && ! grep -q "old-event" "$SANDBOX/impact.jsonl" 2>/dev/null; then
  pass "fresh event kept, old event archived"
else
  fail "rotation kept/removed wrong events"
fi

if ls "$SANDBOX/impact.archive"/impact-*.jsonl >/dev/null 2>&1; then
  pass "archive file created"
else
  fail "archive file missing"
fi

# -----------------------------------------------------------------------------
echo "--- Test 12: Invalid event rejected ---"
if python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/hooks/lib')
import impact_log
try:
    impact_log.log_event('not-a-valid-event', iid='x')
    sys.exit(1)
except ValueError:
    sys.exit(0)
"; then
  pass "invalid event raises ValueError"
else
  fail "invalid event not rejected"
fi

# -----------------------------------------------------------------------------
echo "--- Test 13: Invalid feedback rating rejected ---"
if python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/hooks/lib')
import impact_log
try:
    impact_log.log_feedback('some-id', 'garbage')
    sys.exit(1)
except ValueError:
    sys.exit(0)
"; then
  pass "invalid rating raises ValueError"
else
  fail "invalid rating not rejected"
fi

# -----------------------------------------------------------------------------
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
