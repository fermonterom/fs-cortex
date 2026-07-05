#!/usr/bin/env bash
# test_curate.sh — v4.4.0 /cx-curate engine support tests.
# Scope: the curate additions to hooks/lib/distill_engine.py ONLY:
#   1. apply_confidence_downvote reduces confidence and logs the vote.
#   2. Downvotes respect the CURATE_CONF_FLOOR (0.30) — clamp, then no-op.
#   3. Unknown instinct id returns (False, msg) without side effects.
#   4. curate_snapshot returns the laws/candidates/instincts corpus dict.
#   5. curate_due marker cadence (missing marker = due; touch = not due).
#   6. `curate-snapshot` CLI subcommand prints valid JSON.
# The curation VOTES themselves (which law to demote, what to downvote)
# are the /cx-curate command's LLM judgment — out of scope here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

SANDBOX="$(mktemp -d -t cortex-curate-test-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== Curate Engine Tests (sandbox: $SANDBOX) ==="
echo

# ── Helper: write a minimal instinct YAML ────────────────────────────────────
# make_instinct <dir> <id> <conf> <extra_fields...>
# extra_fields is raw multiline YAML appended inside the frontmatter block.
make_instinct() {
  local dir="$1" iid="$2" conf="$3"
  shift 3
  local extra="${*:-}"
  mkdir -p "$dir"
  cat > "$dir/${iid}.yaml" <<YAML
---
id: ${iid}
confidence: ${conf}
domain: testing
trigger: 'SomeTool'
action: 'Always do the thing for testing'
last_seen: 2026-07-01
first_seen: 2026-06-01
project_id: proj-alpha
project_name: test-project
${extra}
---
YAML
}

# Common preamble: import distill_engine with CORTEX_DIR pointed at $1,
# redundantly re-pinning every module-level path constant (belt-and-
# suspenders — matches tests/test_distill_v4.sh convention; the
# `export CORTEX_DIR` before invoking python already makes this correct
# at import time, this just guards against import-order surprises).
py_preamble() {
  local dir="$1"
  cat <<PY
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$dir'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$dir')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.LAWS_META_FILE = de.LAWS_DIR / 'laws-meta.json'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
de.INSTINCT_TRACKING_FILE = de.CORTEX_DIR / 'instinct-tracking.json'
de.CURATE_MARKER_FILE = de.CORTEX_DIR / '.last-curate'
PY
}

# ── Test 1: downvote reduces confidence and logs the vote ────────────────────
echo "--- Test 1: downvote-reduces-confidence ---"
T1="$SANDBOX/t1"
make_instinct "$T1/instincts/global" "t1-noisy" "0.8000"

result=$(python3 -c "
$(py_preamble "$T1")
ok, msg = de.apply_confidence_downvote('t1-noisy', reason='curator vote')
fields, _ = de._read_instinct(de.INSTINCTS_DIR / 't1-noisy.yaml')
klog = de.KNOWLEDGE_LOG.read_text() if de.KNOWLEDGE_LOG.exists() else ''
logged = 'downvoted' in klog and 't1-noisy' in klog and 'cx-curate' in klog
print(ok, abs(float(fields['confidence']) - 0.65) < 1e-9, logged)
")
if echo "$result" | grep -q "^True True True$"; then
  pass "downvote-reduces-confidence: 0.80 -> 0.65, logged as downvoted/cx-curate"
else
  fail "downvote-reduces-confidence: got '$result'"
fi

# ── Test 2: downvote clamps at the 0.30 floor, then refuses ──────────────────
echo "--- Test 2: downvote-respects-floor ---"
T2="$SANDBOX/t2"
make_instinct "$T2/instincts/global" "t2-near-floor" "0.4000"

result=$(python3 -c "
$(py_preamble "$T2")
ok1, msg1 = de.apply_confidence_downvote('t2-near-floor')
fields, _ = de._read_instinct(de.INSTINCTS_DIR / 't2-near-floor.yaml')
clamped = abs(float(fields['confidence']) - de.CURATE_CONF_FLOOR) < 1e-9
ok2, msg2 = de.apply_confidence_downvote('t2-near-floor')
print(ok1, clamped, not ok2, 'floor' in msg2)
")
if echo "$result" | grep -q "^True True True True$"; then
  pass "downvote-respects-floor: clamped 0.40 -> 0.30, second vote refused"
else
  fail "downvote-respects-floor: got '$result'"
fi

# ── Test 3: unknown instinct id returns (False, msg) ─────────────────────────
echo "--- Test 3: downvote-unknown-id ---"
T3="$SANDBOX/t3"
make_instinct "$T3/instincts/global" "t3-bystander" "0.7000"

result=$(python3 -c "
$(py_preamble "$T3")
ok, msg = de.apply_confidence_downvote('t3-ghost')
fields, _ = de._read_instinct(de.INSTINCTS_DIR / 't3-bystander.yaml')
untouched = abs(float(fields['confidence']) - 0.70) < 1e-9
print(not ok, 't3-ghost' in msg, untouched)
")
if echo "$result" | grep -q "^True True True$"; then
  pass "downvote-unknown-id: returns False with id in msg, bystander untouched"
else
  fail "downvote-unknown-id: got '$result'"
fi

# ── Test 4: curate_snapshot returns the corpus dict on a seeded sandbox ─────
echo "--- Test 4: curate-snapshot-shape ---"
T4="$SANDBOX/t4"
mkdir -p "$T4/laws"
echo "Always test the thing before shipping it" > "$T4/laws/law-seeded.txt"
make_instinct "$T4/instincts/global" "t4-instinct" "0.7500"

result=$(python3 -c "
$(py_preamble "$T4")
snap = de.curate_snapshot()
keys_ok = all(k in snap for k in ('laws', 'candidates', 'instincts', 'generated_at'))
law = snap['laws'].get('law-seeded', {})
law_ok = (
    law.get('content') == 'Always test the thing before shipping it'
    and law.get('tier') == 'principle'
    and isinstance(law.get('age_days'), int)
    and law.get('impact_30d') == {'useful': 0, 'noise': 0}
    and law.get('has_backing_instinct') is False
)
inst = next((i for i in snap['instincts'] if i['id'] == 't4-instinct'), None)
inst_ok = (
    inst is not None
    and abs(float(inst['confidence']) - 0.75) < 1e-9
    and inst['trigger'] == 'SomeTool'
    and inst['impact_30d'] == {'useful': 0, 'noise': 0}
)
print(isinstance(snap, dict), keys_ok, law_ok, inst_ok, isinstance(snap['candidates'], list))
")
if echo "$result" | grep -q "^True True True True True$"; then
  pass "curate-snapshot-shape: laws/candidates/instincts/generated_at populated"
else
  fail "curate-snapshot-shape: got '$result'"
fi

# ── Test 5: curate_due marker cadence ────────────────────────────────────────
echo "--- Test 5: curate-due-marker ---"
T5="$SANDBOX/t5"
mkdir -p "$T5"

result=$(python3 -c "
$(py_preamble "$T5")
due_before = de.curate_due()
de.touch_curate_marker()
due_after = de.curate_due()
marker_iso = de.CURATE_MARKER_FILE.read_text().strip()
import datetime
parseable = bool(datetime.datetime.fromisoformat(marker_iso))
print(due_before, not due_after, de.CURATE_MARKER_FILE.exists(), parseable)
")
if echo "$result" | grep -q "^True True True True$"; then
  pass "curate-due-marker: due without marker, not due right after touch, ISO content"
else
  fail "curate-due-marker: got '$result'"
fi

# ── Test 6: curate-snapshot CLI prints valid JSON ────────────────────────────
echo "--- Test 6: curate-snapshot-cli ---"
T6="$SANDBOX/t6"
mkdir -p "$T6/laws"
echo "CLI law unique content" > "$T6/laws/law-cli.txt"
make_instinct "$T6/instincts/global" "t6-cli-instinct" "0.6000"

cli_out=$(CORTEX_DIR="$T6" python3 "$PROJECT_ROOT/hooks/lib/distill_engine.py" curate-snapshot)
result=$(printf '%s' "$cli_out" | python3 -c "
import json, sys
snap = json.load(sys.stdin)
print(
    all(k in snap for k in ('laws', 'candidates', 'instincts', 'generated_at')),
    'law-cli' in snap['laws'],
    any(i['id'] == 't6-cli-instinct' for i in snap['instincts']),
)
")
if echo "$result" | grep -q "^True True True$"; then
  pass "curate-snapshot-cli: stdout is valid JSON with the seeded corpus"
else
  fail "curate-snapshot-cli: got '$result'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
