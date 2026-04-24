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

# Test 12b: topic-overlap gate rejects false positives (v3.13.2)
# Same domain, both contain always/never, but about different subjects → NOT a contradiction
result=$(python3 -c "
from dream_cycle import detect_contradictions
instincts = [
    {'id': 'a', 'action': 'Always include -i ~/.ssh/hetzner-fersora when connecting', 'domain': 'gotcha'},
    {'id': 'b', 'action': 'NEVER --no-verify on git push, bypasses pre-push hooks', 'domain': 'gotcha'},
]
c = detect_contradictions(instincts)
print(len(c))
")
[ "$result" = "0" ] && pass "topic-overlap gate rejects unrelated always/never" || fail "false positive not filtered=$result"

# Test 12c: real contradiction with shared subject is still detected
result=$(python3 -c "
from dream_cycle import detect_contradictions
instincts = [
    {'id': 'a', 'action': 'Always mock the Supabase client in unit tests', 'domain': 'testing'},
    {'id': 'b', 'action': 'Never mock the Supabase client, use real integration tests', 'domain': 'testing'},
]
c = detect_contradictions(instincts)
print(len(c))
")
[ "$result" = "1" ] && pass "real contradiction detected after gate" || fail "real contradiction missed=$result"

# Test 12d: opt-out via threshold=0 preserves legacy behavior
result=$(python3 -c "
from dream_cycle import detect_contradictions
instincts = [
    {'id': 'a', 'action': 'Always use X for feature Y', 'domain': 'gotcha'},
    {'id': 'b', 'action': 'Never touch unrelated file Z during deploy', 'domain': 'gotcha'},
]
c = detect_contradictions(instincts, min_action_overlap=0)
print(len(c))
")
[ "$result" = "1" ] && pass "threshold=0 restores legacy keyword-only detection" || fail "opt-out broken=$result"

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
PYTHONPATH="$PROJECT_ROOT/hooks/lib" python3 -c "
from dream_cycle import apply_staleness_decay
from datetime import datetime, timedelta

def make_inst(confidence, days_ago):
    ts = (datetime.now() - timedelta(days=days_ago)).strftime('%Y-%m-%dT%H:%M:%SZ')
    return {'id': 'test', 'confidence': confidence, 'last_seen': ts, 'action': 'test'}

# Test 1: 0.80 confidence, 61 days stale => 0.70 (linear: 0.80 - 0.05*2)
# Use 61 to guarantee 2 full 30-day periods (staleness_score may be days-1)
inst60 = make_inst(0.80, 61)
active, _ = apply_staleness_decay([inst60])
assert len(active) == 1, f'Expected active, got archived'
assert abs(active[0]['confidence'] - 0.70) < 0.01, f'Expected ~0.70, got {active[0][\"confidence\"]}'
print('PASS: decay(0.80, 61d) = 0.70')

# Test 2: 0.80 confidence, 31 days stale => 0.75
inst30 = make_inst(0.80, 31)
active2, _ = apply_staleness_decay([inst30])
assert abs(active2[0]['confidence'] - 0.75) < 0.01, f'Expected ~0.75, got {active2[0][\"confidence\"]}'
print('PASS: decay(0.80, 31d) = 0.75')

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

# ── Cleanup Module Tests ─────────────────────────────────────────────

echo "--- Module 6: Cleanup ---"

# Setup temp dir for cleanup tests (trap ensures cleanup on failure)
CLEANUP_TMP=$(mktemp -d)
trap 'rm -rf "$CLEANUP_TMP" 2>/dev/null' EXIT
mkdir -p "$CLEANUP_TMP/projects/abc123def456"
mkdir -p "$CLEANUP_TMP/projects/orphan_no_reg"
mkdir -p "$CLEANUP_TMP/projects/stale_proj_99/observations.archive"

# Create registry with abc123 (exists) + dead_entry (missing dir) + stale_proj_99
cat > "$CLEANUP_TMP/projects/registry.json" << 'REGEOF'
{
  "abc123def456": {"name": "active-project", "last_seen": "2026-04-13T10:00:00Z"},
  "dead_entry_id": {"name": "deleted-project", "last_seen": "2026-04-01T10:00:00Z"},
  "stale_proj_99": {"name": "stale-project", "last_seen": "2025-01-01T10:00:00Z"}
}
REGEOF

# Test 27: Detect dead registry entry (dir missing)
result=$(python3 -c "
from dream_cycle import detect_orphan_projects
orphans = detect_orphan_projects('$CLEANUP_TMP')
dead = [o for o in orphans if o['type'] == 'dead_entry']
print(len(dead))
")
[ "$result" = "1" ] && pass "orphan: dead registry entry detected" || fail "dead_entry=$result"

# Test 28: Detect orphan directory (not in registry)
result=$(python3 -c "
from dream_cycle import detect_orphan_projects
orphans = detect_orphan_projects('$CLEANUP_TMP')
orphan_dirs = [o for o in orphans if o['type'] == 'orphan_dir']
print(len(orphan_dirs))
")
[ "$result" = "1" ] && pass "orphan: orphan directory detected" || fail "orphan_dir=$result"

# Test 29: Detect stale project (last_seen > 90d)
result=$(python3 -c "
from dream_cycle import detect_orphan_projects
orphans = detect_orphan_projects('$CLEANUP_TMP')
stale = [o for o in orphans if o['type'] == 'stale_project']
print(len(stale))
")
[ "$result" = "1" ] && pass "orphan: stale project detected" || fail "stale=$result"

# Test 30: Expired context.md detected (>14d)
# Create context.md and backdate it to 20 days ago
touch "$CLEANUP_TMP/projects/abc123def456/context.md"
python3 -c "
import os, time
p = '$CLEANUP_TMP/projects/abc123def456/context.md'
old = time.time() - (20 * 86400)
os.utime(p, (old, old))
"
result=$(python3 -c "
from dream_cycle import cleanup_expired_context
expired = cleanup_expired_context('$CLEANUP_TMP', ttl_days=14)
print(len(expired))
")
[ "$result" = "1" ] && pass "context: expired context.md detected" || fail "expired_ctx=$result"

# Test 31: Fresh context.md NOT detected (<14d)
touch "$CLEANUP_TMP/projects/orphan_no_reg/context.md"
result=$(python3 -c "
from dream_cycle import cleanup_expired_context
expired = cleanup_expired_context('$CLEANUP_TMP', ttl_days=14)
# orphan_no_reg has fresh context.md, should not appear
fresh = [e for e in expired if e['project_id'] == 'orphan_no_reg']
print(len(fresh))
")
[ "$result" = "0" ] && pass "context: fresh context.md not flagged" || fail "fresh_ctx=$result"

# Test 32: Old archives detected (>90d)
touch "$CLEANUP_TMP/projects/stale_proj_99/observations.archive/obs-old.jsonl"
python3 -c "
import os, time
p = '$CLEANUP_TMP/projects/stale_proj_99/observations.archive/obs-old.jsonl'
old = time.time() - (100 * 86400)
os.utime(p, (old, old))
"
result=$(python3 -c "
from dream_cycle import consolidate_old_archives
archives = consolidate_old_archives('$CLEANUP_TMP', days=90)
print(len(archives))
")
[ "$result" = "1" ] && pass "archives: old archive files detected" || fail "old_archives=$result"

# Cleanup temp dir
rm -rf "$CLEANUP_TMP"

echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
