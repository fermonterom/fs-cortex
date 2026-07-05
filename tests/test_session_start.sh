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

# ── Test 4b: fresh maintain digest emits informative badge ─────────────────
echo "--- Test 4b: fresh maintain digest badge ---"
T4B="$(mktemp -d -t cortex-sstart-t4b-XXXXXX)"
python3 - <<PYEOF
import json
from datetime import datetime
from pathlib import Path
Path('$T4B/.review-digest.json').write_text(json.dumps({
    'generated_at': datetime.utcnow().isoformat(),
    'proposals_human_gated': 2,
    'swaps_last_run': [{'in': 'new-law', 'out': 'old-law'}],
    'expired_last_run': 3,
    'total_items': 2,
}), encoding='utf-8')
PYEOF
out=$(python3 - <<PYEOF
import sys, importlib.util
from pathlib import Path
sys.path.insert(0, '$HOOK_DIR')
sys.path.insert(0, '$HOOK_DIR/lib')
spec = importlib.util.spec_from_file_location('session_start', '$SESSION_START_PY')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.CORTEX_DIR = Path('$T4B')
print(mod.check_review_digest() or '')
PYEOF
)
if echo "$out" | grep -q '^\[cx\] maintain:' && echo "$out" | grep -q '+new-law (jubilada old-law)' && echo "$out" | grep -q '3 propuestas caducadas'; then
    pass "T4b fresh digest: informative [cx] maintain badge"
else
    fail "T4b fresh digest: unexpected badge → $out"
fi
rm -rf "$T4B"

# ── Test 4c: stale maintain digest (>48h) emits no badge ───────────────────
echo "--- Test 4c: stale maintain digest ignored ---"
T4C="$(mktemp -d -t cortex-sstart-t4c-XXXXXX)"
python3 - <<PYEOF
import json
from datetime import datetime, timedelta
from pathlib import Path
Path('$T4C/.review-digest.json').write_text(json.dumps({
    'generated_at': (datetime.utcnow() - timedelta(hours=49)).isoformat(),
    'proposals_human_gated': 2,
    'swaps_last_run': [{'in': 'new-law', 'out': 'old-law'}],
    'expired_last_run': 3,
    'total_items': 2,
}), encoding='utf-8')
PYEOF
out=$(python3 - <<PYEOF
import sys, importlib.util
from pathlib import Path
sys.path.insert(0, '$HOOK_DIR')
sys.path.insert(0, '$HOOK_DIR/lib')
spec = importlib.util.spec_from_file_location('session_start', '$SESSION_START_PY')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.CORTEX_DIR = Path('$T4C')
print(mod.check_review_digest() or '')
PYEOF
)
if [ -z "$out" ]; then
    pass "T4c stale digest: no badge after 48h"
else
    fail "T4c stale digest: unexpected badge → $out"
fi
rm -rf "$T4C"

echo ""

# ── Test 5: malformed laws-meta.json shapes → no crash, laws still load ──────
# AD [P2] finding: laws-meta.json can be malformed in shapes load_laws() must
# tolerate without crashing SessionStart. Unlike Tests 1-4 (which drive
# check_maintenance() via module import), these drive the FULL process via
# stdin pipe (`CORTEX_DIR=... python3 hooks/session-start.py`) since the tier
# split happens in main(), not in a function importable in isolation.
echo "--- Test 5: malformed laws-meta.json (v non-dict, laws non-dict, invalid JSON) ---"
run_full_hook() {
  # $1 = sandbox CORTEX_DIR
  echo '{}' | CORTEX_DIR="$1" python3 "$SESSION_START_PY" 2>&1
}

declare -a T5_CASES=(
  '{"laws":{"x":"tool"}}'
  '{"laws":[]}'
  'xxx'
)
T5_LABELS=(
  "v non-dict"
  "laws non-dict"
  "invalid JSON"
)
for i in "${!T5_CASES[@]}"; do
  T5="$(mktemp -d -t cortex-sstart-t5-XXXXXX)"
  mkdir -p "$T5/laws"
  echo "Fixture law text" > "$T5/laws/a-fixture.txt"
  printf '%s' "${T5_CASES[$i]}" > "$T5/laws/laws-meta.json"
  out=$(run_full_hook "$T5")
  label="${T5_LABELS[$i]}"
  if echo "$out" | grep -qi 'traceback\|exception'; then
    fail "T5 laws-meta ($label): crashed → $out"
  elif echo "$out" | grep -q 'CORTEX LAWS'; then
    pass "T5 laws-meta ($label): no crash, CORTEX LAWS present"
  else
    fail "T5 laws-meta ($label): no crash but CORTEX LAWS missing → $out"
  fi
  rm -rf "$T5"
done

# ── Test 6: well-formed laws-meta.json → tier split [principios]/[herramienta] ─
echo "--- Test 6: well-formed laws-meta.json splits by tier ---"
T6="$(mktemp -d -t cortex-sstart-t6-XXXXXX)"
mkdir -p "$T6/laws"
echo "Principle law text" > "$T6/laws/a-principle.txt"
echo "Tool law text" > "$T6/laws/b-tool.txt"
printf '%s' '{"laws":{"a-principle":{"tier":"principle"},"b-tool":{"tier":"tool"}}}' > "$T6/laws/laws-meta.json"
out=$(run_full_hook "$T6")
if echo "$out" | grep -q '\[principios\]' && echo "$out" | grep -q '\[herramienta\]'; then
    pass "T6 well-formed laws-meta: both [principios] and [herramienta] present"
else
    fail "T6 well-formed laws-meta: missing tier split → $out"
fi
rm -rf "$T6"

# ── Test 7: no laws-meta.json → single CORTEX LAWS block (retrocompat) ───────
echo "--- Test 7: no laws-meta.json (retrocompat, single block) ---"
T7="$(mktemp -d -t cortex-sstart-t7-XXXXXX)"
mkdir -p "$T7/laws"
echo "Some law text" > "$T7/laws/a.txt"
out=$(run_full_hook "$T7")
if echo "$out" | grep -q 'CORTEX LAWS'; then
    if echo "$out" | grep -q '\[principios\]\|\[herramienta\]'; then
        fail "T7 no laws-meta: unexpected tier split without meta file → $out"
    else
        pass "T7 no laws-meta: single CORTEX LAWS block, no tier split"
    fi
else
    fail "T7 no laws-meta: CORTEX LAWS missing → $out"
fi
rm -rf "$T7"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
