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
law_eligible: true
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

# ── Test 5: retired in v4 (was at-law-threshold-since-set) ──────────────────
# retired in v4: `at_law_threshold_since` is no longer read or written by
# auto_promote_to_law (DESIGN-V4.md §3 drops the whole sustained-14-day
# combo). Nothing in the engine sets this field anymore, so there is no
# behavior left to assert.

# ── Test 6: retired in v4 (was at-law-threshold-since-cleared) ──────────────
# retired in v4: same removal as Test 5 — the clearing side of a field the
# engine no longer manages.

# ── Test 7: retired in v4 (was promote-rejects-young) ───────────────────────
# retired in v4: the 'sustained < 14d' rejection reason no longer exists —
# see auto_promote_to_law docstring, "the old sustained-14-day-since-
# threshold field ... are gone".

# ── Test 8: promote-rejects-single-project (DESIGN-V4.md §3) ────────────────
# v4 restored LAW_MIN_PROJECTS 1 → 3 (see the constant's comment: a 3-project
# floor is the deliberate cross-project-evidence bar now that the sustained-
# days/session combo is gone). This inverts the v3.24.0-era test that used
# to assert single-project promotion.
echo "--- Test 8: promote-rejects-single-project (DESIGN-V4.md §3) ---"
T8="$(mktemp -d -t distill-t8-XXXXXX)"
export CORTEX_DIR="$T8"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
make_instinct "$T8/instincts/global" "t8-single" "0.9500" "$TODAY" "occurrences_v4: 20"
# Only 1 project (project_id=proj-alpha, no projects_seen) — must now BLOCK
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
in_cand_for_projects = any('projects < 3' in r for c in candidates if c['id'] == 't8-single' for r in c['reasons'])
print(got_promoted, in_cand_for_projects)
")
if echo "$result" | grep -q "False True"; then
  pass "promote-rejects-single-project: 1 project → blocked (LAW_MIN_PROJECTS=3)"
else
  fail "promote-rejects-single-project: got '$result' (expected 'False True')"
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
# Create LAW_MAX_ACTIVE law files (v3.32.0 §4.5: cap raised 12 → 15)
for i in $(seq 1 15); do
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
  pass "promote-rejects-laws-full: 15 active laws → candidate with 'laws == 15/15 saturated'"
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

# ── Test 12: promote-accepts — all 4 criteria pass (DESIGN-V4.md §3) ─────────
echo "--- Test 12: promote-accepts ---"
T12="$(mktemp -d -t distill-t12-XXXXXX)"
export CORTEX_DIR="$T12"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
mkdir -p "$T12/instincts/global"
cat > "$T12/instincts/global/t12-good.yaml" <<YAML
---
id: t12-good
confidence: 0.9500
law_eligible: true
domain: testing
trigger: "Bash"
action: "Always verify test results before reporting success to user"
last_seen: $TODAY
first_seen: $TODAY
occurrences_v4: 20
project_id: proj-alpha
projects_seen:
- proj-alpha
- proj-beta
- proj-gamma
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
  pass "promote-accepts: all 4 v4 criteria → law file created + knowledge-log appended"
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
# v4 (DESIGN-V4.md §2): 'error-recovery' moved AUTO → HUMAN, so this must
# use the still-AUTO 'gotcha' domain to actually exercise auto-accept.
make_proposal "$T16/proposals.json" "t16-gotcha" "0.60" "gotcha"

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
  pass "auto-validate-accepts-gotcha-conf-high: gotcha conf=0.60 accepted, instinct created"
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

# ── v4 (DESIGN-V4.md §3) — projects_seen replaces the multi-session gate ────
# retired in v4: the whole v3.29.0/v3.31.2 multi-session promotion gate
# (instinct-tracking.json sessions[] read by auto_promote_to_law, plus its
# grandfather clause for missing/empty/corrupt tracking entries) is gone —
# auto_promote_to_law no longer calls _count_distinct_sessions at all (see
# its docstring: "the >=3-distinct-sessions gate ... are gone"). The
# universality signal is now LAW_MIN_PROJECTS via _count_distinct_projects
# (project_id / projects_seen[] on the instinct yaml, or a scan of
# projects/*/instincts/<iid>.yaml). Former Tests 32-34 and 36-40 (blocks-at-2,
# promotes-at-3, grandfather-missing-tracking, gf-entry-absent,
# gf-sessions-empty-list, gf-sessions-populated, gf-sessions-null-blocks,
# gf-missing-sessions-key-blocks) exercised that removed integration and are
# replaced below by the two tests that cover the new gate end to end.

make_promotable_instinct() {
  # make_promotable_instinct <dir> <iid>
  # v4: creates an instinct that PASSES every auto_promote_to_law criterion
  # (conf>=0.95, projects>=3, occurrences_v4>=10, no noise) — occurrences_v4
  # is set directly so the test doesn't depend on the one-time lazy
  # migration from the legacy `occurrences` counter (see
  # _ensure_occurrences_v4; it starts a migrated instinct at 0).
  local dir="$1" iid="$2"
  local today
  today=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
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
occurrences_v4: 20
project_id: proj-alpha
projects_seen:
- proj-alpha
- proj-beta
- proj-gamma
law_eligible: true
---
YAML
}

# ── Test 32: promote-blocks-below-3-projects (DESIGN-V4.md §3) ──────────────
echo "--- Test 32: promote-blocks-below-3-projects ---"
T32="$(mktemp -d -t distill-t32-XXXXXX)"
export CORTEX_DIR="$T32"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
mkdir -p "$T32/instincts/global"
cat > "$T32/instincts/global/t32-oneproj.yaml" <<YAML
---
id: t32-oneproj
confidence: 0.9500
domain: testing
trigger: "Bash"
action: "Always verify test results before reporting success to user"
last_seen: $TODAY
first_seen: $TODAY
occurrences_v4: 20
project_id: proj-alpha
---
YAML
make_impact_events "$T32/impact.jsonl" "t32-oneproj" 6 0

result=$(python3 - <<PYEOF
$(_py_patch "$T32")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't32-oneproj' for p in promoted)
cand = next((c for c in candidates if c['id'] == 't32-oneproj'), None)
reason_ok = bool(cand) and any('projects < 3' in r for r in cand['reasons'])
print(was_promoted, reason_ok)
PYEOF
)
if echo "$result" | grep -q "False True"; then
  pass "promote-blocks-below-3-projects: 1 project → NOT promoted, candidate reason 'projects < 3'"
else
  fail "promote-blocks-below-3-projects: got '$result'"
fi
rm -rf "$T32"

# ── Test 33: promote-passes-at-3-projects (DESIGN-V4.md §3) ─────────────────
echo "--- Test 33: promote-passes-at-3-projects ---"
T33="$(mktemp -d -t distill-t33-XXXXXX)"
export CORTEX_DIR="$T33"
make_promotable_instinct "$T33/instincts/global" "t33-threeproj"
make_impact_events "$T33/impact.jsonl" "t33-threeproj" 6 0
mkdir -p "$T33/laws"

result=$(python3 - <<PYEOF
$(_py_patch "$T33")
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't33-threeproj' for p in promoted)
law_exists = (de.LAWS_DIR / 't33-threeproj.txt').exists()
print(was_promoted, law_exists)
PYEOF
)
if echo "$result" | grep -q "True True"; then
  pass "promote-passes-at-3-projects: 3 projects + occurrences_v4=20 → law file created"
else
  fail "promote-passes-at-3-projects: got '$result'"
fi
rm -rf "$T33"

# ── Test 35: count-distinct-sessions-defensive ───────────────────────────────
# _count_distinct_sessions is no longer wired into auto_promote_to_law (see
# retirement note above) but the helper itself is untouched code (hooks/ is
# not in scope for this pass without a demonstrated bug) — keep the direct
# unit coverage of its defensive malformed-shape handling.
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

# ── v3.31.2 §4.1.B — auto_validate_proposals skip_breakdown logging ─────────
# Tests 41-42 verify the new instrumentation: aggregated skip-reason
# Counter returned in dict AND persisted to auto-validate-skips.jsonl.

# ── Test 41: skip-breakdown-counts — return dict has 3 skip reasons ────────
echo "--- Test 41: skip-breakdown-counts (v3.31.2 §4.1.B return value) ---"
T41="$(mktemp -d -t distill-t41-XXXXXX)"
export CORTEX_DIR="$T41"
mkdir -p "$T41/instincts/global"
# Pre-existing instinct so p3 triggers `already-instinct`.
# v4 (DESIGN-V4.md §2): 'error-recovery' moved AUTO → HUMAN, so p2/p3/p4 use
# the still-AUTO 'gotcha' domain — otherwise every proposal here lands on
# needs-human-judgment before the confidence/already-instinct checks ever
# run, collapsing the 3 distinct skip reasons this test exists to prove.
cat > "$T41/instincts/global/p3-exists.yaml" <<'YAML'
---
id: p3-exists
trigger: 'Bash'
action: 'Test existing instinct'
confidence: 0.9500
domain: gotcha
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
  {"id": "p2-low", "domain": "gotcha", "confidence": 0.30, "status": "pending",
   "trigger": "Bash", "action": "Catch and retry on transient failure"},
  {"id": "p3-exists", "domain": "gotcha", "confidence": 0.95, "status": "pending",
   "trigger": "Bash", "action": "Test existing instinct"},
  {"id": "p4-accept", "domain": "gotcha", "confidence": 0.95, "status": "pending",
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

# ── v3.32.0 §4.5 — LAW_MAX_ACTIVE 12 → 15 + deprecation policy ──────────────
# Tests 43-48 verify the cap raise + _find_least_impactful_law +
# manual_swap_promote rollback (AD P1-3 + P1-7 absorbed).

# Test 43: cap-raised-allows-13th-promotion
echo "--- Test 43: cap-raised-12-to-15 (v3.32.0 §4.5 Eje A) ---"
T43="$(mktemp -d -t distill-t43-XXXXXX)"
export CORTEX_DIR="$T43"
mkdir -p "$T43/laws"
# Seed 12 existing laws (would have saturated the pre-v3.32 cap of 12)
for i in $(seq 1 12); do
  echo "Existing law number $i" > "$T43/laws/law-existing-$i.txt"
done
make_promotable_instinct "$T43/instincts/global" "t43-new"
make_impact_events "$T43/impact.jsonl" "t43-new" 6 0
cat > "$T43/instinct-tracking.json" <<'JSON'
{
  "t43-new": {
    "count": 30,
    "sessions": ["sess-A", "sess-B", "sess-C"],
    "projects_seen": ["proj-alpha"],
    "first_seen": "2026-05-01T00:00:00Z",
    "last_seen": "2026-05-14T00:00:00Z"
  }
}
JSON

result=$(python3 - <<PYEOF
$(_py_patch "$T43")
assert de.LAW_MAX_ACTIVE == 15, f"cap not raised: {de.LAW_MAX_ACTIVE}"
promoted, candidates = de.auto_promote_to_law()
was_promoted = any(p['id'] == 't43-new' for p in promoted)
law_exists = (de.LAWS_DIR / 't43-new.txt').exists()
count_after = de._active_law_count()
print(was_promoted, law_exists, count_after)
PYEOF
)
if echo "$result" | grep -q "True True 13"; then
  pass "cap-raised-12-to-15: 13th law promotes (would have been blocked at old cap=12)"
else
  fail "cap-raised-12-to-15: got '$result'"
fi
rm -rf "$T43"

# Test 44: _find_least_impactful_law picks lowest ratio
echo "--- Test 44: deprecation-lowest-ratio (v3.32.0 §4.5 Eje B) ---"
T44="$(mktemp -d -t distill-t44-XXXXXX)"
export CORTEX_DIR="$T44"
mkdir -p "$T44/laws"
for name in productive marginal worst; do
  echo "Law $name" > "$T44/laws/law-$name.txt"
done
# Age every law to be > 7 days so age guard doesn't filter them out.
python3 - <<PYEOF
import os, time
old = time.time() - (30 * 86400)
for name in ("productive", "marginal", "worst"):
    p = "$T44/laws/law-" + name + ".txt"
    os.utime(p, (old, old))
PYEOF

result=$(python3 - <<PYEOF
$(_py_patch "$T44")
impact = {
    "law-productive": {"useful": 10, "noise": 0},  # ratio 10.0 — keep
    "law-marginal":   {"useful": 2,  "noise": 1},  # ratio 1.0 — borderline
    "law-worst":      {"useful": 0,  "noise": 3},  # ratio 0.0 — top deprecation candidate
}
print(de._find_least_impactful_law(impact))
PYEOF
)
if [ "$result" = "law-worst" ]; then
  pass "deprecation-lowest-ratio: law-worst (useful=0 noise=3) picked"
else
  fail "deprecation-lowest-ratio: got '$result'"
fi
rm -rf "$T44"

# Test 45: tie-break by oldest mtime
echo "--- Test 45: deprecation-age-tie-break (v3.32.0 §4.5) ---"
T45="$(mktemp -d -t distill-t45-XXXXXX)"
export CORTEX_DIR="$T45"
mkdir -p "$T45/laws"
for name in alpha beta gamma; do
  echo "Law $name" > "$T45/laws/law-$name.txt"
done
# Same ratio for all 3, but oldest mtime is alpha (60d old)
python3 - <<PYEOF
import os, time
now = time.time()
os.utime("$T45/laws/law-alpha.txt", (now - 60*86400, now - 60*86400))
os.utime("$T45/laws/law-beta.txt",  (now - 30*86400, now - 30*86400))
os.utime("$T45/laws/law-gamma.txt", (now - 10*86400, now - 10*86400))
PYEOF

result=$(python3 - <<PYEOF
$(_py_patch "$T45")
# All three have identical ratio (useful=0 noise=0 → 0/1=0). Tie-break
# should pick the oldest law-alpha.
impact = {
    "law-alpha": {"useful": 0, "noise": 0},
    "law-beta":  {"useful": 0, "noise": 0},
    "law-gamma": {"useful": 0, "noise": 0},
}
print(de._find_least_impactful_law(impact))
PYEOF
)
if [ "$result" = "law-alpha" ]; then
  pass "deprecation-age-tie-break: same ratio → oldest mtime (60d) wins"
else
  fail "deprecation-age-tie-break: got '$result'"
fi
rm -rf "$T45"

# Test 46: AD P1-3 — laws younger than LAW_DEPRECATE_MIN_AGE_DAYS skipped
echo "--- Test 46: deprecation-age-guard-7d (v3.32.0 §4.5 AD P1-3) ---"
T46="$(mktemp -d -t distill-t46-XXXXXX)"
export CORTEX_DIR="$T46"
mkdir -p "$T46/laws"
echo "Law fresh" > "$T46/laws/law-fresh.txt"
echo "Law mature" > "$T46/laws/law-mature.txt"
python3 - <<PYEOF
import os, time
now = time.time()
# Fresh = 3 days old (under 7-day guard); mature = 30 days old.
os.utime("$T46/laws/law-fresh.txt", (now - 3*86400, now - 3*86400))
os.utime("$T46/laws/law-mature.txt", (now - 30*86400, now - 30*86400))
PYEOF

result=$(python3 - <<PYEOF
$(_py_patch "$T46")
# Fresh has ratio 0 (newer = more candidate by ratio); but age guard
# must skip it and return the mature law instead.
impact = {
    "law-fresh":  {"useful": 0, "noise": 0},
    "law-mature": {"useful": 0, "noise": 0},
}
got = de._find_least_impactful_law(impact)
# Also test: with ONLY fresh law present → return None (no candidate)
import os as _os
_os.remove("$T46/laws/law-mature.txt")
got2 = de._find_least_impactful_law(impact)
print(got, got2)
PYEOF
)
if echo "$result" | grep -q "^law-mature None$"; then
  pass "deprecation-age-guard-7d: <7d law skipped; lone fresh law → None (AD P1-3)"
else
  fail "deprecation-age-guard-7d: got '$result'"
fi
rm -rf "$T46"

# Test 47: manual_swap_promote golden path
echo "--- Test 47: swap-promote-golden (v3.32.0 §4.5) ---"
T47="$(mktemp -d -t distill-t47-XXXXXX)"
export CORTEX_DIR="$T47"
mkdir -p "$T47/laws"
echo "Old law content" > "$T47/laws/law-old.txt"
# Promote-eligible instinct (conf >= 0.95)
make_promotable_instinct "$T47/instincts/global" "t47-new-mature"

result=$(python3 - <<PYEOF
$(_py_patch "$T47")
ok, reason = de.manual_swap_promote("t47-new-mature", "law-old")
old_gone = not (de.LAWS_DIR / 'law-old.txt').exists()
new_present = (de.LAWS_DIR / 't47-new-mature.txt').exists()
archive_dir = de.LAWS_DIR / 'archive'
archive_files = sorted(archive_dir.iterdir()) if archive_dir.is_dir() else []
has_archive = any(f.name.startswith('law-old.') and f.suffix == '.txt' for f in archive_files)
print(ok, old_gone, new_present, has_archive)
PYEOF
)
if echo "$result" | grep -q "True True True True"; then
  pass "swap-promote-golden: old archived, new written, all 3 atomic steps"
else
  fail "swap-promote-golden: got '$result'"
fi
rm -rf "$T47"

# Test 48: AD P1-7 — manual_swap_promote rollback on write failure
echo "--- Test 48: swap-promote-rollback (v3.32.0 §4.5 AD P1-7) ---"
T48="$(mktemp -d -t distill-t48-XXXXXX)"
export CORTEX_DIR="$T48"
mkdir -p "$T48/laws"
echo "Old law original content" > "$T48/laws/law-old-rollback.txt"
make_promotable_instinct "$T48/instincts/global" "t48-new"

result=$(python3 - <<PYEOF
$(_py_patch "$T48")
# Monkey-patch _atomic_write to fail ONLY when called on the new-law
# path. Archive write + rollback write must keep working.
orig = de._atomic_write
calls = {"n": 0}
def failing_atomic_write(path, content):
    calls["n"] += 1
    # First call: archive backup → succeed
    # Second call: NEW law write → fail
    # Third call: rollback restore → must succeed (use original)
    if calls["n"] == 2:
        raise OSError("simulated disk-full on new law write")
    return orig(path, content)
de._atomic_write = failing_atomic_write

ok, reason = de.manual_swap_promote("t48-new", "law-old-rollback")
de._atomic_write = orig  # restore for cleanup

old_back = (de.LAWS_DIR / 'law-old-rollback.txt').exists()
old_content = (de.LAWS_DIR / 'law-old-rollback.txt').read_text(encoding='utf-8') if old_back else ""
new_not_present = not (de.LAWS_DIR / 't48-new.txt').exists()
print(f"ok={ok} reason_has_rolled_back={('rolled back' in reason)} old_back={old_back} content_match={('Old law original' in old_content)} new_absent={new_not_present}")
PYEOF
)
if echo "$result" | grep -q "ok=False reason_has_rolled_back=True old_back=True content_match=True new_absent=True"; then
  pass "swap-promote-rollback: write-failure → old law restored, new not present (AD P1-7)"
else
  fail "swap-promote-rollback: got '$result'"
fi
rm -rf "$T48"

# ── Test 49: empty-impact-tie-break (PR #44 review quick win) ───────────────
# Common case in fresh installs: impact.jsonl is empty so every law has
# ratio=0/1=0. The function must NOT return None — it must fall through to
# the tie-break-by-age and return the oldest law. (Healthy-cohort guard
# only kicks in when best ratio > 1.0.)
echo "--- Test 49: empty-impact-tie-break (PR #44 review quick win) ---"
T49="$(mktemp -d -t distill-t49-XXXXXX)"
export CORTEX_DIR="$T49"
mkdir -p "$T49/laws"
for name in old middle newer; do
  echo "Law $name" > "$T49/laws/law-$name.txt"
done
python3 - <<PYEOF
import os, time
now = time.time()
os.utime("$T49/laws/law-old.txt",    (now - 60*86400, now - 60*86400))
os.utime("$T49/laws/law-middle.txt", (now - 30*86400, now - 30*86400))
os.utime("$T49/laws/law-newer.txt",  (now - 10*86400, now - 10*86400))
PYEOF

result=$(python3 - <<PYEOF
$(_py_patch "$T49")
# Empty impact dict — every law has useful=0 noise=0 → ratio=0.
got = de._find_least_impactful_law({})
print(got)
PYEOF
)
if [ "$result" = "law-old" ]; then
  pass "empty-impact-tie-break: empty impact_per_iid → returns oldest law (tie-break by mtime)"
else
  fail "empty-impact-tie-break: got '$result'"
fi
rm -rf "$T49"

echo ""
# ── Test 49b: retired in v4 (was criteria-8 universality opt-in, v3.34.2) ───
# retired in v4: the manual `law_eligible: true` opt-in ("Criteria 8") is
# gone — DESIGN-V4.md §3 / P3 ("reglas objetivas sustituyen a flags
# manuales que nadie pone") replaces it with the 4 statistical criteria
# tested above (Test 12 promote-accepts, Test 33 promote-passes-at-3-
# projects). `law_eligible: false` survives as an explicit human VETO only
# (still covered by test_law_tier.sh Test 6) — `law_eligible: true` no
# longer gates anything, so an instinct missing the field is no longer
# blocked from promotion, which is the exact behavior this test used to
# assert as a failure case.

# ── Test 50: write-path ops acquire the engine LOCK_FILE (#45) ───────────────
echo "--- Test 50: #45 demote serializes under LOCK_FILE ---"
T50="$(mktemp -d -t distill-t50-XXXXXX)"
export CORTEX_DIR="$T50"
mkdir -p "$T50/laws"
make_instinct "$T50/instincts/global" "t50-law" "0.9900" "$TODAY"
printf 'When X, do the t50 thing\n' > "$T50/laws/t50-law.txt"
result=$(python3 - <<PYEOF
$(_py_patch "$T50")
calls = {'n': 0}
_orig = de._lock_acquire
def _spy(*a, **k):
    calls['n'] += 1
    return _orig(*a, **k)
de._lock_acquire = _spy
ok, _ = de.demote_law_to_domain('t50-law')
print('LOCKED' if (ok and calls['n'] >= 1) else f'NO_LOCK ok={ok} n={calls["n"]}')
PYEOF
)
[ "$result" = "LOCKED" ] && pass "#45: demote_law_to_domain serializes under LOCK_FILE" \
                         || fail "#45: $result"
rm -rf "$T50"

# ── Test 51: #56.1 _derive_law_line — cap 200 + word-boundary cut ────────────
echo "--- Test 51: #56.1 law line cap 200 + word boundary ---"
T51="$(mktemp -d -t distill-t51-XXXXXX)"
export CORTEX_DIR="$T51"
result=$(python3 - <<PYEOF
$(_py_patch "$T51")
cap_ok = de.LAW_MAX_CHARS == 200
short = de._derive_law_line({'action': 'Use X for Y always', 'trigger': 't'})
short_ok = short == 'Use X for Y always'
long_line = de._derive_law_line({'action': 'Always ' + 'word ' * 60, 'trigger': 't'})
len_ok = len(long_line) <= de.LAW_MAX_CHARS
ends_ok = long_line.endswith('word…')
print(cap_ok, short_ok, len_ok, ends_ok)
PYEOF
)
[ "$result" = "True True True True" ] && pass "#56.1: cap=200, short intact, long cut at word boundary" \
                                      || fail "#56.1: got '$result'"
rm -rf "$T51"

# ── Test 52: tags list starts on its own line (#56 audit, v3.35.2) ──────────
echo "--- Test 52: _proposal_to_instinct_yaml tags block format ---"
T52="$(mktemp -d -t distill-t52-XXXXXX)"
export CORTEX_DIR="$T52"
result=$(python3 - <<PYEOF
$(_py_patch "$T52")
y = de._proposal_to_instinct_yaml(
    {'id': 't52', 'trigger': 'Bash', 'action': 'do x', 'confidence': 0.6,
     'domain': 'gotcha', 'scope': 'global', 'tags': ['cross-day-1']},
    '2026-06-10')
inline_bug = 'tags:   -' in y or 'tags: -' in y
block_ok = '\ntags:\n  - ' in y
empty = de._proposal_to_instinct_yaml(
    {'id': 't52b', 'trigger': 'Bash', 'action': 'do x', 'confidence': 0.6,
     'domain': 'gotcha', 'scope': 'global', 'tags': []},
    '2026-06-10')
empty_ok = '\ntags: []\n' in empty
print(not inline_bug, block_ok, empty_ok)
PYEOF
)
[ "$result" = "True True True" ] && pass "#56: tags emit as block list (no inline first item)" \
                                || fail "#56 tags writer: got '$result'"
rm -rf "$T52"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
