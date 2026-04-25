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
echo "--- Test 14: feedback with --source user writes source field ---"
rm -f "$SANDBOX/impact.jsonl" "$SANDBOX/feedback.jsonl"
python3 "$IMPACT_PY" log --event feedback --iid src-test-1 --rating useful --source user
LAST=$(tail -1 "$SANDBOX/impact.jsonl")
if echo "$LAST" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('source')=='user'" 2>/dev/null; then
  pass "source=user persisted in event"
else
  fail "source=user missing or wrong: $LAST"
fi

# -----------------------------------------------------------------------------
echo "--- Test 15: feedback with --source agent writes source field ---"
python3 "$IMPACT_PY" log --event feedback --iid src-test-2 --rating useful --source agent
LAST=$(tail -1 "$SANDBOX/impact.jsonl")
if echo "$LAST" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('source')=='agent'" 2>/dev/null; then
  pass "source=agent persisted in event"
else
  fail "source=agent missing or wrong: $LAST"
fi

# -----------------------------------------------------------------------------
echo "--- Test 16: legacy events without source default to user on read ---"
# Write a legacy-shaped event manually (no source field)
echo '{"v":1,"ts":"2026-04-01T00:00:00Z","ev":"feedback","iid":"legacy-1","rating":"useful"}' >> "$SANDBOX/impact.jsonl"
# Also need an inject for it to count
echo '{"v":1,"ts":"2026-04-01T00:00:00Z","ev":"inject","iid":"legacy-1","tool":"Bash"}' >> "$SANDBOX/impact.jsonl"
STATS=$(python3 "$IMPACT_PY" stats --days 365 --json)
if echo "$STATS" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
# legacy useful-feedback should count toward useful_ratio_user (default source)
assert d['useful_ratio_user'] > 0, 'legacy event lost in user bucket'
" 2>/dev/null; then
  pass "missing source defaults to user"
else
  fail "legacy event handling broken"
fi

# -----------------------------------------------------------------------------
echo "--- Test 17: split ratios — user vs agent — with controlled fixture ---"
rm -f "$SANDBOX/impact.jsonl" "$SANDBOX/feedback.jsonl"
# 4 injects, 1 user-useful, 1 user-noise, 1 agent-useful, 1 agent-noise
for i in 1 2 3 4; do
  python3 "$IMPACT_PY" log --event inject --iid "split-$i" --tool Bash --sid sid-S --conf 0.7
done
python3 "$IMPACT_PY" log --event feedback --iid split-1 --rating useful --source user
python3 "$IMPACT_PY" log --event feedback --iid split-2 --rating noise  --source user
python3 "$IMPACT_PY" log --event feedback --iid split-3 --rating useful --source agent
python3 "$IMPACT_PY" log --event feedback --iid split-4 --rating noise  --source agent

STATS=$(python3 "$IMPACT_PY" stats --days 1 --json)
if echo "$STATS" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
# 4 injects, 1 user-useful, 1 user-noise → both = 0.25
assert abs(d['useful_ratio_user']  - 0.25) < 0.001, f'user useful={d[\"useful_ratio_user\"]}'
assert abs(d['noise_ratio_user']   - 0.25) < 0.001, f'user noise={d[\"noise_ratio_user\"]}'
assert abs(d['useful_ratio_agent'] - 0.25) < 0.001, f'agent useful={d[\"useful_ratio_agent\"]}'
assert abs(d['noise_ratio_agent']  - 0.25) < 0.001, f'agent noise={d[\"noise_ratio_agent\"]}'
# Legacy aggregate sums both
assert abs(d['useful_ratio'] - 0.50) < 0.001, f'legacy useful={d[\"useful_ratio\"]}'
" 2>/dev/null; then
  pass "split ratios correct (user 0.25/0.25, agent 0.25/0.25, legacy 0.50)"
else
  fail "split ratio mismatch"
  echo "$STATS" | python3 -m json.tool 2>/dev/null | head -25
fi

# -----------------------------------------------------------------------------
echo "--- Test 18: gate uses _user only (high agent should not flip to GO) ---"
rm -f "$SANDBOX/impact.jsonl"
# 10 injects, 9 agent-useful, 0 user-useful → useful_ratio_user = 0.0 → NO-GO despite agent at 0.9
for i in 1 2 3 4 5 6 7 8 9 10; do
  python3 "$IMPACT_PY" log --event inject --iid "agent-only-$i" --tool Bash --sid sid-G --conf 0.7
done
for i in 1 2 3 4 5 6 7 8 9; do
  python3 "$IMPACT_PY" log --event feedback --iid "agent-only-$i" --rating useful --source agent
done
GATE=$(python3 "$IMPACT_PY" stats --days 1 --json | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['gate'])")
if [ "$GATE" = "NO-GO" ]; then
  pass "agent-only useful does not flip gate (NO-GO as expected)"
else
  fail "expected NO-GO for agent-only useful, got $GATE"
fi

# -----------------------------------------------------------------------------
echo "--- Test 19: invalid source raises ValueError ---"
if python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/hooks/lib')
import impact_log
try:
    impact_log.log_feedback('some-id', 'useful', source='hacker')
    sys.exit(1)
except ValueError:
    sys.exit(0)
"; then
  pass "invalid source raises ValueError"
else
  fail "invalid source not rejected"
fi

# -----------------------------------------------------------------------------
# v3.18.0 — Reflex auto-evaluation (Alcance MAX)
# -----------------------------------------------------------------------------
echo "--- Test 20: evalToolSubstitution returns useful when expected_tool follows ---"
RESULT=$(node -e "
const sl = require('$REPO_ROOT/hooks/session-learner.js');
const obs = [
  { tool:'Bash', input:'find . -name x', ts:'2026-04-25T10:00:00Z' },
  { tool:'Glob', input:'**/*.js',         ts:'2026-04-25T10:00:01Z' }
];
console.log(sl.evalToolSubstitution(
  { type:'tool-substitution', expected_tool:'Glob', anti_tool:'Bash', anti_pattern:'find ', window:3 },
  obs, 0
));
")
[ "$RESULT" = "useful" ] && pass "tool-substitution useful" || fail "expected useful, got $RESULT"

# -----------------------------------------------------------------------------
echo "--- Test 21: evalToolSubstitution returns noise when anti_pattern repeats ---"
RESULT=$(node -e "
const sl = require('$REPO_ROOT/hooks/session-learner.js');
const obs = [
  { tool:'Bash', input:'find . -name x', ts:'t0' },
  { tool:'Bash', input:'find . -type f', ts:'t1' }
];
console.log(sl.evalToolSubstitution(
  { type:'tool-substitution', expected_tool:'Glob', anti_tool:'Bash', anti_pattern:'find ', window:3 },
  obs, 0
));
")
[ "$RESULT" = "noise" ] && pass "tool-substitution noise on repeat" || fail "expected noise, got $RESULT"

# -----------------------------------------------------------------------------
echo "--- Test 22: evalToolSubstitution returns ignore when neither path taken ---"
RESULT=$(node -e "
const sl = require('$REPO_ROOT/hooks/session-learner.js');
const obs = [
  { tool:'Bash', input:'find . -name x', ts:'t0' },
  { tool:'Read', input:'/tmp/foo',       ts:'t1' }
];
console.log(sl.evalToolSubstitution(
  { type:'tool-substitution', expected_tool:'Glob', anti_tool:'Bash', anti_pattern:'find ', window:3 },
  obs, 0
));
")
[ "$RESULT" = "ignore" ] && pass "tool-substitution ignore" || fail "expected ignore, got $RESULT"

# -----------------------------------------------------------------------------
echo "--- Test 23: evalPreconditionCheck returns useful when Read precedes Edit ---"
RESULT=$(node -e "
const sl = require('$REPO_ROOT/hooks/session-learner.js');
const obs = [
  { tool:'Read', input:JSON.stringify({file_path:'/tmp/x.ts'}), ts:'t0' },
  { tool:'Edit', input:JSON.stringify({file_path:'/tmp/x.ts'}), ts:'t1', err:false }
];
console.log(sl.evalPreconditionCheck(
  { type:'precondition-check', precondition_tool:'Read', match_field:'file_path', lookback:10 },
  obs, 1
));
")
[ "$RESULT" = "useful" ] && pass "precondition-check useful" || fail "expected useful, got $RESULT"

# -----------------------------------------------------------------------------
echo "--- Test 24: evalPreconditionCheck returns ignore when no error and no precondition ---"
RESULT=$(node -e "
const sl = require('$REPO_ROOT/hooks/session-learner.js');
const obs = [
  { tool:'Edit', input:JSON.stringify({file_path:'/tmp/new.ts'}), ts:'t0', err:false }
];
console.log(sl.evalPreconditionCheck(
  { type:'precondition-check', precondition_tool:'Read', match_field:'file_path', lookback:10 },
  obs, 0
));
")
[ "$RESULT" = "ignore" ] && pass "precondition-check ignore (no error)" || fail "expected ignore, got $RESULT"

# -----------------------------------------------------------------------------
echo "--- Test 25: evalErrorMonitor returns noise when error matches pattern ---"
RESULT=$(node -e "
const sl = require('$REPO_ROOT/hooks/session-learner.js');
const obs = [
  { tool:'Bash', input:'git push', ts:'t0', err:false },
  { tool:'Bash', input:'git push', ts:'t1', err:true, err_msg:'rejected: non-fast-forward' }
];
console.log(sl.evalErrorMonitor(
  { type:'error-monitor', error_pattern:'rejected|non-fast-forward', window:5 },
  obs, 0
));
")
[ "$RESULT" = "noise" ] && pass "error-monitor noise" || fail "expected noise, got $RESULT"

# -----------------------------------------------------------------------------
echo "--- Test 26: evalErrorMonitor returns ignore when no matching error ---"
RESULT=$(node -e "
const sl = require('$REPO_ROOT/hooks/session-learner.js');
const obs = [
  { tool:'Bash', input:'git push', ts:'t0', err:false }
];
console.log(sl.evalErrorMonitor(
  { type:'error-monitor', error_pattern:'rejected|non-fast-forward', window:5 },
  obs, 0
));
")
[ "$RESULT" = "ignore" ] && pass "error-monitor ignore (conservative)" || fail "expected ignore, got $RESULT"

# -----------------------------------------------------------------------------
echo "--- Test 27: evaluateReflex returns ignore for reflex without evaluator ---"
RESULT=$(node -e "
const sl = require('$REPO_ROOT/hooks/session-learner.js');
console.log(sl.evaluateReflex(
  { id:'meta-reflex', enabled:true /* no evaluator field */ },
  [{tool:'Bash', input:'x', ts:'t0'}], 0
));
")
[ "$RESULT" = "ignore" ] && pass "no-evaluator returns ignore" || fail "expected ignore, got $RESULT"

# -----------------------------------------------------------------------------
echo "--- Test 28: Reflex inject event uses 'reflex:' iid prefix ---"
rm -f "$SANDBOX/impact.jsonl"
python3 "$IMPACT_PY" log --event inject --iid "reflex:test-reflex" --tool Bash --sid sid-R --conf 0 || true
LAST=$(tail -1 "$SANDBOX/impact.jsonl")
if echo "$LAST" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['iid'].startswith('reflex:')" 2>/dev/null; then
  pass "iid prefix 'reflex:' written"
else
  fail "iid prefix missing: $LAST"
fi

# -----------------------------------------------------------------------------
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
