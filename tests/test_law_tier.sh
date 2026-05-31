#!/usr/bin/env bash
# test_law_tier.sh — v3.34 Core/Domain law split
# Validates: demote_law_to_domain (archive .txt + ensure yaml in global/ +
# mark law_eligible:false + fail-safe when no yaml backing) and the
# auto_promote_to_law guard that never re-promotes a law_eligible:false instinct.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

SANDBOX="$(mktemp -d -t cortex-tier-test-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
echo "=== Law Tier (Core/Domain) Tests (sandbox: $SANDBOX) ==="
echo

# ── Helpers ──────────────────────────────────────────────────────────────────
make_law() {
  local dir="$1" iid="$2" content="$3"
  mkdir -p "$dir"
  printf '%s\n' "$content" > "$dir/${iid}.txt"
}

make_instinct() {
  # make_instinct <dir> <id> <confidence> <trigger>
  local dir="$1" iid="$2" conf="$3" trig="$4"
  mkdir -p "$dir"
  cat > "$dir/${iid}.yaml" <<YAML
---
id: ${iid}
confidence: ${conf}
domain: testing
trigger: "${trig}"
action: "Always do the contextual thing for ${iid}"
last_seen: 2026-05-31
first_seen: 2026-04-01
occurrences: 40
scope: global
---
YAML
}

run() { CORTEX_DIR="$SANDBOX" python3 -c "$1"; }

# ── Test 1: demote a law that has a live yaml in instincts/global/ ────────────
echo "Test 1: demote_law_to_domain with live global yaml"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
make_law "$SANDBOX/laws" "gotcha-x" "When ^Agent, do the agent thing"
make_instinct "$SANDBOX/instincts/global" "gotcha-x" "0.99" "^Agent"
OUT=$(run "
import distill_engine as de
ok,reason = de.demote_law_to_domain('gotcha-x')
print('OK' if ok else 'NO', reason)
")
if echo "$OUT" | grep -q '^OK'; then pass "demote returned success: $OUT"; else fail "demote failed: $OUT"; fi
[ ! -f "$SANDBOX/laws/gotcha-x.txt" ] && pass "law .txt removed from laws/" || fail "law .txt still present"
ls "$SANDBOX/laws/archive/"gotcha-x.*.txt >/dev/null 2>&1 && pass "law .txt archived" || fail "law .txt not archived"
[ -f "$SANDBOX/instincts/global/gotcha-x.yaml" ] && pass "instinct yaml still in global/" || fail "instinct yaml lost"
grep -qE '^law_eligible:[[:space:]]*false' "$SANDBOX/instincts/global/gotcha-x.yaml" && pass "yaml marked law_eligible:false" || fail "law_eligible flag missing"

# ── Test 2: fail-safe — law without any yaml backing must NOT be touched ──────
echo "Test 2: demote fails safe when no yaml backing exists"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
make_law "$SANDBOX/laws" "orphan-law" "Some universal-looking law with no instinct"
OUT=$(run "
import distill_engine as de
ok,reason = de.demote_law_to_domain('orphan-law')
print('OK' if ok else 'NO', reason)
")
echo "$OUT" | grep -q '^NO' && pass "demote refused (no yaml): $OUT" || fail "demote should have refused: $OUT"
[ -f "$SANDBOX/laws/orphan-law.txt" ] && pass "law .txt left intact on refusal" || fail "law .txt was removed despite refusal"

# ── Test 3: yaml only in archive/ is restored to global/ then demoted ─────────
echo "Test 3: demote restores archived yaml to global/"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
make_law "$SANDBOX/laws" "gotcha-z" "When Read, do z"
make_instinct "$SANDBOX/instincts/archive" "gotcha-z" "0.99" "Read"
OUT=$(run "
import distill_engine as de
ok,reason = de.demote_law_to_domain('gotcha-z')
print('OK' if ok else 'NO', reason)
")
echo "$OUT" | grep -q '^OK' && pass "demote restored+demoted: $OUT" || fail "demote failed: $OUT"
[ -f "$SANDBOX/instincts/global/gotcha-z.yaml" ] && pass "yaml restored to global/" || fail "yaml not restored to global/"

# ── Test 4: demote of a non-existent law returns False ───────────────────────
echo "Test 4: demote of missing law"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX/laws"
OUT=$(run "
import distill_engine as de
ok,reason = de.demote_law_to_domain('does-not-exist')
print('OK' if ok else 'NO', reason)
")
echo "$OUT" | grep -q '^NO' && pass "missing law refused: $OUT" || fail "should refuse missing law: $OUT"

# ── Test 5: dry_run mutates nothing ──────────────────────────────────────────
echo "Test 5: dry_run is side-effect free"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
make_law "$SANDBOX/laws" "gotcha-d" "When Edit, do d"
make_instinct "$SANDBOX/instincts/global" "gotcha-d" "0.99" "Edit"
run "
import distill_engine as de
ok,reason = de.demote_law_to_domain('gotcha-d', dry_run=True)
assert ok, reason
" >/dev/null
[ -f "$SANDBOX/laws/gotcha-d.txt" ] && pass "dry_run left law in place" || fail "dry_run removed the law"
grep -qE '^law_eligible:' "$SANDBOX/instincts/global/gotcha-d.yaml" && fail "dry_run wrote law_eligible" || pass "dry_run did not mark yaml"

# ── Test 6: auto_promote_to_law NEVER re-promotes a law_eligible:false instinct ─
echo "Test 6: promotion guard respects law_eligible:false"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
make_instinct "$SANDBOX/instincts/global" "demoted-one" "0.99" "Bash"
# mark it as demoted
python3 -c "
import io
p='$SANDBOX/instincts/global/demoted-one.yaml'
t=open(p).read().replace('scope: global','scope: global\nlaw_eligible: false')
open(p,'w').write(t)
"
OUT=$(run "
import distill_engine as de
promoted,_ = de.auto_promote_to_law(dry_run=True)
ids=[p.get('id') for p in promoted]
print('PROMOTED' if 'demoted-one' in ids else 'SKIPPED')
")
echo "$OUT" | grep -q 'SKIPPED' && pass "law_eligible:false instinct not promoted" || fail "guard failed, instinct promoted: $OUT"

# ── Test 7: E2E — a demoted law STILL injects via the real injector engine ────
# This is the integration gate (instinct gotcha-ad-por-fase-no-sustituye-e2e):
# unit tests prove demote moves files; only the real injector proves the
# demoted instinct keeps reaching the session when its trigger matches.
echo "Test 7: e2e — demoted law injects via real injector-engine.js when trigger matches"
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not available"
else
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX/instincts/global" "$SANDBOX/laws"
  printf '%s\n' '{"config":{"max_instincts_per_injection":3}}' > "$SANDBOX/memory.json"
  printf '%s\n' '{"reflexes":[]}' > "$SANDBOX/reflexes.json"
  make_law "$SANDBOX/laws" "gotcha-agentdemo" "When ^Agent, contextual agent reminder"
  make_instinct "$SANDBOX/instincts/global" "gotcha-agentdemo" "0.99" "^Agent"
  # Demote it through the real engine (ley → instinct law_eligible:false).
  run "import distill_engine as de; ok,r=de.demote_law_to_domain('gotcha-agentdemo'); assert ok, r" >/dev/null
  INPUT="$SANDBOX/hook-input.json"
  printf '%s\n' "{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"do x\"},\"cwd\":\"$SANDBOX\"}" > "$INPUT"
  ENGINE_OUT=$(_CX_CORTEX_DIR="$SANDBOX" \
    _CX_GLOBAL_INSTINCTS_DIR="$SANDBOX/instincts/global" \
    _CX_REFLEXES_FILE="$SANDBOX/reflexes.json" \
    _CX_INPUT_FILE="$INPUT" \
    node "$PROJECT_ROOT/hooks/lib/injector-engine.js" 2>/dev/null || true)
  if echo "$ENGINE_OUT" | grep -q "gotcha-agentdemo"; then
    pass "demoted law re-injected by real engine via its trigger"
  else
    fail "demoted instinct NOT injected by engine: $ENGINE_OUT"
  fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
