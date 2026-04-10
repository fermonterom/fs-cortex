#!/usr/bin/env bash
# Dream Cycle tests — adapted from Sinapsis's 40 tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Make dream_cycle importable
export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

echo "=== Dream Cycle Tests ==="
echo ""

# ── Jaccard Dedup Tests ──────────────────────────────────────────────

echo "--- Jaccard Similarity ---"

# Test 1: Identical strings = 1.0
result=$(python3 -c "
from dream_cycle import jaccard_similarity
print(jaccard_similarity('always use const in javascript', 'always use const in javascript'))
")
[ "$result" = "1.0" ] && pass "identical=1.0" || fail "identical=$result"

# Test 2: Completely different = 0.0
result=$(python3 -c "
from dream_cycle import jaccard_similarity
print(jaccard_similarity('use react hooks', 'deploy to kubernetes'))
")
[ "$result" = "0.0" ] && pass "different=0.0" || fail "different=$result"

# Test 3: Similar above threshold
result=$(python3 -c "
from dream_cycle import jaccard_similarity
sim = jaccard_similarity('always use const for variables in functions', 'always use const for declarations in functions')
print('above' if sim >= 0.60 else 'below')
")
[ "$result" = "above" ] && pass "similar>=0.60" || fail "similar=$result"

# Test 4: Empty strings = 0.0
result=$(python3 -c "
from dream_cycle import jaccard_similarity
print(jaccard_similarity('', ''))
")
[ "$result" = "0.0" ] && pass "empty=0.0" || fail "empty=$result"

# Test 5: Unicode/CJK support
result=$(python3 -c "
from dream_cycle import jaccard_similarity
sim = jaccard_similarity('use const variables', 'use const variables')
print('nonzero' if sim > 0 else 'zero')
")
[ "$result" = "nonzero" ] && pass "unicode nonzero" || fail "unicode=$result"

# Test 6: Dedup keeps higher confidence
result=$(python3 -c "
from dream_cycle import dedup_instincts
instincts = [
    {'id': 'a', 'action': 'always use const for variable declarations', 'confidence': 0.80},
    {'id': 'b', 'action': 'always use const for variable declarations please', 'confidence': 0.90},
]
kept = dedup_instincts(instincts, threshold=0.70)
print(kept[0]['id'])
")
[ "$result" = "b" ] && pass "dedup keeps higher confidence" || fail "dedup kept=$result"

# Test 7: Dedup preserves non-duplicates
result=$(python3 -c "
from dream_cycle import dedup_instincts
instincts = [
    {'id': 'a', 'action': 'use react hooks', 'confidence': 0.80},
    {'id': 'b', 'action': 'deploy to kubernetes', 'confidence': 0.70},
]
kept = dedup_instincts(instincts, threshold=0.80)
print(len(kept))
")
[ "$result" = "2" ] && pass "non-duplicates preserved" || fail "non-dup count=$result"

echo ""

# ── Contradiction Detection Tests ────────────────────────────────────

echo "--- Contradiction Detection ---"

# Test 8: always/never detected
result=$(python3 -c "
from dream_cycle import detect_contradictions
instincts = [
    {'id': 'a', 'action': 'always mock the database', 'domain': 'testing'},
    {'id': 'b', 'action': 'never mock the database', 'domain': 'testing'},
]
c = detect_contradictions(instincts)
print(len(c))
")
[ "$result" = "1" ] && pass "always/never detected" || fail "always/never=$result"

# Test 9: Different domains = no contradiction
result=$(python3 -c "
from dream_cycle import detect_contradictions
instincts = [
    {'id': 'a', 'action': 'always mock the database', 'domain': 'testing'},
    {'id': 'b', 'action': 'never mock the database', 'domain': 'production'},
]
c = detect_contradictions(instincts)
print(len(c))
")
[ "$result" = "0" ] && pass "different domains no contradiction" || fail "cross-domain=$result"

# Test 10: No false positive on "document" (Sinapsis bug)
result=$(python3 -c "
from dream_cycle import detect_contradictions
instincts = [
    {'id': 'a', 'action': 'document all API endpoints', 'domain': 'docs'},
    {'id': 'b', 'action': 'domain validation is required', 'domain': 'docs'},
]
c = detect_contradictions(instincts)
print(len(c))
")
[ "$result" = "0" ] && pass "no false positive on document/domain" || fail "false positive=$result"

# Test 11: must/must not detected
result=$(python3 -c "
from dream_cycle import detect_contradictions
instincts = [
    {'id': 'a', 'action': 'you must validate inputs', 'domain': 'security'},
    {'id': 'b', 'action': 'you must not validate inputs', 'domain': 'security'},
]
c = detect_contradictions(instincts)
print(len(c))
")
[ "$result" = "1" ] && pass "must/must not detected" || fail "must=$result"

# Test 12: ES pairs siempre/nunca
result=$(python3 -c "
from dream_cycle import detect_contradictions
instincts = [
    {'id': 'a', 'action': 'siempre usar const', 'domain': 'coding'},
    {'id': 'b', 'action': 'nunca usar const', 'domain': 'coding'},
]
c = detect_contradictions(instincts)
print(len(c))
")
[ "$result" = "1" ] && pass "siempre/nunca detected" || fail "es_pair=$result"

echo ""

# ── Staleness Tests ──────────────────────────────────────────────────

echo "--- Staleness Scoring ---"

# Test 13: Fresh instinct (today) = 0
result=$(python3 -c "
from dream_cycle import staleness_score
from datetime import datetime, timezone
now = datetime.now(timezone.utc).isoformat()
print(staleness_score({'last_seen': now}))
")
[ "$result" = "0" ] && pass "fresh=0" || fail "fresh=$result"

# Test 14: Missing date = 100
result=$(python3 -c "
from dream_cycle import staleness_score
print(staleness_score({}))
")
[ "$result" = "100" ] && pass "missing date=100" || fail "missing=$result"

# Test 15: 45 days = moderate (30-60 range)
result=$(python3 -c "
from dream_cycle import staleness_score
from datetime import datetime, timezone, timedelta
d = (datetime.now(timezone.utc) - timedelta(days=45)).isoformat()
score = staleness_score({'last_seen': d})
print('moderate' if 30 <= score <= 60 else f'wrong:{score}')
")
[ "$result" = "moderate" ] && pass "45d=moderate" || fail "45d=$result"

# Test 16: 120 days = very stale (>90)
result=$(python3 -c "
from dream_cycle import staleness_score
from datetime import datetime, timezone, timedelta
d = (datetime.now(timezone.utc) - timedelta(days=120)).isoformat()
score = staleness_score({'last_seen': d})
print('stale' if score >= 90 else f'wrong:{score}')
")
[ "$result" = "stale" ] && pass "120d>=90" || fail "120d=$result"

# Test 17: Auto-archive at threshold
result=$(python3 -c "
from dream_cycle import apply_staleness_decay
instincts = [
    {'id': 'fresh', 'confidence': 0.80, 'last_seen': '2099-01-01T00:00:00Z'},
    {'id': 'stale', 'confidence': 0.80},  # no last_seen = score 100
]
active, archived = apply_staleness_decay(instincts, archive_threshold=90)
print(f'{len(active)},{len(archived)}')
")
[ "$result" = "1,1" ] && pass "auto-archive stale" || fail "archive=$result"

echo ""

# ── Regex Validation Tests ───────────────────────────────────────────

echo "--- Regex Validation ---"

# Test 18: Valid regex
result=$(python3 -c "
from dream_cycle import validate_trigger_regex
valid, _ = validate_trigger_regex('Bash|Edit|Write')
print(valid)
")
[ "$result" = "True" ] && pass "valid regex accepted" || fail "valid=$result"

# Test 19: Too long
result=$(python3 -c "
from dream_cycle import validate_trigger_regex
valid, reason = validate_trigger_regex('a' * 101)
print(valid, reason)
")
echo "$result" | grep -q "False" && pass "too long rejected" || fail "long=$result"

# Test 20: Nested quantifiers (ReDoS)
result=$(python3 -c "
from dream_cycle import validate_trigger_regex
valid, reason = validate_trigger_regex('(a+)+')
print(valid)
")
[ "$result" = "False" ] && pass "ReDoS rejected" || fail "redos=$result"

# Test 21: Excessive alternations
result=$(python3 -c "
from dream_cycle import validate_trigger_regex
valid, _ = validate_trigger_regex('a|b|c|d|e|f|g')
print(valid)
")
[ "$result" = "False" ] && pass "excessive alternations rejected" || fail "alt=$result"

# Test 22: Invalid regex
result=$(python3 -c "
from dream_cycle import validate_trigger_regex
valid, _ = validate_trigger_regex('[invalid')
print(valid)
")
[ "$result" = "False" ] && pass "invalid regex rejected" || fail "invalid=$result"

echo ""

# ── Health Score Tests ───────────────────────────────────────────────

echo "--- Health Score ---"

# Test 23: Perfect health
result=$(python3 -c "
from dream_cycle import calculate_health_score
score = calculate_health_score({
    'stale_count': 0, 'contradiction_count': 0, 'duplicate_count': 0,
    'law_count': 5, 'avg_confidence': 0.75,
    'last_distill_days': 3, 'last_dream_days': 2,
})
print(score)
")
[ "$result" = "100" ] && pass "perfect=100" || fail "perfect=$result"

# Test 24: Contradictions reduce score
result=$(python3 -c "
from dream_cycle import calculate_health_score
score = calculate_health_score({
    'stale_count': 0, 'contradiction_count': 2, 'duplicate_count': 0,
    'law_count': 0, 'avg_confidence': 0.50,
    'last_distill_days': 3, 'last_dream_days': 2,
})
print('lower' if score < 100 else 'same')
")
[ "$result" = "lower" ] && pass "contradictions reduce score" || fail "contra=$result"

# Test 25: Overdue maintenance reduces score
result=$(python3 -c "
from dream_cycle import calculate_health_score
score = calculate_health_score({
    'stale_count': 0, 'contradiction_count': 0, 'duplicate_count': 0,
    'law_count': 0, 'avg_confidence': 0.50,
    'last_distill_days': 30, 'last_dream_days': 14,
})
print('lower' if score < 100 else 'same')
")
[ "$result" = "lower" ] && pass "overdue maintenance reduces score" || fail "maint=$result"

# Test 26: Score never negative
result=$(python3 -c "
from dream_cycle import calculate_health_score
score = calculate_health_score({
    'stale_count': 50, 'contradiction_count': 10, 'duplicate_count': 20,
    'law_count': 0, 'avg_confidence': 0.10,
    'last_distill_days': 100, 'last_dream_days': 100,
})
print('ok' if score >= 0 else 'negative')
")
[ "$result" = "ok" ] && pass "score >= 0" || fail "negative=$result"

echo ""

# ── Decay formula consistency ─────────────────────────────────────

echo "--- Decay Formula Consistency ---"
PYTHONPATH="$LIB_DIR" python3 -c "
from dream_cycle import apply_staleness_decay
from datetime import datetime, timedelta

def make_inst(confidence, days_ago):
    ts = (datetime.now() - timedelta(days=days_ago)).strftime('%Y-%m-%dT%H:%M:%SZ')
    return {'id': 'test', 'confidence': confidence, 'last_seen': ts, 'action': 'test'}

# Test 1: 0.80 confidence, 60 days stale => 0.70 (linear: 0.80 - 0.05*2)
inst60 = make_inst(0.80, 60)
active, _ = apply_staleness_decay([inst60])
assert len(active) == 1, f'Expected active, got archived'
assert abs(active[0]['confidence'] - 0.70) < 0.01, f'Expected ~0.70, got {active[0][\"confidence\"]}'
print('PASS: decay(0.80, 60d) = 0.70')

# Test 2: 0.80 confidence, 30 days stale => 0.75
inst30 = make_inst(0.80, 30)
active2, _ = apply_staleness_decay([inst30])
assert abs(active2[0]['confidence'] - 0.75) < 0.01, f'Expected ~0.75, got {active2[0][\"confidence\"]}'
print('PASS: decay(0.80, 30d) = 0.75')

# Test 3: 0.80 confidence, 0 days stale => 0.80 (no decay)
inst0 = make_inst(0.80, 0)
active3, _ = apply_staleness_decay([inst0])
assert abs(active3[0]['confidence'] - 0.80) < 0.01, f'Expected ~0.80, got {active3[0][\"confidence\"]}'
print('PASS: decay(0.80, 0d) = 0.80')
" 2>&1 | while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    *) echo "  $line"; fail "decay formula consistency" ;;
  esac
done

echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
