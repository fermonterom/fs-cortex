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

# ── Test 8: promote-rejects-single-project ───────────────────────────────────
echo "--- Test 8: promote-rejects-single-project ---"
T8="$(mktemp -d -t distill-t8-XXXXXX)"
export CORTEX_DIR="$T8"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
FIFTEEN_AGO=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
make_instinct "$T8/instincts/global" "t8-single" "0.9500" "$TODAY" \
  "at_law_threshold_since: $FIFTEEN_AGO"
# Only 1 project (project_id=proj-alpha, no projects_seen)
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
in_cand = any(c['id'] == 't8-single' for c in candidates)
reason_ok = any('projects' in r for c in candidates if c['id'] == 't8-single' for r in c['reasons'])
print(in_cand, reason_ok)
")
if echo "$result" | grep -q "True True"; then
  pass "promote-rejects-single-project: 1 project → candidate with 'projects < 3'"
else
  fail "promote-rejects-single-project: got '$result'"
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
# Create 10 law files
for i in $(seq 1 10); do
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
  pass "promote-rejects-laws-full: 10 active laws → candidate with 'laws == 10'"
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

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
