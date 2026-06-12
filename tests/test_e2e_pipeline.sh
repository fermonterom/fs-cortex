#!/usr/bin/env bash
# test_e2e_pipeline.sh — v3.29.0 (Sprint 8 §4.11)
#
# End-to-end pipeline test: synthetic paired Pre/Post observations →
# session-learner.js (Stop hook) → proposals.json → distill_engine
# (auto_validate + auto_promote) → asserts on the resulting instinct/law
# artefacts. Catches bugs that unit tests miss because they only see
# a single stage of the pipeline.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

LEARNER="$PROJECT_ROOT/hooks/session-learner.js"

# Build a sandbox with the per-project observations layout the Stop hook
# expects. PROJ_ID matches what observe.py.detect_project would produce
# but we skip observe.py entirely and write observations.jsonl directly —
# the goal here is to exercise session-learner.js + distill_engine.py
# end-to-end, not observe.py (which has its own suite).
make_sandbox() {
  local s; s="$(mktemp -d -t cortex-e2e-XXXXXX)"
  local pid="proj-e2e"
  mkdir -p "$s/projects/$pid" "$s/instincts/global" "$s/laws"
  cat > "$s/projects/registry.json" <<JSON
{ "$pid": { "name": "e2e-proj", "root": "/tmp/e2e" } }
JSON
  echo "$s|$pid"
}

# Append synthetic paired Pre/Post events to the per-project observations.
# Tools that produce errors get err=true + an error-shaped output; the
# follow-up Edit/Bash call is what session-learner pairs with them to
# emit an error-fix gotcha.
append_error_fix() {
  local file="$1" sid="$2" ts_base="$3"
  # v3.37.0 contract:
  # 1. ts event carries the failing input (distinctive tokens for trigger derivation).
  # 2. tc event carries err_msg (required; without it the detector skips the observation).
  # 3. fix observation follows as a non-error tc event within the WINDOW.
  cat >> "$file" <<JSON
{"ts":"${ts_base}T10:00:00Z","ev":"ts","tool":"Bash","input":"{\"command\":\"pnpm run build --workspace api\"}","sid":"$sid","pid":"proj-e2e"}
{"ts":"${ts_base}T10:00:01Z","ev":"tc","tool":"Bash","err":true,"err_msg":"pnpm run build failed","output":"Error: 1 test failed","sid":"$sid","pid":"proj-e2e"}
{"ts":"${ts_base}T10:01:00Z","ev":"ts","tool":"Edit","input":"{\"file_path\":\"/tmp/e2e/src/app.ts\"}","sid":"$sid","pid":"proj-e2e"}
{"ts":"${ts_base}T10:01:01Z","ev":"tc","tool":"Edit","output":"ok","err":false,"sid":"$sid","pid":"proj-e2e"}
JSON
}

# Drive session-learner.js with the given harness session-id payload.
# Each call runs the Stop hook pipeline for ONE session in the sandbox.
run_learner() {
  local sandbox="$1" sid="$2"
  CORTEX_DIR="$sandbox" \
    bash -c "echo '{\"session_id\":\"$sid\"}' | node '$LEARNER'" >/dev/null 2>&1 || true
}

# Drive run_auto_distill in the sandbox by retargeting the module paths.
run_distill() {
  local sandbox="$1"
  CORTEX_DIR="$sandbox" python3 - <<PYEOF
import sys, os
sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$sandbox')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
de.PROPOSALS_FILE = de.CORTEX_DIR / 'proposals.json'
de.EVOLVED_SKILLS_DIR = de.CORTEX_DIR / 'evolved' / 'skills'
de.SKILLS_DIR = de.CORTEX_DIR / 'skills'
de.INSTINCT_TRACKING_FILE = de.CORTEX_DIR / 'instinct-tracking.json'
print(de.run_auto_distill())
PYEOF
}

echo "=== E2E Pipeline Tests (v3.29.0 §4.11) ==="

# ── Test 1: error-fix → proposal → instinct → /cx-validate happy path ────────
echo "--- Test 1: error-fix happy path ---"
out="$(make_sandbox)"; T1="${out%|*}"; PID1="${out##*|}"
append_error_fix "$T1/projects/$PID1/observations.jsonl" "sess-e2e-1" "2026-05-15"
run_learner "$T1" "sess-e2e-1"
# Stop hook should have produced at least one error-recovery proposal.
if [ -f "$T1/proposals.json" ] && python3 -c "
import json, sys
data = json.load(open('$T1/proposals.json'))
auto = [p for p in data if p.get('domain') == 'error-recovery']
sys.exit(0 if auto else 1)
"; then
  pass "Stop hook → proposals.json with error-recovery proposal"
else
  fail "Stop hook → no error-recovery proposal emitted"
fi

# Now run auto-distill: the AUTO-domain proposal should auto-validate
# into an instinct YAML.
run_distill "$T1" >/dev/null 2>&1 || true
# Use find (not ls + glob) because under `set -euo pipefail` a glob that
# matches zero files makes `ls` exit non-zero and pipefail kills the script.
inst_count=$(find "$T1/instincts/global" -maxdepth 1 -name 'gotcha-*.yaml' 2>/dev/null | wc -l | tr -d ' ')
[ "$inst_count" -ge "1" ] && pass "auto-distill → gotcha-*.yaml instinct materialised" \
                          || fail "auto-distill → no instinct file created"
rm -rf "$T1"

# ── Test 2: HUMAN-gated proposal stays pending across the pipeline ───────────
echo "--- Test 2: HUMAN-gated proposal not auto-promoted ---"
out="$(make_sandbox)"; T2="${out%|*}"; PID2="${out##*|}"
# Five sessions of foo.ts+bar.ts edits trip file-coupling (§4.2).
for i in 1 2 3 4 5; do
  cat >> "$T2/projects/$PID2/observations.jsonl" <<JSON
{"ts":"2026-05-15T10:0${i}:00Z","ev":"PostToolUse","tool":"Edit","input":"{\"file_path\":\"/tmp/e2e/foo.ts\"}","output":"ok","sid":"sess-e2e-2-${i}","pid":"proj-e2e"}
{"ts":"2026-05-15T10:0${i}:30Z","ev":"PostToolUse","tool":"Edit","input":"{\"file_path\":\"/tmp/e2e/bar.ts\"}","output":"ok","sid":"sess-e2e-2-${i}","pid":"proj-e2e"}
JSON
  run_learner "$T2" "sess-e2e-2-${i}"
done
# At least one coupling-* proposal must be in proposals.json after the Stop runs.
coupling_count=$(python3 -c "
import json
try:
    data = json.load(open('$T2/proposals.json'))
    print(sum(1 for p in data if p.get('domain') == 'coupling'))
except Exception:
    print(0)
")
[ "$coupling_count" -ge "1" ] && pass "Stop hook → coupling proposal emitted" \
                              || fail "Stop hook → no coupling proposal (got $coupling_count)"

# auto-distill should SKIP it as needs-human-judgment (NOT create instinct).
run_distill "$T2" >/dev/null 2>&1 || true
coupling_inst=$(find "$T2/instincts/global" -maxdepth 1 -name 'coupling-*.yaml' 2>/dev/null | wc -l | tr -d ' ')
[ "$coupling_inst" = "0" ] && pass "auto-distill → coupling proposal NOT materialised (HUMAN-gated)" \
                           || fail "auto-distill leaked HUMAN-gated coupling into instinct YAML"
# Status must still be pending.
status_ok=$(python3 -c "
import json
data = json.load(open('$T2/proposals.json'))
c = next((p for p in data if p.get('domain') == 'coupling'), None)
print('OK' if c and c.get('status') == 'pending' else 'FAIL')
")
[ "$status_ok" = "OK" ] && pass "auto-distill → coupling proposal remains status=pending" \
                       || fail "auto-distill mutated coupling status"
rm -rf "$T2"

# ── Test 3: CORTEX_DETECTORS_OFF intercepts the Stop hook ────────────────────
echo "--- Test 3: CORTEX_DETECTORS_OFF in Stop hook ---"
out="$(make_sandbox)"; T3="${out%|*}"; PID3="${out##*|}"
append_error_fix "$T3/projects/$PID3/observations.jsonl" "sess-e2e-3" "2026-05-15"
CORTEX_DIR="$T3" CORTEX_DETECTORS_OFF=1 \
  bash -c "echo '{\"session_id\":\"sess-e2e-3\"}' | node '$LEARNER'" >/dev/null 2>&1 || true
if [ -f "$T3/proposals.json" ]; then
  fail "DETECTORS_OFF in Stop: proposals.json was created"
else
  pass "DETECTORS_OFF in Stop: proposals.json NOT created"
fi
rm -rf "$T3"

# ── Test 4: CORTEX_AUTODISTILL_OFF intercepts SessionStart auto-distill ──────
echo "--- Test 4: CORTEX_AUTODISTILL_OFF in SessionStart ---"
out="$(make_sandbox)"; T4="${out%|*}"; PID4="${out##*|}"
append_error_fix "$T4/projects/$PID4/observations.jsonl" "sess-e2e-4" "2026-05-15"
run_learner "$T4" "sess-e2e-4"
# Confirm a proposal exists and is pending.
pre_pending=$(python3 -c "
import json
data = json.load(open('$T4/proposals.json'))
print(sum(1 for p in data if p.get('status') == 'pending'))
")
if [ "$pre_pending" -lt "1" ]; then
  fail "pre-condition: expected a pending proposal, got $pre_pending"
  rm -rf "$T4"
else
CORTEX_DIR="$T4" CORTEX_AUTODISTILL_OFF=1 python3 - <<PYEOF
import sys
sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T4')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.PROPOSALS_FILE = de.CORTEX_DIR / 'proposals.json'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
de.run_auto_distill()
PYEOF
post_inst=$(find "$T4/instincts/global" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
[ "$post_inst" = "0" ] && pass "AUTODISTILL_OFF in SessionStart: no instinct materialised" \
                       || fail "AUTODISTILL_OFF leaked: $post_inst instinct(s) created"
[ ! -e "$T4/.last-auto-distill" ] && pass "AUTODISTILL_OFF: no .last-auto-distill marker" \
                                   || fail "AUTODISTILL_OFF: marker file appeared"
rm -rf "$T4"
fi  # closes pre-condition guard

# ── Test 5: ghost guard restores cx-validate-auto bulk-reject end-to-end ─────
echo "--- Test 5: ghost guard end-to-end ---"
out="$(make_sandbox)"; T5="${out%|*}"; PID5="${out##*|}"
append_error_fix "$T5/projects/$PID5/observations.jsonl" "sess-e2e-5" "2026-05-15"
run_learner "$T5" "sess-e2e-5"
# Simulate the ghost: stamp the auto-domain proposal as rejected by the
# unauthorized identity.
python3 - <<PYEOF
import json
path = '$T5/proposals.json'
data = json.load(open(path))
for p in data:
    if p.get('domain') == 'error-recovery':
        p['status'] = 'rejected'
        p['rejected_by'] = 'cx-validate-auto'
        p['rejected_reason'] = 'ghost-bulk'
        p['rejected_at'] = '2026-05-05'
json.dump(data, open(path, 'w'))
PYEOF

run_distill "$T5" >/dev/null 2>&1 || true
# After distill: ghost guard restores to pending → same pass auto-validates →
# instinct YAML exists AND proposal status is 'accepted'.
final_state=$(python3 -c "
import json
data = json.load(open('$T5/proposals.json'))
p = next((p for p in data if p.get('domain') == 'error-recovery'), None)
print(p.get('status') if p else 'missing')
")
inst_after=$(find "$T5/instincts/global" -maxdepth 1 -name 'gotcha-*.yaml' 2>/dev/null | wc -l | tr -d ' ')
[ "$final_state" = "accepted" ] && pass "ghost-guard E2E: proposal status=accepted after restore+validate" \
                                || fail "ghost-guard E2E: status=$final_state (expected 'accepted')"
[ "$inst_after" -ge "1" ] && pass "ghost-guard E2E: instinct materialised after ghost restoration" \
                          || fail "ghost-guard E2E: no instinct after restoration"
rm -rf "$T5"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
