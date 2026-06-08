#!/usr/bin/env bash
# test_precompact.sh — v3.29.0 (Sprint 8 §4.15)
#
# Tests the PreCompact hook hardening: kill-switch honor, env-var
# propagation, fire-and-forget contract, idempotency.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

PRECOMPACT_PY="$PROJECT_ROOT/hooks/precompact.py"

# Build a sandbox HOME that mirrors the install layout precompact.py expects:
#   $HOME/.claude/hooks/cortex/session-learner.js   ← we install a fake here
#   $HOME/.claude/cortex/                           ← CORTEX_DIR points here
# Each test gets its own sandbox to keep state isolated.
make_sandbox() {
  local s; s="$(mktemp -d -t cortex-precompact-XXXXXX)"
  mkdir -p "$s/.claude/hooks/cortex" "$s/.claude/cortex"
  echo "$s"
}

# Fake session-learner.js that simply logs invocation details to a file
# under $CORTEX_DIR/.precompact-spy. Used by tests 1-6 to assert what
# precompact passed to it (env, stdin, etc.) without booting Node's real
# session-learner runtime.
install_spy_learner() {
  local sandbox="$1"
  local spy_mode="${2:-record}"   # record | hang | crash
  local spy_file="$sandbox/.claude/cortex/.precompact-spy"
  rm -f "$spy_file"
  case "$spy_mode" in
    record)
      cat > "$sandbox/.claude/hooks/cortex/session-learner.js" <<JSEOF
#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const out = '$spy_file';
let stdin = '';
process.stdin.on('data', d => { stdin += d; });
process.stdin.on('end', () => {
  fs.writeFileSync(out, JSON.stringify({
    env_session_id: process.env.CORTEX_SESSION_ID || '',
    stdin_received: stdin,
    argv: process.argv.slice(2),
  }, null, 2));
});
JSEOF
      ;;
    hang)
      # Deliberately slow learner (sleeps 30s). Used to assert the hook
      # returns BEFORE the child finishes — fire-and-forget.
      cat > "$sandbox/.claude/hooks/cortex/session-learner.js" <<JSEOF
#!/usr/bin/env node
const fs = require('fs');
fs.writeFileSync('$spy_file', 'started');
setTimeout(() => { fs.appendFileSync('$spy_file', '\nfinished'); }, 30000);
JSEOF
      ;;
    crash)
      cat > "$sandbox/.claude/hooks/cortex/session-learner.js" <<JSEOF
#!/usr/bin/env node
throw new Error('intentional crash for precompact test');
JSEOF
      ;;
  esac
  chmod +x "$sandbox/.claude/hooks/cortex/session-learner.js"
}

# Drive precompact.py with HOME pointing at the sandbox and a stdin payload.
# Returns ONLY precompact's exit code; spy output is read separately.
run_precompact() {
  local sandbox="$1" payload="$2"
  shift 2
  HOME="$sandbox" CORTEX_DIR="$sandbox/.claude/cortex" "$@" \
    python3 "$PRECOMPACT_PY" <<<"$payload"
}

echo "=== PreCompact Hook Tests (v3.29.0 §4.15) ==="

# ── Test 1: smoke — hook fires + writes marker ───────────────────────────────
echo "--- Test 1: smoke ---"
S1="$(make_sandbox)"
install_spy_learner "$S1" record
payload='{"session_id":"compact-sess-uuid-12345678","hook_event_name":"PreCompact"}'
run_precompact "$S1" "$payload" >/dev/null 2>&1
rc=$?
# fire_once writes markers under $CORTEX_DIR/.fire-once/precompact-flush-<sid>.
# The session-id is _safe_slug'd and truncated to 24 chars at both
# precompact._parse_session_id and fire_once._safe_slug levels.
marker_count=$(find "$S1/.claude/cortex/.fire-once" -name 'precompact-flush-*' 2>/dev/null | wc -l | tr -d ' ')
[ "$rc" = "0" ] && pass "smoke: exit code 0" || fail "smoke: exit $rc"
[ "$marker_count" -ge "1" ] && pass "smoke: marker file written under .fire-once/" || fail "smoke: no marker found"
rm -rf "$S1"

# ── Test 2: env propagation — CORTEX_SESSION_ID set in spawned learner ───────
echo "--- Test 2: env propagation ---"
S2="$(make_sandbox)"
install_spy_learner "$S2" record
payload='{"session_id":"sess-env-id-abcdef","hook_event_name":"PreCompact"}'
run_precompact "$S2" "$payload" >/dev/null 2>&1
# Spy is asynchronous: wait briefly for the child to finish.
for _ in $(seq 1 20); do
  [ -f "$S2/.claude/cortex/.precompact-spy" ] && break
  sleep 0.1
done
if [ -f "$S2/.claude/cortex/.precompact-spy" ]; then
  if grep -q '"env_session_id": "sess-env-id-abcdef"' "$S2/.claude/cortex/.precompact-spy"; then
    pass "env: CORTEX_SESSION_ID propagated to learner"
  else
    fail "env: spy did not see CORTEX_SESSION_ID"
  fi
else
  fail "env: spy file never written"
fi
rm -rf "$S2"

# ── Test 3: stdin propagation — payload reaches learner stdin ────────────────
echo "--- Test 3: stdin propagation ---"
S3="$(make_sandbox)"
install_spy_learner "$S3" record
payload='{"session_id":"sess-stdin-test","hook_event_name":"PreCompact","custom_field":"propagated"}'
run_precompact "$S3" "$payload" >/dev/null 2>&1
for _ in $(seq 1 20); do
  [ -f "$S3/.claude/cortex/.precompact-spy" ] && break
  sleep 0.1
done
# The spy stores stdin verbatim inside JSON.stringify, so the on-disk
# representation has the inner JSON's quotes escaped (e.g.
# `"\"custom_field\":\"propagated\""`). Parse the spy file with Python
# instead of trying to match the escape pattern in a shell grep.
got=$(python3 - <<PYEOF
import json
try:
    with open('$S3/.claude/cortex/.precompact-spy') as f:
        outer = json.load(f)
    inner = json.loads(outer.get('stdin_received', '') or '{}')
    print('FOUND' if inner.get('custom_field') == 'propagated' else 'MISSING')
except Exception as e:
    print(f'ERR:{e}')
PYEOF
)
[ "$got" = "FOUND" ] && pass "stdin: payload propagated to learner" \
                    || fail "stdin: payload not in spy ($got)"
rm -rf "$S3"

# ── Test 4: fire-and-forget — hung learner does not block precompact ─────────
echo "--- Test 4: fire-and-forget (hung child) ---"
S4="$(make_sandbox)"
install_spy_learner "$S4" hang
payload='{"session_id":"sess-hang","hook_event_name":"PreCompact"}'
start_ts=$(date +%s)
run_precompact "$S4" "$payload" >/dev/null 2>&1
rc=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
# Hook should return in under 3s even though the spy sleeps 30s.
[ "$rc" = "0" ] && [ "$elapsed" -lt "5" ] \
  && pass "fire-and-forget: returned in ${elapsed}s with hung learner" \
  || fail "fire-and-forget: rc=$rc elapsed=${elapsed}s"
# Kill the hung child so it doesn't outlive the test.
pkill -f "session-learner.js" 2>/dev/null || true
rm -rf "$S4"

# ── Test 5: crash safety — learner throws, hook still exits 0 ────────────────
echo "--- Test 5: crash safety ---"
S5="$(make_sandbox)"
install_spy_learner "$S5" crash
payload='{"session_id":"sess-crash","hook_event_name":"PreCompact"}'
run_precompact "$S5" "$payload" >/dev/null 2>&1
rc=$?
[ "$rc" = "0" ] && pass "crash: exit 0 even though learner throws" \
                || fail "crash: exit code $rc"
rm -rf "$S5"

# ── Test 6: idempotent — second invocation same sid is no-op ─────────────────
echo "--- Test 6: idempotent double-flush ---"
S6="$(make_sandbox)"
install_spy_learner "$S6" record
payload='{"session_id":"sess-idem-12345","hook_event_name":"PreCompact"}'
run_precompact "$S6" "$payload" >/dev/null 2>&1
# Wait for first run's spy.
for _ in $(seq 1 20); do
  [ -f "$S6/.claude/cortex/.precompact-spy" ] && break
  sleep 0.1
done
# GNU coreutils first: BSD `stat -f %m` is parsed as --file-system on GNU and
# returns garbage with exit 0, so a BSD-first order skipped the GNU fallback —
# both mtimes came back identical ('?') and this idempotency check passed
# vacuously on Linux. `stat -c` is rejected by BSD (exit 1) → falls back to -f.
first_mtime=$(stat -c %Y "$S6/.claude/cortex/.precompact-spy" 2>/dev/null || stat -f %m "$S6/.claude/cortex/.precompact-spy" 2>/dev/null)
sleep 1
run_precompact "$S6" "$payload" >/dev/null 2>&1
sleep 0.5
second_mtime=$(stat -c %Y "$S6/.claude/cortex/.precompact-spy" 2>/dev/null || stat -f %m "$S6/.claude/cortex/.precompact-spy" 2>/dev/null)
[ "$first_mtime" = "$second_mtime" ] \
  && pass "idempotent: second invocation did not re-spawn learner" \
  || fail "idempotent: spy file mtime changed ($first_mtime → $second_mtime)"
rm -rf "$S6"

# ── Test 7: CORTEX_OBSERVE_OFF=1 → no learner spawn ──────────────────────────
echo "--- Test 7: CORTEX_OBSERVE_OFF kill switch ---"
S7="$(make_sandbox)"
install_spy_learner "$S7" record
payload='{"session_id":"sess-observe-off","hook_event_name":"PreCompact"}'
HOME="$S7" CORTEX_DIR="$S7/.claude/cortex" CORTEX_OBSERVE_OFF=1 \
  python3 "$PRECOMPACT_PY" <<<"$payload" >/dev/null 2>&1
rc=$?
sleep 0.5
[ "$rc" = "0" ] && pass "OBSERVE_OFF: exit 0" || fail "OBSERVE_OFF: rc=$rc"
[ ! -f "$S7/.claude/cortex/.precompact-spy" ] \
  && pass "OBSERVE_OFF: learner was NOT spawned" \
  || fail "OBSERVE_OFF: spy file exists (learner ran)"
rm -rf "$S7"

# ── Test 8: CORTEX_DETECTORS_OFF=1 → no learner spawn ────────────────────────
echo "--- Test 8: CORTEX_DETECTORS_OFF kill switch ---"
S8="$(make_sandbox)"
install_spy_learner "$S8" record
payload='{"session_id":"sess-det-off","hook_event_name":"PreCompact"}'
HOME="$S8" CORTEX_DIR="$S8/.claude/cortex" CORTEX_DETECTORS_OFF=1 \
  python3 "$PRECOMPACT_PY" <<<"$payload" >/dev/null 2>&1
rc=$?
sleep 0.5
[ "$rc" = "0" ] && pass "DETECTORS_OFF: exit 0" || fail "DETECTORS_OFF: rc=$rc"
[ ! -f "$S8/.claude/cortex/.precompact-spy" ] \
  && pass "DETECTORS_OFF: learner was NOT spawned" \
  || fail "DETECTORS_OFF: spy file exists (learner ran)"
rm -rf "$S8"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
