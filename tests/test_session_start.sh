#!/usr/bin/env bash
# test_session_start.sh — v3.29.0 (Sprint 8 §4.10)
#
# Covers check_maintenance() banner gating: the [ACTION] reminder must
# count only proposals in VALIDATE_AUTO_DOMAINS (the auto-validate
# whitelist), so HUMAN-gated detectors don't generate permanent nag.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

SESSION_START_PY="$PROJECT_ROOT/hooks/session-start.py"
HOOK_DIR="$(dirname "$SESSION_START_PY")"

# All three sub-cases drive check_maintenance() directly. We import the
# script as a module, retarget its CORTEX_DIR constant at a sandbox, write
# a proposals.json fixture there, and assert on the returned reminders.

run_check() {
  # $1 = sandbox dir
  python3 - <<PYEOF
import sys
sys.path.insert(0, '$HOOK_DIR')
sys.path.insert(0, '$HOOK_DIR/lib')
# Import then retarget — session-start.py looks at CORTEX_DIR at call time
# via attribute access, so monkey-patching the module attribute is enough.
import importlib.util
spec = importlib.util.spec_from_file_location('session_start', '$SESSION_START_PY')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
from pathlib import Path
mod.CORTEX_DIR = Path('$1')
out = mod.check_maintenance()
for line in out:
    print(line)
PYEOF
}

echo "=== Session-Start [ACTION] Banner Tests (v3.29.0 §4.10) ==="

# ── Test 1: 50 HUMAN-gated pending → NO [ACTION] reminder ────────────────────
echo "--- Test 1: 50 HUMAN, 0 AUTO ---"
T1="$(mktemp -d -t cortex-sstart-t1-XXXXXX)"
trap 'rm -rf "$T1"' EXIT
python3 - <<PYEOF
import json
proposals = []
for i in range(50):
    domain = ['correction', 'coupling', 'agent-quality', 'user-preference', 'workflow'][i % 5]
    proposals.append({
        'id': f't1-{i}',
        'trigger': 'Edit',
        'action': 'review pattern',
        'confidence': 0.55,
        'domain': domain,
        'scope': 'project',
        'project_id': 'p',
        'status': 'pending',
    })
with open('$T1/proposals.json', 'w') as f:
    json.dump(proposals, f)
PYEOF
out=$(run_check "$T1")
if echo "$out" | grep -q '\[ACTION\] .* pending proposals'; then
    fail "T1 HUMAN-only: [ACTION] still firing → $(echo "$out" | grep '\[ACTION\]')"
else
    pass "T1 HUMAN-only (50 proposals): NO [ACTION] reminder"
fi

# ── Test 2: 5 AUTO + 50 HUMAN → [ACTION] counts only the AUTO ones ───────────
# v4: VALIDATE_AUTO_DOMAINS shrank (error-recovery moved AUTO -> HUMAN, see
# docs/DESIGN-V4.md §2). Pull the set LIVE from distill_engine instead of
# hardcoding domain names here, so this test tracks the engine's whitelist
# instead of silently drifting out of sync with it again.
echo "--- Test 2: 5 AUTO + 50 HUMAN ---"
T2="$(mktemp -d -t cortex-sstart-t2-XXXXXX)"
python3 - <<PYEOF
import json, sys
sys.path.insert(0, '$HOOK_DIR/lib')
from distill_engine import VALIDATE_AUTO_DOMAINS
auto_domains = sorted(VALIDATE_AUTO_DOMAINS)
assert auto_domains, "VALIDATE_AUTO_DOMAINS is empty — test needs at least one AUTO domain"

proposals = []
# 5 proposals cycling through the LIVE auto-domain set.
for i in range(5):
    domain = auto_domains[i % len(auto_domains)]
    proposals.append({
        'id': f't2-auto-{i}', 'trigger': 'Bash', 'action': 'a', 'confidence': 0.60,
        'domain': domain, 'status': 'pending',
    })
# 50 HUMAN-domain proposals — pick domains guaranteed NOT in the auto set.
human_pool = [d for d in ['correction', 'coupling', 'agent-quality', 'decision',
                          'workflow', 'user-preference'] if d not in VALIDATE_AUTO_DOMAINS]
assert human_pool, "no human domain candidate outside VALIDATE_AUTO_DOMAINS"
for i in range(50):
    domain = human_pool[i % len(human_pool)]
    proposals.append({
        'id': f't2-human-{i}', 'trigger': 'Edit', 'action': 'b', 'confidence': 0.55,
        'domain': domain, 'status': 'pending',
    })
with open('$T2/proposals.json', 'w') as f:
    json.dump(proposals, f)
with open('$T2/.expected_auto_count', 'w') as f:
    f.write('5')
PYEOF
EXPECTED=$(cat "$T2/.expected_auto_count")
out=$(run_check "$T2")
if echo "$out" | grep -q "\[ACTION\] $EXPECTED pending proposals"; then
    pass "T2 mixed: [ACTION] reports $EXPECTED (only live AUTO domains counted)"
else
    fail "T2 mixed: expected '[ACTION] $EXPECTED pending', got '$(echo "$out" | grep '\[ACTION\]' || echo "(none)")'"
fi
rm -rf "$T2"

# ── Test 3: malformed proposals.json → no crash, no [ACTION] ─────────────────
echo "--- Test 3: malformed proposals.json ---"
T3="$(mktemp -d -t cortex-sstart-t3-XXXXXX)"
echo 'not json {' > "$T3/proposals.json"
out=$(run_check "$T3" 2>&1)
if echo "$out" | grep -q '\[ACTION\]'; then
    fail "T3 malformed: [ACTION] fired on bad JSON"
elif echo "$out" | grep -qi 'traceback\|exception'; then
    fail "T3 malformed: crashed on bad JSON → $out"
else
    pass "T3 malformed: no [ACTION], no crash"
fi
rm -rf "$T3"

# Already-accepted proposals are not counted either (sanity — same path,
# different filter, but worth a guard so a future regression on the
# `status == 'pending'` check doesn't slip through silently).
echo "--- Test 4: only AUTO with status='accepted' → NO [ACTION] ---"
T4="$(mktemp -d -t cortex-sstart-t4-XXXXXX)"
python3 - <<PYEOF
import json
proposals = [
    {'id': 't4-1', 'trigger': 'Bash', 'action': 'a', 'confidence': 0.60,
     'domain': 'gotcha', 'status': 'accepted'},
    {'id': 't4-2', 'trigger': 'Bash', 'action': 'a', 'confidence': 0.60,
     'domain': 'pattern', 'status': 'rejected'},
]
with open('$T4/proposals.json', 'w') as f:
    json.dump(proposals, f)
PYEOF
out=$(run_check "$T4")
if echo "$out" | grep -q '\[ACTION\]'; then
    fail "T4 accepted/rejected: [ACTION] fired (should not)"
else
    pass "T4 accepted/rejected: NO [ACTION] reminder"
fi
rm -rf "$T4"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
