#!/usr/bin/env bash
# test_migrate_legacy_iid.sh — v3.19.5 migration script tests
# Validates: dry-run, apply, idempotency, backup, reflex-id whitelist, missing-file safety.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATE_PY="$REPO_ROOT/scripts/migrate-legacy-reflex-iid.py"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SANDBOX="$(mktemp -d -t cortex-migrate-test-XXXXXX)"
export CORTEX_DIR="$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== Migration Tests (sandbox: $SANDBOX) ==="
echo

# Seed a minimal reflexes.json with two known ids — only events whose
# iid maps onto one of these should be rewritten.
cat > "$SANDBOX/reflexes.json" <<'JSON'
{
  "version": "2.0.0",
  "reflexes": [
    { "id": "bash-cat-use-read", "matcher": "Bash", "action": "x", "severity": "medium", "enabled": true, "fireCount": 0 },
    { "id": "read-before-edit",  "matcher": "Edit", "action": "x", "severity": "high",   "enabled": true, "fireCount": 0 }
  ]
}
JSON

# Seed impact.jsonl with mixed cases:
#   - 2 legacy reflex- events that match known reflexes  → should rewrite
#   - 1 legacy reflex- event with UNKNOWN id              → must pass through
#   - 1 already-canonical reflex: event                   → must pass through
#   - 1 plain instinct event                              → must pass through
cat > "$SANDBOX/impact.jsonl" <<'JSONL'
{"v":1,"ts":"2026-04-25T14:35:56Z","ev":"feedback","iid":"reflex-bash-cat-use-read","rating":"useful"}
{"v":1,"ts":"2026-04-25T15:06:25Z","ev":"feedback","iid":"reflex-read-before-edit","rating":"noise","note":"agent self-rated"}
{"v":1,"ts":"2026-04-25T15:07:00Z","ev":"feedback","iid":"reflex-some-unknown-thing","rating":"useful"}
{"v":1,"ts":"2026-04-25T16:00:00Z","ev":"feedback","iid":"reflex:bash-cat-use-read","rating":"useful"}
{"v":1,"ts":"2026-04-25T16:01:00Z","ev":"feedback","iid":"gotcha-some-instinct","rating":"useful"}
JSONL

ORIG_HASH=$(shasum -a 256 "$SANDBOX/impact.jsonl" | awk '{print $1}')

# -----------------------------------------------------------------------------
echo "--- Test 1: dry-run does not modify the file ---"
python3 "$MIGRATE_PY" --quiet >/dev/null
NEW_HASH=$(shasum -a 256 "$SANDBOX/impact.jsonl" | awk '{print $1}')
if [ "$ORIG_HASH" = "$NEW_HASH" ]; then
  pass "dry-run leaves impact.jsonl untouched"
else
  fail "dry-run mutated the file"
fi
if [ ! -f "$SANDBOX/impact.jsonl${BACKUP_SUFFIX:-.pre-v3.19.5.bak}" ]; then
  pass "dry-run does not create a backup"
else
  fail "dry-run created a backup unexpectedly"
fi

# -----------------------------------------------------------------------------
echo "--- Test 2: --apply rewrites only known reflex ids ---"
OUT=$(python3 "$MIGRATE_PY" --apply 2>&1)
COUNT_REFLEX_DASH=$(grep -c '"iid":"reflex-' "$SANDBOX/impact.jsonl" || true)
COUNT_REFLEX_COLON_CAT=$(grep -c '"iid":"reflex:bash-cat-use-read"' "$SANDBOX/impact.jsonl" || true)
COUNT_REFLEX_COLON_RBE=$(grep -c '"iid":"reflex:read-before-edit"' "$SANDBOX/impact.jsonl" || true)
COUNT_PASSTHRU_UNKNOWN=$(grep -c '"iid":"reflex-some-unknown-thing"' "$SANDBOX/impact.jsonl" || true)
COUNT_PASSTHRU_INSTINCT=$(grep -c '"iid":"gotcha-some-instinct"' "$SANDBOX/impact.jsonl" || true)

# Expected after rewrite:
#   reflex- (any) lines = 1  (the "unknown" one only — others rewritten)
#   reflex:bash-cat-use-read lines = 2  (one originally canonical + one rewritten)
#   reflex:read-before-edit lines = 1  (rewritten)
#   reflex-some-unknown-thing = 1 (passthrough)
#   gotcha-some-instinct = 1 (passthrough)
if [ "$COUNT_REFLEX_DASH" -eq 1 ] && [ "$COUNT_REFLEX_COLON_CAT" -eq 2 ] \
   && [ "$COUNT_REFLEX_COLON_RBE" -eq 1 ] && [ "$COUNT_PASSTHRU_UNKNOWN" -eq 1 ] \
   && [ "$COUNT_PASSTHRU_INSTINCT" -eq 1 ]; then
  pass "rewrote 2 known reflex ids; passed through unknown and canonical"
else
  fail "counts wrong: reflex-=$COUNT_REFLEX_DASH cat=$COUNT_REFLEX_COLON_CAT rbe=$COUNT_REFLEX_COLON_RBE unknown=$COUNT_PASSTHRU_UNKNOWN instinct=$COUNT_PASSTHRU_INSTINCT"
  echo "OUT was: $OUT"
fi

# -----------------------------------------------------------------------------
echo "--- Test 3: backup is created with the .pre-v3.19.5.bak suffix ---"
if [ -f "$SANDBOX/impact.jsonl.pre-v3.19.5.bak" ]; then
  BACKUP_HASH=$(shasum -a 256 "$SANDBOX/impact.jsonl.pre-v3.19.5.bak" | awk '{print $1}')
  if [ "$BACKUP_HASH" = "$ORIG_HASH" ]; then
    pass "backup matches original pre-migration hash"
  else
    fail "backup contents differ from original"
  fi
else
  fail "backup file missing"
fi

# -----------------------------------------------------------------------------
echo "--- Test 4: original event payload preserved (only iid changed) ---"
# Pick the first rewritten event and verify the rest of its fields unchanged.
LINE=$(grep '"iid":"reflex:bash-cat-use-read"' "$SANDBOX/impact.jsonl" | head -1)
if echo "$LINE" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['v'] == 1
assert d['ev'] == 'feedback'
assert d['rating'] == 'useful'
assert d['ts'] == '2026-04-25T14:35:56Z'
" 2>/dev/null; then
  pass "non-iid fields preserved verbatim"
else
  fail "rewrite mutated unrelated fields: $LINE"
fi

# -----------------------------------------------------------------------------
echo "--- Test 5: idempotent — second --apply is a no-op ---"
HASH_AFTER_FIRST=$(shasum -a 256 "$SANDBOX/impact.jsonl" | awk '{print $1}')
OUT2=$(python3 "$MIGRATE_PY" --apply 2>&1)
HASH_AFTER_SECOND=$(shasum -a 256 "$SANDBOX/impact.jsonl" | awk '{print $1}')
if [ "$HASH_AFTER_FIRST" = "$HASH_AFTER_SECOND" ]; then
  pass "second apply does not mutate the file"
else
  fail "second apply rewrote the file"
fi
if echo "$OUT2" | grep -q "already canonical"; then
  pass "reports already-canonical state"
else
  fail "second apply did not report idempotency: $OUT2"
fi

# -----------------------------------------------------------------------------
echo "--- Test 6: backup is preserved on subsequent runs (not overwritten) ---"
BACKUP_HASH_BEFORE=$(shasum -a 256 "$SANDBOX/impact.jsonl.pre-v3.19.5.bak" | awk '{print $1}')
python3 "$MIGRATE_PY" --apply --quiet
BACKUP_HASH_AFTER=$(shasum -a 256 "$SANDBOX/impact.jsonl.pre-v3.19.5.bak" | awk '{print $1}')
if [ "$BACKUP_HASH_BEFORE" = "$BACKUP_HASH_AFTER" ]; then
  pass "backup not overwritten on idempotent re-run"
else
  fail "backup was overwritten"
fi

# -----------------------------------------------------------------------------
echo "--- Test 7: missing impact.jsonl exits cleanly ---"
SANDBOX2="$(mktemp -d -t cortex-migrate-empty-XXXXXX)"
CORTEX_DIR="$SANDBOX2" python3 "$MIGRATE_PY" --apply --quiet
RC=$?
if [ "$RC" -eq 0 ]; then
  pass "exit 0 when impact.jsonl missing"
else
  fail "exit $RC when impact.jsonl missing"
fi
rm -rf "$SANDBOX2"

# -----------------------------------------------------------------------------
echo "--- Test 8: missing reflexes.json → no rewrites (safety) ---"
SANDBOX3="$(mktemp -d -t cortex-migrate-noreflex-XXXXXX)"
cat > "$SANDBOX3/impact.jsonl" <<'JSONL'
{"v":1,"ts":"2026-04-25T14:35:56Z","ev":"feedback","iid":"reflex-bash-cat-use-read","rating":"useful"}
JSONL
ORIG_HASH3=$(shasum -a 256 "$SANDBOX3/impact.jsonl" | awk '{print $1}')
CORTEX_DIR="$SANDBOX3" python3 "$MIGRATE_PY" --apply 2>&1 | grep -q "nothing to migrate" && \
  pass "skipped rewrites when reflexes.json absent" || \
  fail "rewrote without reflex whitelist"
NEW_HASH3=$(shasum -a 256 "$SANDBOX3/impact.jsonl" | awk '{print $1}')
[ "$ORIG_HASH3" = "$NEW_HASH3" ] && pass "file untouched without whitelist" || fail "file mutated without whitelist"
rm -rf "$SANDBOX3"

# -----------------------------------------------------------------------------
echo "--- Test 9: --stats prints summary fields ---"
STATS_OUT=$(python3 "$MIGRATE_PY" --stats 2>&1)
if echo "$STATS_OUT" | grep -q "scanned:" && echo "$STATS_OUT" | grep -q "rewrote:" && echo "$STATS_OUT" | grep -q "applied:"; then
  pass "--stats prints scanned/rewrote/applied"
else
  fail "--stats output missing fields: $STATS_OUT"
fi

# -----------------------------------------------------------------------------
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
