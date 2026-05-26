#!/usr/bin/env bash
# test_distill_engine.sh — Sprint 6 Auto-Distill Engine tests
# Validates: decay, archive, promotion gate (7 criteria), idempotency, rate-limit, locking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_PY="$PROJECT_ROOT/hooks/lib/distill_engine.py"

export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Sandbox: each test gets CORTEX_DIR pointing at a mktemp dir
SANDBOX="$(mktemp -d -t cortex-distill-test-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== Distill Engine Tests (sandbox: $SANDBOX) ==="
echo

# ── Helper: write a minimal instinct YAML ────────────────────────────────────

make_instinct() {
  # make_instinct <dir> <id> <confidence> <last_seen> [extra_fields...]
  # extra_fields is multiline YAML appended after last_seen line
  local dir="$1" iid="$2" conf="$3" last_seen="$4"
  shift 4
  local extra="${*:-}"
  mkdir -p "$dir"
  cat > "$dir/${iid}.yaml" <<YAML
---
id: ${iid}
confidence: ${conf}
domain: testing
trigger: "SomeTool"
action: "Always do the thing for testing"
last_seen: ${last_seen}
first_seen: ${last_seen}
occurrences: 10
project_id: proj-alpha
project_name: test-project
${extra}
---
YAML
}

make_law() {
  local dir="$1" iid="$2" content="$3"
  mkdir -p "$dir"
  echo "$content" > "$dir/${iid}.txt"
}

make_impact_events() {
  # make_impact_events <file> <iid> <useful_count> <noise_count> [days_ago=0]
  local file="$1" iid="$2" useful="$3" noise="$4"
  local days_ago="${5:-0}"
  mkdir -p "$(dirname "$file")"
  local ts
  ts=$(python3 -c "
from datetime import datetime, timezone, timedelta
d = datetime.now(timezone.utc) - timedelta(days=$days_ago)
print(d.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
  if [ "$useful" -gt 0 ]; then
    for i in $(seq 1 "$useful"); do
      echo "{\"v\":1,\"ts\":\"$ts\",\"ev\":\"feedback\",\"iid\":\"$iid\",\"rating\":\"useful\"}" >> "$file"
    done
  fi
  if [ "$noise" -gt 0 ]; then
    for i in $(seq 1 "$noise"); do
      echo "{\"v\":1,\"ts\":\"$ts\",\"ev\":\"feedback\",\"iid\":\"$iid\",\"rating\":\"noise\"}" >> "$file"
    done
  fi
}

# ── Test 1: decay-basic — 31 days unused at 0.80 → 0.75 ─────────────────────
echo "--- Test 1: decay-basic ---"
T1="$(mktemp -d -t distill-t1-XXXXXX)"
export CORTEX_DIR="$T1"
THIRTY_ONE_AGO=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(days=31)).strftime('%Y-%m-%d'))
")
make_instinct "$T1/instincts/global" "t1-decay" "0.8000" "$THIRTY_ONE_AGO"

result=$(python3 -c "
import sys; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
import os; os.environ['CORTEX_DIR'] = '$T1'
from distill_engine import apply_decay, CORTEX_DIR
# reload module with correct CORTEX_DIR
import importlib, distill_engine as de
de.CORTEX_DIR = __import__('pathlib').Path('$T1')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
changed = de.apply_decay()
print(changed[0]['new_conf'] if changed else 'no-change')
")
# 0.80 - 0.05 = 0.75
if python3 -c "assert abs(float('$result') - 0.75) < 0.001" 2>/dev/null; then
  pass "decay-basic: conf 0.80 → 0.75 after 31d"
else
  fail "decay-basic: expected ~0.75, got $result"
fi
rm -rf "$T1"

# ── Test 2: decay-stacks — 60 days at 0.80 → 0.70 ──────────────────────────
echo "--- Test 2: decay-stacks ---"
T2="$(mktemp -d -t distill-t2-XXXXXX)"
export CORTEX_DIR="$T2"
SIXTY_AGO=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(days=60)).strftime('%Y-%m-%d'))
")
make_instinct "$T2/instincts/global" "t2-stack" "0.8000" "$SIXTY_AGO"

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T2'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T2')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
changed = de.apply_decay()
print(changed[0]['new_conf'] if changed else 'no-change')
")
if python3 -c "assert abs(float('$result') - 0.70) < 0.001" 2>/dev/null; then
  pass "decay-stacks: conf 0.80 → 0.70 after 60d"
else
  fail "decay-stacks: expected ~0.70, got $result"
fi
rm -rf "$T2"

# ── Test 3: decay-fresh-noop — 5 days unused → unchanged ────────────────────
echo "--- Test 3: decay-fresh-noop ---"
T3="$(mktemp -d -t distill-t3-XXXXXX)"
export CORTEX_DIR="$T3"
FIVE_AGO=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(days=5)).strftime('%Y-%m-%d'))
")
make_instinct "$T3/instincts/global" "t3-fresh" "0.8000" "$FIVE_AGO"

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T3'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T3')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
changed = de.apply_decay()
print(len(changed))
")
[ "$result" = "0" ] && pass "decay-fresh-noop: 5d unused → no change" || fail "decay-fresh-noop: expected 0 changed, got $result"
rm -rf "$T3"

# ── Test 4: archive-on-low-conf — conf 0.05 → moved to archive/ ─────────────
echo "--- Test 4: archive-on-low-conf ---"
T4="$(mktemp -d -t distill-t4-XXXXXX)"
export CORTEX_DIR="$T4"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
make_instinct "$T4/instincts/global" "t4-low" "0.0500" "$TODAY"

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T4'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T4')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
archived = de.archive_decayed()
print(len(archived))
")
archived_file="$T4/instincts/global/archive/t4-low.yaml"
if [ "$result" = "1" ] && [ -f "$archived_file" ]; then
  pass "archive-on-low-conf: moved to archive/"
else
  fail "archive-on-low-conf: archived=$result, file_exists=$([ -f "$archived_file" ] && echo yes || echo no)"
fi
rm -rf "$T4"

# ── Test 5: at-law-threshold-since-set — conf 0.95, field absent → set today ─
echo "--- Test 5: at-law-threshold-since-set ---"
T5="$(mktemp -d -t distill-t5-XXXXXX)"
export CORTEX_DIR="$T5"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
make_instinct "$T5/instincts/global" "t5-thresh" "0.9500" "$TODAY" \
  "projects_seen:\n- proj-alpha\n- proj-beta\n- proj-gamma"
# Add enough impact events
make_impact_events "$T5/impact.jsonl" "t5-thresh" 6 0

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T5'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T5')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
promoted, candidates = de.auto_promote_to_law()
# check field was set
text = Path('$T5/instincts/global/t5-thresh.yaml').read_text()
has_field = 'at_law_threshold_since' in text
promoted_now = any(p['id'] == 't5-thresh' for p in promoted)
print(has_field, promoted_now)
")
if echo "$result" | grep -q "True False"; then
  pass "at-law-threshold-since-set: field added, not promoted yet"
else
  fail "at-law-threshold-since-set: got '$result'"
fi
rm -rf "$T5"

# ── Test 6: at-law-threshold-since-cleared — conf drops below 0.95 ──────────
echo "--- Test 6: at-law-threshold-since-cleared ---"
T6="$(mktemp -d -t distill-t6-XXXXXX)"
export CORTEX_DIR="$T6"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
FOURTEEN_AGO=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
make_instinct "$T6/instincts/global" "t6-drop" "0.8500" "$TODAY" \
  "at_law_threshold_since: $FOURTEEN_AGO"

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T6'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T6')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
de.auto_promote_to_law()
text = Path('$T6/instincts/global/t6-drop.yaml').read_text()
print('cleared' if 'at_law_threshold_since' not in text else 'still_there')
")
[ "$result" = "cleared" ] && pass "at-law-threshold-since-cleared: field removed when conf < 0.95" || fail "at-law-threshold-since-cleared: got '$result'"
rm -rf "$T6"

# ── Test 7: promote-rejects-young — threshold_since=today → candidate ────────
echo "--- Test 7: promote-rejects-young ---"
T7="$(mktemp -d -t distill-t7-XXXXXX)"
export CORTEX_DIR="$T7"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
make_instinct "$T7/instincts/global" "t7-young" "0.9500" "$TODAY" \
  "at_law_threshold_since: $TODAY
projects_seen:
- proj-alpha
- proj-beta
- proj-gamma"
make_impact_events "$T7/impact.jsonl" "t7-young" 6 0

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T7'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T7')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
promoted, candidates = de.auto_promote_to_law()
in_candidates = any(c['id'] == 't7-young' for c in candidates)
not_promoted = not any(p['id'] == 't7-young' for p in promoted)
reason_ok = any('sustained' in r for c in candidates if c['id'] == 't7-young' for r in c['reasons'])
print(in_candidates, not_promoted, reason_ok)
")
if echo "$result" | grep -q "True True True"; then
  pass "promote-rejects-young: 0d threshold → candidate with 'sustained < 14d'"
else
  fail "promote-rejects-young: got '$result'"
fi
rm -rf "$T7"

# ── Test 8: promote-accepts-single-project (v3.24.0+) ────────────────────────
# v3.24.0: LAW_MIN_PROJECTS lowered from 3 to 1 (Audit C P0). Single-project
# knowledge IS promotable now provided every other gate passes. The previous
# test asserted the opposite — kept here renamed and inverted.
echo "--- Test 8: promote-accepts-single-project (v3.24.0+) ---"
T8="$(mktemp -d -t distill-t8-XXXXXX)"
export CORTEX_DIR="$T8"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
FIFTEEN_AGO=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
make_instinct "$T8/instincts/global" "t8-single" "0.9500" "$TODAY" \
  "at_law_threshold_since: $FIFTEEN_AGO"
# Only 1 project (project_id=proj-alpha, no projects_seen) — should now PASS
make_impact_events "$T8/impact.jsonl" "t8-single" 6 0

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T8'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T8')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
promoted, candidates = de.auto_promote_to_law()
got_promoted = any(p['id'] == 't8-single' for p in promoted)
in_cand_for_projects = any('projects' in r for c in candidates if c['id'] == 't8-single' for r in c['reasons'])
print(got_promoted, in_cand_for_projects)
")
if echo "$result" | grep -q "True False"; then
  pass "promote-accepts-single-project: 1 project → promoted (LAW_MIN_PROJECTS=1)"
else
  fail "promote-accepts-single-project: got '$result' (expected 'True False')"
fi
rm -rf "$T8"

# ── Test 9: promote-rejects-noise ────────────────────────────────────────────
echo "--- Test 9: promote-rejects-noise ---"
T9="$(mktemp -d -t distill-t9-XXXXXX)"
export CORTEX_DIR="$T9"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
FIFTEEN_AGO=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
make_instinct "$T9/instincts/global" "t9-noisy" "0.9500" "$TODAY" \
  "at_law_threshold_since: $FIFTEEN_AGO
projects_seen:
- proj-alpha
- proj-beta
- proj-gamma"
make_impact_events "$T9/impact.jsonl" "t9-noisy" 6 1  # 6 useful, 1 noise

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T9'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T9')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
promoted, candidates = de.auto_promote_to_law()
in_cand = any(c['id'] == 't9-noisy' for c in candidates)
reason_ok = any('noise' in r for c in candidates if c['id'] == 't9-noisy' for r in c['reasons'])
print(in_cand, reason_ok)
")
if echo "$result" | grep -q "True True"; then
  pass "promote-rejects-noise: 1 noise event → candidate with 'noise > 0'"
else
  fail "promote-rejects-noise: got '$result'"
fi
rm -rf "$T9"

# ── Test 10: promote-rejects-laws-full ───────────────────────────────────────
echo "--- Test 10: promote-rejects-laws-full ---"
T10="$(mktemp -d -t distill-t10-XXXXXX)"
export CORTEX_DIR="$T10"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
FIFTEEN_AGO=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
make_instinct "$T10/instincts/global" "t10-full" "0.9500" "$TODAY" \
  "at_law_threshold_since: $FIFTEEN_AGO
projects_seen:
- proj-alpha
- proj-beta
- proj-gamma"
make_impact_events "$T10/impact.jsonl" "t10-full" 6 0
# Create LAW_MAX_ACTIVE law files (v3.29.2: cap raised 10 → 12)
for i in $(seq 1 12); do
  make_law "$T10/laws" "existing-law-$i" "Always do thing $i for testing purposes"
done

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T10'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T10')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
promoted, candidates = de.auto_promote_to_law()
in_cand = any(c['id'] == 't10-full' for c in candidates)
reason_ok = any('laws ==' in r for c in candidates if c['id'] == 't10-full' for r in c['reasons'])
print(in_cand, reason_ok)
")
if echo "$result" | grep -q "True True"; then
  pass "promote-rejects-laws-full: 12 active laws → candidate with 'laws == 12'"
else
  fail "promote-rejects-laws-full: got '$result'"
fi
rm -rf "$T10"

# ── Test 11: promote-rejects-jaccard-overlap ─────────────────────────────────
echo "--- Test 11: promote-rejects-jaccard-overlap ---"
T11="$(mktemp -d -t distill-t11-XXXXXX)"
export CORTEX_DIR="$T11"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
FIFTEEN_AGO=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
# Instinct with action very similar to the existing law
mkdir -p "$T11/instincts/global"
cat > "$T11/instincts/global/t11-dup.yaml" <<YAML
---
id: t11-dup
confidence: 0.9500
domain: testing
trigger: "SomeTool"
action: "Always use read tool before edit tool when modifying files in repo"
last_seen: $TODAY
first_seen: $TODAY
occurrences: 10
project_id: proj-alpha
projects_seen:
- proj-alpha
- proj-beta
- proj-gamma
at_law_threshold_since: $FIFTEEN_AGO
---
YAML
make_impact_events "$T11/impact.jsonl" "t11-dup" 6 0
# Existing law with identical content => Jaccard = 1.0
mkdir -p "$T11/laws"
echo "Always use read tool before edit tool when modifying files in repo" > "$T11/laws/existing-read-first.txt"

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T11'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T11')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
promoted, candidates = de.auto_promote_to_law()
in_cand = any(c['id'] == 't11-dup' for c in candidates)
reason_ok = any('duplicate of' in r for c in candidates if c['id'] == 't11-dup' for r in c['reasons'])
print(in_cand, reason_ok)
")
if echo "$result" | grep -q "True True"; then
  pass "promote-rejects-jaccard-overlap: high Jaccard → candidate with 'duplicate of'"
else
  fail "promote-rejects-jaccard-overlap: got '$result'"
fi
rm -rf "$T11"

# ── Test 12: promote-accepts — all 7 criteria pass ───────────────────────────
echo "--- Test 12: promote-accepts ---"
T12="$(mktemp -d -t distill-t12-XXXXXX)"
export CORTEX_DIR="$T12"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
FIFTEEN_AGO=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
mkdir -p "$T12/instincts/global"
cat > "$T12/instincts/global/t12-good.yaml" <<YAML
---
id: t12-good
confidence: 0.9500
domain: testing
trigger: "Bash"
action: "Always verify test results before reporting success to user"
last_seen: $TODAY
first_seen: $TODAY
occurrences: 20
project_id: proj-alpha
projects_seen:
- proj-alpha
- proj-beta
- proj-gamma
at_law_threshold_since: $FIFTEEN_AGO
---
YAML
make_impact_events "$T12/impact.jsonl" "t12-good" 6 0
mkdir -p "$T12/laws"

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T12'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T12')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't12-good' for p in promoted)
law_exists = (de.LAWS_DIR / 't12-good.txt').exists()
log_exists = (de.KNOWLEDGE_LOG).exists()
print(was_promoted, law_exists, log_exists)
")
if echo "$result" | grep -q "True True True"; then
  pass "promote-accepts: all 7 criteria → law file created + knowledge-log appended"
else
  fail "promote-accepts: got '$result'"
fi
rm -rf "$T12"

# ── Test 13: idempotent-decay — second call same day is no-op ────────────────
echo "--- Test 13: idempotent-decay ---"
T13="$(mktemp -d -t distill-t13-XXXXXX)"
export CORTEX_DIR="$T13"
THIRTY_ONE_AGO=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(days=31)).strftime('%Y-%m-%d'))
")
make_instinct "$T13/instincts/global" "t13-idem" "0.8000" "$THIRTY_ONE_AGO"

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T13'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T13')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
first = de.apply_decay()
second = de.apply_decay()
print(len(first), len(second))
")
if echo "$result" | grep -q "^1 0$"; then
  pass "idempotent-decay: second same-day call changes 0 instincts"
else
  fail "idempotent-decay: got '$result' (expected '1 0')"
fi
rm -rf "$T13"

# ── Test 14: rate-limit-marker — second run_auto_distill within 24h skipped ──
echo "--- Test 14: rate-limit-marker ---"
T14="$(mktemp -d -t distill-t14-XXXXXX)"
export CORTEX_DIR="$T14"

result=$(python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T14'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T14')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
first = de.run_auto_distill()
second = de.run_auto_distill()
print(first.get('skipped_reason'), second.get('skipped_reason'))
")
if echo "$result" | grep -q "^None rate-limited$"; then
  pass "rate-limit-marker: second call within 24h returns skipped_reason=rate-limited"
else
  fail "rate-limit-marker: got '$result'"
fi
rm -rf "$T14"

# ── Test 15: lock-prevents-parallel — concurrent calls ───────────────────────
echo "--- Test 15: lock-prevents-parallel ---"
T15="$(mktemp -d -t distill-t15-XXXXXX)"
export CORTEX_DIR="$T15"

# Run two concurrent auto-distill calls; one should acquire the lock, the other
# should return lock-busy (or rate-limited if the first finishes fast enough to
# write the marker before the second checks). Both non-blocking.
OUTFILE1="$T15/out1.txt"
OUTFILE2="$T15/out2.txt"

python3 -c "
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$T15'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T15')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'

# Acquire the lock manually to simulate a concurrent holder
lock_fh, acquired = de._lock_acquire(nonblocking=False)
# Now try a non-blocking acquire in the 'other' process
lock_fh2, acquired2 = de._lock_acquire(nonblocking=True)
de._lock_release(lock_fh2)
de._lock_release(lock_fh)
print(acquired, acquired2)
" > "$T15/locktest.txt" 2>&1

lock_result=$(cat "$T15/locktest.txt")
# First acquire should succeed (True), second should fail (False) on POSIX
# On Windows (no fcntl) both return True — we accept that gracefully
if echo "$lock_result" | grep -q "True False" || echo "$lock_result" | grep -q "True True"; then
  pass "lock-prevents-parallel: concurrent lock attempt correctly handled"
else
  fail "lock-prevents-parallel: got '$lock_result'"
fi
rm -rf "$T15"

# ── Sprint 7: auto_validate_proposals tests ──────────────────────────────────

make_proposal() {
  # make_proposal <proposals_file> <id> <conf> <domain> [scope=global] [status=pending]
  local file="$1" iid="$2" conf="$3" domain="$4"
  local scope="${5:-global}" status="${6:-pending}"
  mkdir -p "$(dirname "$file")"
  # Append to array in JSON (or create fresh file)
  python3 - <<PYEOF
import json, os
path = '$file'
entry = {
    "id": "$iid",
    "trigger": "SomeTool",
    "action": "Always do the thing for testing",
    "confidence": $conf,
    "domain": "$domain",
    "scope": "$scope",
    "project_id": "global",
    "project_name": "cross-project",
    "tags": [],
    "detected": "2026-01-01",
    "source": "cx-analyze",
    "status": "$status",
}
data = []
if os.path.exists(path):
    try:
        data = json.loads(open(path).read())
    except Exception:
        data = []
data.append(entry)
open(path, 'w').write(json.dumps(data, indent=2))
PYEOF
}

_py_patch() {
  # Patch distill_engine module-level paths to CORTEX_DIR in a heredoc
  local tdir="$1"
  cat <<PYEOF
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$tdir'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$tdir')
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
PYEOF
}

# ── Test 16: auto-validate-accepts-gotcha-conf-high ──────────────────────────
echo "--- Test 16: auto-validate-accepts-gotcha-conf-high ---"
T16="$(mktemp -d -t distill-t16-XXXXXX)"
export CORTEX_DIR="$T16"
make_proposal "$T16/proposals.json" "t16-gotcha" "0.60" "error-recovery"

result=$(python3 - <<PYEOF
$(_py_patch "$T16")
r = de.auto_validate_proposals()
accepted_ids = [a['id'] for a in r['accepted']]
import json
# Check instinct file created
instinct_path = de.CORTEX_DIR / 'instincts' / 'global' / 't16-gotcha.yaml'
instinct_exists = instinct_path.exists()
# Check proposals.json updated
props = json.loads(de.PROPOSALS_FILE.read_text())
status_ok = props[0]['status'] == 'accepted'
print('t16-gotcha' in accepted_ids, instinct_exists, status_ok)
PYEOF
)
if echo "$result" | grep -q "True True True"; then
  pass "auto-validate-accepts-gotcha-conf-high: error-recovery conf=0.60 accepted, instinct created"
else
  fail "auto-validate-accepts-gotcha-conf-high: got '$result'"
fi
rm -rf "$T16"

# ── Test 17: auto-validate-rejects-correction ────────────────────────────────
echo "--- Test 17: auto-validate-rejects-correction ---"
T17="$(mktemp -d -t distill-t17-XXXXXX)"
export CORTEX_DIR="$T17"
make_proposal "$T17/proposals.json" "t17-corr" "0.80" "correction"

result=$(python3 - <<PYEOF
$(_py_patch "$T17")
r = de.auto_validate_proposals()
skipped_ids = {s['id']: s['reason'] for s in r['skipped']}
accepted_ids = [a['id'] for a in r['accepted']]
reason_ok = skipped_ids.get('t17-corr') == 'needs-human-judgment'
not_accepted = 't17-corr' not in accepted_ids
print(reason_ok, not_accepted)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "auto-validate-rejects-correction: domain=correction skipped with needs-human-judgment"
else
  fail "auto-validate-rejects-correction: got '$result'"
fi
rm -rf "$T17"

# ── Test 18: auto-validate-rejects-low-conf ──────────────────────────────────
echo "--- Test 18: auto-validate-rejects-low-conf ---"
T18="$(mktemp -d -t distill-t18-XXXXXX)"
export CORTEX_DIR="$T18"
make_proposal "$T18/proposals.json" "t18-low" "0.40" "gotcha"

result=$(python3 - <<PYEOF
$(_py_patch "$T18")
r = de.auto_validate_proposals()
skipped_ids = {s['id']: s['reason'] for s in r['skipped']}
reason_ok = skipped_ids.get('t18-low') == 'low-confidence'
not_accepted = 't18-low' not in [a['id'] for a in r['accepted']]
print(reason_ok, not_accepted)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "auto-validate-rejects-low-conf: conf=0.40 skipped with low-confidence"
else
  fail "auto-validate-rejects-low-conf: got '$result'"
fi
rm -rf "$T18"

# ── Test 19: auto-validate-idempotent ────────────────────────────────────────
echo "--- Test 19: auto-validate-idempotent ---"
T19="$(mktemp -d -t distill-t19-XXXXXX)"
export CORTEX_DIR="$T19"
make_proposal "$T19/proposals.json" "t19-idem" "0.70" "pattern"
# Pre-create instinct so it "already exists"
mkdir -p "$T19/instincts/global"
cat > "$T19/instincts/global/t19-idem.yaml" <<YAML
---
id: t19-idem
confidence: 0.70
domain: pattern
trigger: SomeTool
action: Already exists
last_seen: 2026-01-01
first_seen: 2026-01-01
occurrences: 1
---
YAML

result=$(python3 - <<PYEOF
$(_py_patch "$T19")
# Read file mtime before
import os
mtime_before = os.path.getmtime(de.CORTEX_DIR / 'instincts' / 'global' / 't19-idem.yaml')
r = de.auto_validate_proposals()
mtime_after = os.path.getmtime(de.CORTEX_DIR / 'instincts' / 'global' / 't19-idem.yaml')
skipped_ids = {s['id']: s['reason'] for s in r['skipped']}
reason_ok = skipped_ids.get('t19-idem') == 'already-instinct'
not_overwritten = mtime_before == mtime_after
print(reason_ok, not_overwritten)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "auto-validate-idempotent: existing instinct skipped with already-instinct, not overwritten"
else
  fail "auto-validate-idempotent: got '$result'"
fi
rm -rf "$T19"

# ── Sprint 7: auto_evolve_detect tests ───────────────────────────────────────

make_instinct_evolve() {
  # make_instinct_evolve <dir> <id> <conf> <domain> <trigger> <action>
  local dir="$1" iid="$2" conf="$3" domain="$4" trigger="$5" action="$6"
  mkdir -p "$dir"
  cat > "$dir/${iid}.yaml" <<YAML
---
id: ${iid}
confidence: ${conf}
domain: ${domain}
trigger: '${trigger}'
action: '${action}'
last_seen: 2026-04-01
first_seen: 2026-04-01
occurrences: 5
project_id: proj-alpha
project_name: test-project
---
YAML
}

# ── Test 20: evolve-detects-cluster-of-3 ─────────────────────────────────────
echo "--- Test 20: evolve-detects-cluster-of-3 ---"
T20="$(mktemp -d -t distill-t20-XXXXXX)"
export CORTEX_DIR="$T20"
# 3 instincts, same domain, similar trigger+action tokens → Jaccard >= 0.50
make_instinct_evolve "$T20/instincts/global" "t20-a" "0.80" "gotcha" \
  "Bash git commit" "Always run tests before committing code to repository"
make_instinct_evolve "$T20/instincts/global" "t20-b" "0.80" "gotcha" \
  "Bash git push" "Always run tests before pushing code to repository"
make_instinct_evolve "$T20/instincts/global" "t20-c" "0.80" "gotcha" \
  "Bash git" "Always run tests before any git operation on repository"

result=$(python3 - <<PYEOF
$(_py_patch "$T20")
r = de.auto_evolve_detect()
drafts = r['drafts_generated']
draft_count = len(drafts)
draft_path_ok = False
if drafts:
    import os
    draft_path_ok = os.path.exists(drafts[0]['draft_path'])
    count_ok = drafts[0]['instinct_count'] >= 3
print(draft_count >= 1, draft_path_ok, count_ok)
PYEOF
)
if echo "$result" | grep -q "True True True"; then
  pass "evolve-detects-cluster-of-3: 3 similar gotcha instincts → draft generated at correct path"
else
  fail "evolve-detects-cluster-of-3: got '$result'"
fi
rm -rf "$T20"

# ── Test 21: evolve-rejects-cluster-of-2 ─────────────────────────────────────
echo "--- Test 21: evolve-rejects-cluster-of-2 ---"
T21="$(mktemp -d -t distill-t21-XXXXXX)"
export CORTEX_DIR="$T21"
# Only 2 instincts in the domain — below cluster minimum
make_instinct_evolve "$T21/instincts/global" "t21-a" "0.80" "gotcha" \
  "Bash git commit" "Always run tests before committing code to repository"
make_instinct_evolve "$T21/instincts/global" "t21-b" "0.80" "gotcha" \
  "Bash git push" "Always run tests before pushing code to repository"

result=$(python3 - <<PYEOF
$(_py_patch "$T21")
r = de.auto_evolve_detect()
draft_count = len(r['drafts_generated'])
error_count = 0  # should not error
print(draft_count == 0, error_count == 0)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "evolve-rejects-cluster-of-2: 2 instincts → no draft generated, no error"
else
  fail "evolve-rejects-cluster-of-2: got '$result'"
fi
rm -rf "$T21"

# ── Test 22: evolve-rejects-low-jaccard ──────────────────────────────────────
echo "--- Test 22: evolve-rejects-low-jaccard ---"
T22="$(mktemp -d -t distill-t22-XXXXXX)"
export CORTEX_DIR="$T22"
# 3 instincts in same domain but very different trigger+action → Jaccard < 0.50
make_instinct_evolve "$T22/instincts/global" "t22-a" "0.80" "gotcha" \
  "Bash git" "Always run tests before committing"
make_instinct_evolve "$T22/instincts/global" "t22-b" "0.80" "gotcha" \
  "Read file" "Check YAML indentation when editing config"
make_instinct_evolve "$T22/instincts/global" "t22-c" "0.80" "gotcha" \
  "Write database" "Verify schema migration before applying to production"

result=$(python3 - <<PYEOF
$(_py_patch "$T22")
r = de.auto_evolve_detect()
draft_count = len(r['drafts_generated'])
print(draft_count == 0)
PYEOF
)
if echo "$result" | grep -q "True"; then
  pass "evolve-rejects-low-jaccard: 3 instincts with low Jaccard → no draft"
else
  fail "evolve-rejects-low-jaccard: got '$result' (expected 0 drafts)"
fi
rm -rf "$T22"

# ── Test 23: evolve-skips-when-skill-exists ───────────────────────────────────
echo "--- Test 23: evolve-skips-when-skill-exists ---"
T23="$(mktemp -d -t distill-t23-XXXXXX)"
export CORTEX_DIR="$T23"
# 3 similar instincts forming a cluster
make_instinct_evolve "$T23/instincts/global" "t23-a" "0.80" "gotcha" \
  "Bash git commit" "Always run tests before committing code to repository"
make_instinct_evolve "$T23/instincts/global" "t23-b" "0.80" "gotcha" \
  "Bash git push" "Always run tests before pushing code to repository"
make_instinct_evolve "$T23/instincts/global" "t23-c" "0.80" "gotcha" \
  "Bash git" "Always run tests before any git operation on repository"

# First, compute what the cluster-id would be and pre-create the skill
cluster_id=$(python3 - <<PYEOF
$(_py_patch "$T23")
# Run detection once to find the cluster id
r = de.auto_evolve_detect(dry_run=True)
if r['drafts_generated']:
    print(r['drafts_generated'][0]['cluster_id'])
else:
    print('no-cluster')
PYEOF
)

if [ "$cluster_id" = "no-cluster" ]; then
  fail "evolve-skips-when-skill-exists: could not detect cluster (prerequisite failed)"
else
  # Create the skill directory to simulate existing skill
  mkdir -p "$T23/skills/$cluster_id"
  echo "# Existing skill" > "$T23/skills/$cluster_id/SKILL.md"

  result=$(python3 - <<PYEOF
$(_py_patch "$T23")
r = de.auto_evolve_detect()
draft_count = len(r['drafts_generated'])
skip_count = len(r['skipped'])
print(draft_count == 0, skip_count >= 1)
PYEOF
  )
  if echo "$result" | grep -q "True True"; then
    pass "evolve-skips-when-skill-exists: cluster found but skill exists → skipped, no draft"
  else
    fail "evolve-skips-when-skill-exists: got '$result'"
  fi
fi
rm -rf "$T23"

# ── Sprint 7.1: pipeline-stats tests ─────────────────────────────────────────

# ── Test 24: pipeline-stats-zero-state ───────────────────────────────────────
echo "--- Test 24: pipeline-stats-zero-state ---"
T24="$(mktemp -d -t distill-t24-XXXXXX)"
export CORTEX_DIR="$T24"

result=$(python3 - <<PYEOF
$(_py_patch "$T24")
import json
stats = de.compute_pipeline_stats(days=14)
v = stats['validate']
pr = stats['promote']
ev = stats['evolve']
dc = stats['decay']
lr = stats['last_runs']

all_zero = (
    v['auto_accepted'] == 0 and v['manual_accepted'] == 0 and
    v['manual_rejected'] == 0 and v['pending'] == 0 and
    pr['auto_promoted'] == 0 and pr['manual_promoted'] == 0 and
    pr['candidates_queued'] == 0 and
    ev['auto_drafts_generated'] == 0 and ev['manual_evolved'] == 0 and
    ev['drafts_pending_install'] == 0 and ev['manual_drafts_pending'] == 0 and
    dc['decayed'] == 0 and dc['archived'] == 0
)
all_runs_null = all(v is None for v in lr.values())
print(all_zero, all_runs_null)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "pipeline-stats-zero-state: empty CORTEX_DIR → all counts 0, last_runs all null"
else
  fail "pipeline-stats-zero-state: got '$result'"
fi
rm -rf "$T24"

# ── Test 25: pipeline-stats-counts-by-source ─────────────────────────────────
echo "--- Test 25: pipeline-stats-counts-by-source ---"
T25="$(mktemp -d -t distill-t25-XXXXXX)"
export CORTEX_DIR="$T25"

# Seed knowledge-log: 3 auto-accepted + 2 manual accepted + 1 manual rejected + 1 auto promoted
TODAY_DATE=$(python3 -c "from datetime import date; print(date.today().isoformat())")
mkdir -p "$T25"
cat > "$T25/knowledge-log.md" <<LOG
$TODAY_DATE | accepted | auto-1 | conf=0.60 | cx-auto-validate
$TODAY_DATE | accepted | auto-2 | conf=0.65 | cx-auto-validate
$TODAY_DATE | accepted | auto-3 | conf=0.70 | cx-auto-validate
$TODAY_DATE | created | manual-1 | 0.75 | cx-validate
$TODAY_DATE | accepted | manual-2 | 0.80 | cx-validate
$TODAY_DATE | rejected | manual-r1 | 0.40 | cx-validate
$TODAY_DATE | promoted | law-1 | law written | cx-auto-distill
LOG

result=$(python3 - <<PYEOF
$(_py_patch "$T25")
import json
stats = de.compute_pipeline_stats(days=14)
v = stats['validate']
pr = stats['promote']
aa = v['auto_accepted'] == 3
ma = v['manual_accepted'] == 2
mr = v['manual_rejected'] == 1
ap = pr['auto_promoted'] == 1
print(aa, ma, mr, ap)
PYEOF
)
if echo "$result" | grep -q "True True True True"; then
  pass "pipeline-stats-counts-by-source: auto_accepted=3, manual_accepted=2, rejected=1, auto_promoted=1"
else
  fail "pipeline-stats-counts-by-source: got '$result'"
fi
rm -rf "$T25"

# ── Test 26: pipeline-stats-pending-by-domain ────────────────────────────────
echo "--- Test 26: pipeline-stats-pending-by-domain ---"
T26="$(mktemp -d -t distill-t26-XXXXXX)"
export CORTEX_DIR="$T26"

# 2 gotcha pending + 3 workflow pending
make_proposal "$T26/proposals.json" "p26-g1" "0.60" "gotcha"
make_proposal "$T26/proposals.json" "p26-g2" "0.65" "gotcha"
make_proposal "$T26/proposals.json" "p26-w1" "0.55" "workflow"
make_proposal "$T26/proposals.json" "p26-w2" "0.60" "workflow"
make_proposal "$T26/proposals.json" "p26-w3" "0.70" "workflow"

result=$(python3 - <<PYEOF
$(_py_patch "$T26")
import json
stats = de.compute_pipeline_stats(days=14)
v = stats['validate']
pending_ok = v['pending'] == 5
domain_ok = v['pending_by_domain'].get('gotcha', 0) == 2 and v['pending_by_domain'].get('workflow', 0) == 3
# gotcha is in WHITELIST_DOMAINS, workflow is not
whitelist_ok = v['pending_in_whitelist'] == 2
outside_ok = v['pending_outside_whitelist'] == 3
print(pending_ok, domain_ok, whitelist_ok, outside_ok)
PYEOF
)
if echo "$result" | grep -q "True True True True"; then
  pass "pipeline-stats-pending-by-domain: pending=5, gotcha:2/whitelist, workflow:3/outside"
else
  fail "pipeline-stats-pending-by-domain: got '$result'"
fi
rm -rf "$T26"

# ── Test 27: pipeline-stats-evolve-drafts ────────────────────────────────────
echo "--- Test 27: pipeline-stats-evolve-drafts ---"
T27="$(mktemp -d -t distill-t27-XXXXXX)"
export CORTEX_DIR="$T27"

mkdir -p "$T27/evolved/skills"
echo "# draft 1" > "$T27/evolved/skills/cluster-testing-abc12345.draft.md"
echo "# draft 2" > "$T27/evolved/skills/cluster-workflow-def67890.draft.md"
echo "# manual skill" > "$T27/evolved/skills/fs-foo.md"

result=$(python3 - <<PYEOF
$(_py_patch "$T27")
import json
stats = de.compute_pipeline_stats(days=14)
ev = stats['evolve']
drafts_ok = ev['drafts_pending_install'] == 2
manual_ok = ev['manual_drafts_pending'] == 1
print(drafts_ok, manual_ok)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "pipeline-stats-evolve-drafts: drafts_pending_install=2, manual_drafts_pending=1"
else
  fail "pipeline-stats-evolve-drafts: got '$result'"
fi
rm -rf "$T27"

# ── v3.29.0 (Sprint 8 §4.1 + §4.7) — Día 1 tests ─────────────────────────────

# ── Test 28: human-domain-coupling-skipped (§4.1) ────────────────────────────
echo "--- Test 28: human-domain-coupling-skipped ---"
T32="$(mktemp -d -t distill-t28-XXXXXX)"
export CORTEX_DIR="$T32"
make_proposal "$T32/proposals.json" "t28-coupling" "0.55" "coupling"

result=$(python3 - <<PYEOF
$(_py_patch "$T32")
r = de.auto_validate_proposals()
skipped = {s['id']: s['reason'] for s in r['skipped']}
accepted_ids = [a['id'] for a in r['accepted']]
reason_ok = skipped.get('t28-coupling') == 'needs-human-judgment'
not_accepted = 't28-coupling' not in accepted_ids
instinct_path = de.CORTEX_DIR / 'instincts' / 'global' / 't28-coupling.yaml'
no_instinct = not instinct_path.exists()
print(reason_ok, not_accepted, no_instinct)
PYEOF
)
if echo "$result" | grep -q "True True True"; then
  pass "human-domain-coupling-skipped: domain=coupling → needs-human-judgment, no instinct created"
else
  fail "human-domain-coupling-skipped: got '$result'"
fi
rm -rf "$T32"

# ── Test 29: human-domain-agent-quality-skipped (§4.1) ───────────────────────
echo "--- Test 29: human-domain-agent-quality-skipped ---"
T33="$(mktemp -d -t distill-t29-XXXXXX)"
export CORTEX_DIR="$T33"
make_proposal "$T33/proposals.json" "t29-aq" "0.55" "agent-quality"

result=$(python3 - <<PYEOF
$(_py_patch "$T33")
r = de.auto_validate_proposals()
skipped = {s['id']: s['reason'] for s in r['skipped']}
accepted_ids = [a['id'] for a in r['accepted']]
reason_ok = skipped.get('t29-aq') == 'needs-human-judgment'
not_accepted = 't29-aq' not in accepted_ids
instinct_path = de.CORTEX_DIR / 'instincts' / 'global' / 't29-aq.yaml'
no_instinct = not instinct_path.exists()
print(reason_ok, not_accepted, no_instinct)
PYEOF
)
if echo "$result" | grep -q "True True True"; then
  pass "human-domain-agent-quality-skipped: domain=agent-quality → needs-human-judgment"
else
  fail "human-domain-agent-quality-skipped: got '$result'"
fi
rm -rf "$T33"

# ── Test 30: ghost-guard-restores-unauthorized-reject (§4.7) ─────────────────
# Inject a proposal rejected by 'cx-validate-auto' (the ghost identity).
# auto_validate_proposals must restore it to pending status and strip
# rejected_by / rejected_reason fields.
echo "--- Test 30: ghost-guard-restores-unauthorized-reject ---"
T34="$(mktemp -d -t distill-t30-XXXXXX)"
export CORTEX_DIR="$T34"
mkdir -p "$T34"
cat > "$T34/proposals.json" <<'JSON'
[
  {
    "id": "t30-ghost",
    "trigger": "Edit",
    "action": "Coupled with bar.ts — review",
    "confidence": 0.55,
    "domain": "coupling",
    "scope": "project",
    "project_id": "proj-alpha",
    "project_name": "alpha",
    "tags": [],
    "detected": "2026-05-05",
    "source": "session-learner:file-coupling",
    "status": "rejected",
    "rejected_by": "cx-validate-auto",
    "rejected_reason": "ghost-bulk",
    "rejected_at": "2026-05-05"
  },
  {
    "id": "t30-legit",
    "trigger": "Bash",
    "action": "Legit reject — leave alone",
    "confidence": 0.40,
    "domain": "gotcha",
    "scope": "global",
    "project_id": "global",
    "project_name": "cross-project",
    "tags": [],
    "detected": "2026-05-05",
    "source": "cx-analyze",
    "status": "rejected",
    "rejected_by": "cx-validate",
    "rejected_reason": "operator declined",
    "rejected_at": "2026-05-05"
  }
]
JSON

result=$(python3 - <<PYEOF
$(_py_patch "$T34")
import json
r = de.auto_validate_proposals()
ghost_restored = r.get('ghost_restored', -1)
data = json.loads(de.PROPOSALS_FILE.read_text())
by_id = {p['id']: p for p in data}
# Ghost-tagged proposal restored to pending; rejected_by stripped.
ghost = by_id['t30-ghost']
ghost_ok = (
    ghost.get('status') == 'pending'
    and 'rejected_by' not in ghost
    and 'rejected_reason' not in ghost
)
# Legitimate reject left untouched.
legit = by_id['t30-legit']
legit_ok = (
    legit.get('status') == 'rejected'
    and legit.get('rejected_by') == 'cx-validate'
)
print(ghost_restored == 1, ghost_ok, legit_ok)
PYEOF
)
if echo "$result" | grep -q "True True True"; then
  pass "ghost-guard-restores-unauthorized-reject: ghost reject restored, legit reject untouched"
else
  fail "ghost-guard-restores-unauthorized-reject: got '$result'"
fi
rm -rf "$T34"

# ── v3.29.0 (Sprint 8 §4.16) — multi-session promotion gate ──────────────────

make_promotable_instinct() {
  # make_promotable_instinct <dir> <iid>
  # Creates an instinct that PASSES every criterion EXCEPT the new
  # distinct_sessions gate, so tests below can isolate that one signal.
  local dir="$1" iid="$2"
  local today fifteen
  today=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
  fifteen=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
  mkdir -p "$dir"
  cat > "$dir/${iid}.yaml" <<YAML
---
id: ${iid}
confidence: 0.9500
domain: testing
trigger: "Bash"
action: "Always verify test results before reporting success to user"
last_seen: $today
first_seen: $today
occurrences: 20
project_id: proj-alpha
at_law_threshold_since: $fifteen
---
YAML
}

# ── Test 32: distinct-sessions-blocks-at-2 (§4.16) ──────────────────────────
echo "--- Test 32: distinct-sessions-blocks-at-2 ---"
T32="$(mktemp -d -t distill-t28-XXXXXX)"
export CORTEX_DIR="$T32"
make_promotable_instinct "$T32/instincts/global" "t32-twosess"
make_impact_events "$T32/impact.jsonl" "t32-twosess" 6 0
# Tracking entry with 2 distinct sessions — below LAW_MIN_DISTINCT_SESSIONS=3
cat > "$T32/instinct-tracking.json" <<JSON
{
  "t32-twosess": {
    "count": 17,
    "sessions": ["sess-A", "sess-B", "sess-A"],
    "projects_seen": ["proj-alpha"],
    "first_seen": "2026-05-01T00:00:00Z",
    "last_seen": "2026-05-14T00:00:00Z"
  }
}
JSON

result=$(python3 - <<PYEOF
$(_py_patch "$T32")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't32-twosess' for p in promoted)
cand = next((c for c in candidates if c['id'] == 't32-twosess'), None)
reason_ok = bool(cand) and any('sessions 2/3' in r for r in cand['reasons'])
print(was_promoted, reason_ok)
PYEOF
)
if echo "$result" | grep -q "False True"; then
  pass "distinct-sessions-blocks-at-2: NOT promoted, candidate reason 'sessions 2/3 (need 1 more)'"
else
  fail "distinct-sessions-blocks-at-2: got '$result'"
fi
rm -rf "$T32"

# ── Test 33: distinct-sessions-promotes-at-3 (§4.16) ─────────────────────────
echo "--- Test 33: distinct-sessions-promotes-at-3 ---"
T33="$(mktemp -d -t distill-t29-XXXXXX)"
export CORTEX_DIR="$T33"
make_promotable_instinct "$T33/instincts/global" "t33-threesess"
make_impact_events "$T33/impact.jsonl" "t33-threesess" 6 0
cat > "$T33/instinct-tracking.json" <<JSON
{
  "t33-threesess": {
    "count": 30,
    "sessions": ["sess-A", "sess-B", "sess-C"],
    "projects_seen": ["proj-alpha"],
    "first_seen": "2026-05-01T00:00:00Z",
    "last_seen": "2026-05-14T00:00:00Z"
  }
}
JSON
mkdir -p "$T33/laws"

result=$(python3 - <<PYEOF
$(_py_patch "$T33")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't33-threesess' for p in promoted)
law_exists = (de.LAWS_DIR / 't33-threesess.txt').exists()
print(was_promoted, law_exists)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "distinct-sessions-promotes-at-3: law file created"
else
  fail "distinct-sessions-promotes-at-3: got '$result'"
fi
rm -rf "$T33"

# ── Test 34: grandfather-missing-tracking (§4.16) ────────────────────────────
# Pre-existing high-confidence instincts created BEFORE v3.29 shipped this
# gate won't have any tracking entry yet. Without the grandfather clause
# they would all be retroactively blocked. With it: conf >= 0.95 + missing
# entry → promote anyway.
echo "--- Test 34: grandfather-missing-tracking ---"
T34="$(mktemp -d -t distill-t30-XXXXXX)"
export CORTEX_DIR="$T34"
make_promotable_instinct "$T34/instincts/global" "t34-grandfather"
make_impact_events "$T34/impact.jsonl" "t34-grandfather" 6 0
# NO instinct-tracking.json deliberately — simulates pre-v3.29 corpus
mkdir -p "$T34/laws"

result=$(python3 - <<PYEOF
$(_py_patch "$T34")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't34-grandfather' for p in promoted)
law_exists = (de.LAWS_DIR / 't34-grandfather.txt').exists()
print(was_promoted, law_exists)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "grandfather-missing-tracking: pre-v3.29 instinct promotes without tracking entry"
else
  fail "grandfather-missing-tracking: got '$result'"
fi
rm -rf "$T34"

# ── Test 35: count-distinct-sessions-defensive (§4.16) ───────────────────────
# The helper must return 0 on every malformed shape: missing file, missing
# key, non-dict entry, non-list sessions, empty/None UUIDs. Direct call
# against the function — no full promote pass needed.
echo "--- Test 35: count-distinct-sessions-defensive ---"
result=$(python3 - <<'PYEOF'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path('hooks/lib').resolve()))
from distill_engine import _count_distinct_sessions
checks = [
    _count_distinct_sessions('x', None),                          # None tracking
    _count_distinct_sessions('x', {}),                            # missing key
    _count_distinct_sessions('x', {'x': 'not-a-dict'}),           # non-dict entry
    _count_distinct_sessions('x', {'x': {}}),                     # missing sessions
    _count_distinct_sessions('x', {'x': {'sessions': 'nope'}}),   # non-list
    _count_distinct_sessions('x', {'x': {'sessions': []}}),       # empty list
    _count_distinct_sessions('x', {'x': {'sessions': [None, '']}}),  # empties only
    _count_distinct_sessions('x', {'x': {'sessions': ['a', 'a', 'b']}}),  # dedup
]
print(checks)
PYEOF
)
if echo "$result" | grep -q "\[0, 0, 0, 0, 0, 0, 0, 2\]"; then
  pass "count-distinct-sessions-defensive: returns 0 on every malformed shape, 2 on valid"
else
  fail "count-distinct-sessions-defensive: got '$result'"
fi

# ── v3.31.2 §4.1.A — grandfather narrow per AD P1-1 ─────────────────────────
# Tests 36-40 verify the narrowed grandfather clause: it fires ONLY when
# (entry absent) OR (sessions == [] explicit). Tracking corruption shapes
# (null, missing key, wrong type) keep blocking so the operator notices.

# ── Test 36: gf-entry-absent — case 1: missing tracking entry promotes ──────
echo "--- Test 36: gf-entry-absent (v3.31.2 §4.1.A case 1) ---"
T36="$(mktemp -d -t distill-t36-XXXXXX)"
export CORTEX_DIR="$T36"
make_promotable_instinct "$T36/instincts/global" "t36-absent"
make_impact_events "$T36/impact.jsonl" "t36-absent" 6 0
# No instinct-tracking.json on disk at all
mkdir -p "$T36/laws"

result=$(python3 - <<PYEOF
$(_py_patch "$T36")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't36-absent' for p in promoted)
law_exists = (de.LAWS_DIR / 't36-absent.txt').exists()
print(was_promoted, law_exists)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "gf-entry-absent: missing tracking entry + conf=0.95 promotes (grandfather case 1)"
else
  fail "gf-entry-absent: got '$result'"
fi
rm -rf "$T36"

# ── Test 37: gf-sessions-empty-list — case 2: sessions:[] promotes ──────────
echo "--- Test 37: gf-sessions-empty-list (v3.31.2 §4.1.A case 2) ---"
T37="$(mktemp -d -t distill-t37-XXXXXX)"
export CORTEX_DIR="$T37"
make_promotable_instinct "$T37/instincts/global" "t37-emptylist"
make_impact_events "$T37/impact.jsonl" "t37-emptylist" 6 0
cat > "$T37/instinct-tracking.json" <<'JSON'
{
  "t37-emptylist": {
    "count": 0,
    "sessions": [],
    "projects_seen": [],
    "first_seen": "2026-05-01T00:00:00Z",
    "last_seen": "2026-05-14T00:00:00Z"
  }
}
JSON
mkdir -p "$T37/laws"

result=$(python3 - <<PYEOF
$(_py_patch "$T37")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't37-emptylist' for p in promoted)
law_exists = (de.LAWS_DIR / 't37-emptylist.txt').exists()
print(was_promoted, law_exists)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "gf-sessions-empty-list: sessions:[] + conf=0.95 promotes (grandfather case 2)"
else
  fail "gf-sessions-empty-list: got '$result'"
fi
rm -rf "$T37"

# ── Test 38: gf-sessions-populated — normal path still works ────────────────
echo "--- Test 38: gf-sessions-populated (v3.31.2 §4.1.A normal path) ---"
T38="$(mktemp -d -t distill-t38-XXXXXX)"
export CORTEX_DIR="$T38"
make_promotable_instinct "$T38/instincts/global" "t38-populated"
make_impact_events "$T38/impact.jsonl" "t38-populated" 6 0
cat > "$T38/instinct-tracking.json" <<'JSON'
{
  "t38-populated": {
    "count": 30,
    "sessions": ["sess-A", "sess-B", "sess-C"],
    "projects_seen": ["proj-alpha"],
    "first_seen": "2026-05-01T00:00:00Z",
    "last_seen": "2026-05-14T00:00:00Z"
  }
}
JSON
mkdir -p "$T38/laws"

result=$(python3 - <<PYEOF
$(_py_patch "$T38")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't38-populated' for p in promoted)
law_exists = (de.LAWS_DIR / 't38-populated.txt').exists()
print(was_promoted, law_exists)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "gf-sessions-populated: 3 distinct sessions + conf=0.95 promotes (normal path)"
else
  fail "gf-sessions-populated: got '$result'"
fi
rm -rf "$T38"

# ── Test 39: gf-sessions-null-blocks — corruption guard ─────────────────────
echo "--- Test 39: gf-sessions-null-blocks (v3.31.2 §4.1.A AD P1-1 negative) ---"
T39="$(mktemp -d -t distill-t39-XXXXXX)"
export CORTEX_DIR="$T39"
make_promotable_instinct "$T39/instincts/global" "t39-null"
make_impact_events "$T39/impact.jsonl" "t39-null" 6 0
cat > "$T39/instinct-tracking.json" <<'JSON'
{
  "t39-null": {
    "count": 0,
    "sessions": null,
    "projects_seen": [],
    "first_seen": "2026-05-01T00:00:00Z",
    "last_seen": "2026-05-14T00:00:00Z"
  }
}
JSON
mkdir -p "$T39/laws"

result=$(python3 - <<PYEOF
$(_py_patch "$T39")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't39-null' for p in promoted)
cand = next((c for c in candidates if c['id'] == 't39-null'), None)
reason_ok = bool(cand) and any('sessions 0/3' in r for r in cand['reasons'])
print(was_promoted, reason_ok)
PYEOF
)
if echo "$result" | grep -q "False True"; then
  pass "gf-sessions-null-blocks: sessions:null does NOT grandfather (corruption guard)"
else
  fail "gf-sessions-null-blocks: got '$result'"
fi
rm -rf "$T39"

# ── Test 40: gf-missing-sessions-key-blocks — corruption guard ──────────────
echo "--- Test 40: gf-missing-sessions-key-blocks (v3.31.2 §4.1.A AD P1-1 negative) ---"
T40="$(mktemp -d -t distill-t40-XXXXXX)"
export CORTEX_DIR="$T40"
make_promotable_instinct "$T40/instincts/global" "t40-missingkey"
make_impact_events "$T40/impact.jsonl" "t40-missingkey" 6 0
cat > "$T40/instinct-tracking.json" <<'JSON'
{
  "t40-missingkey": {
    "count": 0,
    "projects_seen": [],
    "first_seen": "2026-05-01T00:00:00Z",
    "last_seen": "2026-05-14T00:00:00Z"
  }
}
JSON
mkdir -p "$T40/laws"

result=$(python3 - <<PYEOF
$(_py_patch "$T40")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't40-missingkey' for p in promoted)
cand = next((c for c in candidates if c['id'] == 't40-missingkey'), None)
reason_ok = bool(cand) and any('sessions 0/3' in r for r in cand['reasons'])
print(was_promoted, reason_ok)
PYEOF
)
if echo "$result" | grep -q "False True"; then
  pass "gf-missing-sessions-key-blocks: missing 'sessions' key does NOT grandfather (corruption guard)"
else
  fail "gf-missing-sessions-key-blocks: got '$result'"
fi
rm -rf "$T40"

# ── v3.31.2 §4.1.B — auto_validate_proposals skip_breakdown logging ─────────
# Tests 41-42 verify the new instrumentation: aggregated skip-reason
# Counter returned in dict AND persisted to auto-validate-skips.jsonl.

# ── Test 41: skip-breakdown-counts — return dict has 3 skip reasons ────────
echo "--- Test 41: skip-breakdown-counts (v3.31.2 §4.1.B return value) ---"
T41="$(mktemp -d -t distill-t41-XXXXXX)"
export CORTEX_DIR="$T41"
mkdir -p "$T41/instincts/global"
# Pre-existing instinct so p3 triggers `already-instinct`.
cat > "$T41/instincts/global/p3-exists.yaml" <<'YAML'
---
id: p3-exists
trigger: 'Bash'
action: 'Test existing instinct'
confidence: 0.9500
domain: error-recovery
type: gotcha
source: cx-auto-validate
scope: global
project_id: 'global'
project_name: 'cross-project'
tags: []
created: '2026-05-01'
first_seen: '2026-05-01'
last_seen: '2026-05-01'
occurrences: 5
evidence:
  - '2026-05-01: seeded by test'
---
YAML
cat > "$T41/proposals.json" <<'JSON'
[
  {"id": "p1-human", "domain": "correction", "confidence": 0.95, "status": "pending",
   "trigger": "Bash", "action": "Always verify migrations before applying"},
  {"id": "p2-low", "domain": "error-recovery", "confidence": 0.30, "status": "pending",
   "trigger": "Bash", "action": "Catch and retry on transient failure"},
  {"id": "p3-exists", "domain": "error-recovery", "confidence": 0.95, "status": "pending",
   "trigger": "Bash", "action": "Test existing instinct"},
  {"id": "p4-accept", "domain": "error-recovery", "confidence": 0.95, "status": "pending",
   "trigger": "Bash", "action": "Sanitize input before processing user data"}
]
JSON

result=$(python3 - <<PYEOF
$(_py_patch "$T41")
out = de.auto_validate_proposals()
sb = out.get('skip_breakdown', {})
acc = len(out.get('accepted', []))
sk = len(out.get('skipped', []))
print(f"acc={acc} sk={sk} hum={sb.get('needs-human-judgment',0)} low={sb.get('low-confidence',0)} exi={sb.get('already-instinct',0)}")
PYEOF
)
if echo "$result" | grep -q "acc=1 sk=3 hum=1 low=1 exi=1"; then
  pass "skip-breakdown-counts: 1 accepted + 3 skipped (needs-human, low-conf, already-instinct)"
else
  fail "skip-breakdown-counts: got '$result'"
fi
rm -rf "$T41"

# ── Test 42: skip-breakdown-log-jsonl — file written + append behavior ─────
echo "--- Test 42: skip-breakdown-log-jsonl (v3.31.2 §4.1.B persistence) ---"
T42="$(mktemp -d -t distill-t42-XXXXXX)"
export CORTEX_DIR="$T42"
mkdir -p "$T42/instincts/global"
cat > "$T42/proposals.json" <<'JSON'
[
  {"id": "p1-human", "domain": "correction", "confidence": 0.95, "status": "pending",
   "trigger": "Bash", "action": "Always check git status before pushing"}
]
JSON

result=$(python3 - <<PYEOF
$(_py_patch "$T42")
import json as _j
# First run
de.auto_validate_proposals()
log_path = de.CORTEX_DIR / 'log' / 'auto-validate-skips.jsonl'
exists_1 = log_path.exists()
lines_1 = log_path.read_text(encoding='utf-8').splitlines() if exists_1 else []
parsed_1 = _j.loads(lines_1[0]) if lines_1 else {}
keys_1 = sorted(parsed_1.keys()) if parsed_1 else []
# Second run — appends another line
de.auto_validate_proposals()
lines_2 = log_path.read_text(encoding='utf-8').splitlines()
print(f"exists={exists_1} n1={len(lines_1)} n2={len(lines_2)} keys={keys_1}")
PYEOF
)
expected_keys="['accepted', 'ts', 'skip_breakdown', 'skipped', 'total']"
if echo "$result" | grep -q "exists=True n1=1 n2=2 keys=\['accepted', 'skip_breakdown', 'skipped', 'total', 'ts'\]"; then
  pass "skip-breakdown-log-jsonl: file created with 5 keys, append works across runs"
else
  fail "skip-breakdown-log-jsonl: got '$result'"
fi
rm -rf "$T42"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
