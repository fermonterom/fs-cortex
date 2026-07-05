#!/usr/bin/env bash
# tests/test_cx_maintain_runner.sh — bin/cx-maintain.sh (no-LLM /cx-maintain runner).
# Drives the REAL script in a hermetic sandbox (mktemp -d, never touches real
# ~/.claude/cortex). Covers: exit 0 on repeated runs, compat markers touched,
# valid .review-digest.json, and idempotency (a same-day rerun does not
# re-decay an instinct already decayed today — proves the runner honors
# distill_engine's own last_decay_at guard rather than forcing extra work).
# Run: bash tests/test_cx_maintain_runner.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$PROJECT_ROOT/bin/cx-maintain.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

SANDBOX="$(mktemp -d -t cortex-maintain-runner-test-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== bin/cx-maintain.sh Tests (sandbox: $SANDBOX) ==="
echo

# ── Sandbox layout: mirrors the real CORTEX_DIR tree, isolated per test run ──
CDIR="$SANDBOX/cortex"
mkdir -p "$CDIR/instincts/global" "$CDIR/laws" "$CDIR/projects"

# Force the runner to use the REPO's own hooks/lib, never anything installed
# under ~/.claude — this is the whole point of hermetic sandboxing.
export CORTEX_LIB_DIR="$PROJECT_ROOT/hooks/lib"

# A stale-enough instinct (last_seen 90 days ago) so apply_decay has real
# work to do on the first run, and a fresh one that should never decay.
NINETY_DAYS_AGO=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=90)).strftime('%Y-%m-%d'))")
TODAY=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d'))")

cat > "$CDIR/instincts/global/stale-decay-candidate.yaml" <<YAML
---
id: stale-decay-candidate
confidence: 0.80
domain: testing
scope: global
trigger: 'Bash'
action: 'A stale test instinct that should decay on first run only'
last_seen: ${NINETY_DAYS_AGO}
first_seen: ${NINETY_DAYS_AGO}
status: confirmed
---
YAML

cat > "$CDIR/instincts/global/fresh-instinct.yaml" <<YAML
---
id: fresh-instinct
confidence: 0.75
domain: testing
scope: global
trigger: 'Edit'
action: 'A fresh test instinct that should never decay in this test'
last_seen: ${TODAY}
first_seen: ${TODAY}
status: confirmed
---
YAML

# v4.2.2 — seed learn markers + observations so Test 3b can prove the reset:
# observe.py increments .obs-count and touches .learn-pending at threshold;
# the runner must snapshot the total, zero the count and drop the flag.
mkdir -p "$CDIR/projects/testproj"
printf '{"ts":"2026-07-05T10:00:00Z","ev":"tc","tool":"Bash"}\n%.0s' 1 2 3 > "$CDIR/projects/testproj/observations.jsonl"
echo "7" > "$CDIR/.obs-count"
touch "$CDIR/.learn-pending"

# ── Test 1: first run exits 0 ────────────────────────────────────────────────
echo "--- Test 1: first run exits 0 ---"
OUT1=$(CORTEX_DIR="$CDIR" "$RUNNER" 2>&1)
RC1=$?
[ "$RC1" -eq 0 ] && pass "First run exit 0" || { fail "First run exit $RC1"; echo "$OUT1"; }

# ── Test 2: report shows the stale instinct decayed exactly once ────────────
echo "--- Test 2: first run decays the stale instinct ---"
echo "$OUT1" | grep -q "engine-pass: decayed=1" \
  && pass "First run reports decayed=1" \
  || { fail "Expected decayed=1 in first-run report"; echo "$OUT1" | grep "engine-pass"; }

# ── Test 3: compat markers touched ───────────────────────────────────────────
echo "--- Test 3: compat markers written ---"
if [ -f "$CDIR/.last-distill" ] && [ -f "$CDIR/.last-dream" ]; then
  pass "Both .last-distill and .last-dream exist"
else
  fail ".last-distill or .last-dream missing"
fi

# ── Test 3b: learn markers reset (v4.2.2) ────────────────────────────────────
# Nothing cleared .learn-pending after /cx-analyze retired in v4, so the
# SessionStart "N+ new observations" banner nagged forever. The runner must
# snapshot the obs total, zero .obs-count and drop the flag.
echo "--- Test 3b: learn markers reset after run ---"
LEARN_COUNT=$(cat "$CDIR/.last-learn-count" 2>/dev/null)
OBS_COUNT=$(cat "$CDIR/.obs-count" 2>/dev/null)
if [ "$LEARN_COUNT" = "3" ] && [ "$OBS_COUNT" = "0" ] && [ ! -f "$CDIR/.learn-pending" ]; then
  pass "Learn markers reset (.last-learn-count=3, .obs-count=0, .learn-pending gone)"
else
  fail "Learn markers not reset: last-learn-count='$LEARN_COUNT' obs-count='$OBS_COUNT' pending=$([ -f "$CDIR/.learn-pending" ] && echo yes || echo no)"
fi

# ── Test 4: digest is valid JSON with expected keys ──────────────────────────
echo "--- Test 4: .review-digest.json is valid JSON ---"
if [ -f "$CDIR/.review-digest.json" ]; then
  DIGEST_OK=$(python3 -c "
import json
d = json.load(open('$CDIR/.review-digest.json'))
required = ['generated_at', 'total_items', 'laws_active', 'laws_cap']
print('ok' if all(k in d for k in required) else 'missing-keys')
" 2>&1)
  [ "$DIGEST_OK" = "ok" ] && pass "Digest JSON valid with required keys" || fail "Digest malformed: $DIGEST_OK"
else
  fail ".review-digest.json not written"
fi

# ── Test 5: second (same-day) run exits 0 too ────────────────────────────────
echo "--- Test 5: second run exits 0 ---"
OUT2=$(CORTEX_DIR="$CDIR" "$RUNNER" 2>&1)
RC2=$?
[ "$RC2" -eq 0 ] && pass "Second run exit 0" || { fail "Second run exit $RC2"; echo "$OUT2"; }

# ── Test 6: idempotency — second run does NOT re-decay the same instinct ────
# apply_decay writes last_decay_at=today on the first pass; a same-day rerun
# must see decayed=0 for that instinct. This is the real idempotency proof
# (not just "ran twice without crashing").
echo "--- Test 6: idempotent — no re-decay on same-day rerun ---"
echo "$OUT2" | grep -q "engine-pass: decayed=0" \
  && pass "Second run reports decayed=0 (idempotent)" \
  || { fail "Expected decayed=0 on second run"; echo "$OUT2" | grep "engine-pass"; }

# ── Test 7: fresh instinct never touched by decay in either run ─────────────
echo "--- Test 7: fresh instinct confidence unchanged ---"
FRESH_CONF=$(grep '^confidence:' "$CDIR/instincts/global/fresh-instinct.yaml" | head -1)
[ "$FRESH_CONF" = "confidence: 0.75" ] \
  && pass "Fresh instinct confidence untouched (0.75)" \
  || fail "Fresh instinct confidence changed: $FRESH_CONF"

# ── Test 8: idempotency at the file level — running twice does not duplicate
# marker files, digest, or leave stray lock dirs behind ─────────────────────
echo "--- Test 8: no leftover lock dir after clean exit ---"
if [ -d "$CDIR/.cx-maintain-runner.lock" ]; then
  fail "Runner lock dir left behind after clean exit"
else
  pass "Runner lock dir released"
fi

# ── Test 9: --dry-run makes zero writes ──────────────────────────────────────
echo "--- Test 9: --dry-run writes nothing new ---"
CDIR2="$SANDBOX/cortex-dryrun"
mkdir -p "$CDIR2/instincts/global" "$CDIR2/laws" "$CDIR2/projects"
cp "$CDIR/instincts/global/stale-decay-candidate.yaml" "$CDIR2/instincts/global/stale-decay-candidate.yaml" 2>/dev/null || true
# Reset last_decay_at removed copy back to a decayable state for this sub-test
sed -i.bak '/last_decay_at/d' "$CDIR2/instincts/global/stale-decay-candidate.yaml" 2>/dev/null
rm -f "$CDIR2/instincts/global/stale-decay-candidate.yaml.bak"
OUT9=$(CORTEX_DIR="$CDIR2" "$RUNNER" --dry-run 2>&1)
RC9=$?
if [ "$RC9" -eq 0 ] && [ ! -f "$CDIR2/.review-digest.json" ] && [ ! -f "$CDIR2/.last-distill" ]; then
  pass "--dry-run exits 0 and writes no digest/markers"
else
  fail "--dry-run left writes behind or exited non-zero (rc=$RC9)"
  echo "$OUT9"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
