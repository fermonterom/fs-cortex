#!/usr/bin/env bash
# test_backfill_concurrency.sh — issue #49 acceptance criterion 5:
# "concurrent Stop-hook append during --apply → no data loss (not just abort
#  — actual serialization)".
#
# Strategy: seed proposals-history.jsonl with N "seed-*" lines carrying legacy
# `session` (no session_id) so backfill must rewrite. In parallel a Node
# process appends M "node-*" lines via the real _appendHistory path (which
# now takes HISTORY_LOCK_PATH). The race is genuine — we deliberately do not
# stagger the launches. We then assert that the final file contains ALL
# N seed ids AND ALL M node ids, and is exactly N+M lines, with no .tmp.*
# leak and no leftover lockfile. Repeated 5 times to catch flakiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

if ! command -v node >/dev/null 2>&1; then
  echo "=== Backfill concurrency tests SKIPPED (node not on PATH) ==="
  exit 0
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Backfill concurrency tests (issue #49 §5) ==="

SEED_N=50
NODE_N=50

ROUNDS=5
for round in $(seq 1 "$ROUNDS"); do
  T="$(mktemp -d -t backfill-concur-XXXXXX)"
  umask 077
  # shellcheck disable=SC2064  # we want $T expanded now, not at trap time
  trap "rm -rf '$T'" EXIT
  mkdir -p "$T/instincts/global" "$T/archive"

  # Minimal instinct so the engine import + path discovery succeed; the
  # eligible-promotion math is not the focus here.
  cat > "$T/instincts/global/inst-x.yaml" <<'YAML'
---
id: inst-x
trigger: 'Bash'
action: 'noop'
confidence: 0.5
domain: gotcha
---
YAML

  # Seed history: SEED_N lines with legacy `session` (no session_id) →
  # forces backfill to rewrite the whole file.
  : > "$T/proposals-history.jsonl"
  for i in $(seq 0 $((SEED_N - 1))); do
    printf '{"id":"inst-x","source":"session-learner:correction","status":"accepted","session":"seed-%d"}\n' "$i" \
      >> "$T/proposals-history.jsonl"
  done

  # Empty tracking — backfill leaves it alone unless rebuilt, fine.
  echo '{}' > "$T/instinct-tracking.json"

  # --- Launch backfill --apply ---
  (
    CORTEX_DIR="$T" python3 - <<'PYEOF' > "$T/py.out" 2>&1
import distill_engine as de
try:
    r = de.backfill_session_data(dry_run=False)
    print(f"PY_OK wrote_history={r['wrote_history']} normalized={r['normalized']}")
except RuntimeError as e:
    # Stat-mismatch abort is an ACCEPTABLE outcome: it means the Node side
    # raced ahead, which is safe (no data loss; just a re-run-needed signal).
    print(f"PY_ABORT {e}")
PYEOF
  ) &
  PY_PID=$!

  # --- Launch Node appender (real proposals-storage._appendHistory) ---
  (
    CORTEX_DIR="$T" PROJECT="$PROJECT_ROOT" NODE_N="$NODE_N" node -e '
      const ps = require(process.env.PROJECT + "/hooks/lib/proposals-storage");
      const n = parseInt(process.env.NODE_N, 10);
      // Append one at a time so we exercise the lock acquire/release per write,
      // not a single batched append.
      for (let i = 0; i < n; i++) {
        ps.splitForPersist([{
          id: "inst-x",
          source: "session-learner:correction",
          status: "accepted",
          session_id: "node-" + i,
        }]);
      }
      console.log("NODE_OK");
    ' > "$T/node.out" 2>&1
  ) &
  NODE_PID=$!

  wait "$PY_PID" "$NODE_PID" || true

  # --- Asserts ---
  total=$(wc -l < "$T/proposals-history.jsonl" | tr -d ' ')
  expected=$((SEED_N + NODE_N))
  if [ "$total" -eq "$expected" ]; then
    pass "round $round: line count == $expected (got $total)"
  else
    fail "round $round: line count == $expected (got $total). py.out=$(cat "$T/py.out") node.out=$(cat "$T/node.out")"
  fi

  missing_seed=0
  for i in $(seq 0 $((SEED_N - 1))); do
    # After backfill apply, seed-* lines carry session_id="seed-N" (normalized).
    # After abort, they keep session="seed-N". Match either form.
    if ! grep -q "\"seed-${i}\"" "$T/proposals-history.jsonl"; then
      missing_seed=$((missing_seed + 1))
    fi
  done
  [ "$missing_seed" -eq 0 ] && pass "round $round: all $SEED_N seed ids present" \
    || fail "round $round: $missing_seed seed ids missing"

  missing_node=0
  for i in $(seq 0 $((NODE_N - 1))); do
    if ! grep -q "\"node-${i}\"" "$T/proposals-history.jsonl"; then
      missing_node=$((missing_node + 1))
    fi
  done
  [ "$missing_node" -eq 0 ] && pass "round $round: all $NODE_N node ids present" \
    || fail "round $round: $missing_node node ids missing"

  # No leaked tmp files.
  leak=$(find "$T" -maxdepth 2 -name '*.tmp.*' | wc -l | tr -d ' ')
  [ "$leak" -eq 0 ] && pass "round $round: no .tmp.* leak" \
    || fail "round $round: $leak .tmp.* file(s) leaked"

  # Lockfile cleaned up.
  if [ -e "$T/.proposals-history.lock" ]; then
    fail "round $round: lockfile leaked"
  else
    pass "round $round: lockfile cleaned up"
  fi

  rm -rf "$T"
  trap - EXIT
done

# --- Test §B: AD round 2 P2 — DETERMINISTIC contention proof ---
# The race rounds above accept either outcome (success or stat-mismatch abort)
# as long as no line is lost. The issue acceptance criterion #5 (+ AD round 2)
# requires we PROVE actual serialization, not heuristic timing.
#
# Strategy: a Python "holder" script directly acquires HISTORY_LOCK_FILE via
# the public file_lock API and holds it for 2000 ms. While the holder sleeps,
# we start backfill --apply (which must wait for the lock) and then a Node
# appender. The backfill subprocess PRE-IMPORTS distill_engine before t0 so
# the heavy module import (a ~2800-line file) is excluded from the measured
# window — what remains is dominated by the lock wait. We assert
# wait_ms >= 600 — proof they were actually blocked on the lock, not running
# unimpeded. The 2000 ms hold gives a wide margin against CI scheduling jitter.
T="$(mktemp -d -t backfill-serial-XXXXXX)"
trap "rm -rf '$T'" EXIT
mkdir -p "$T/instincts/global" "$T/archive"
cat > "$T/instincts/global/inst-x.yaml" <<'YAML'
---
id: inst-x
trigger: 'Bash'
action: 'noop'
confidence: 0.5
domain: gotcha
---
YAML
: > "$T/proposals-history.jsonl"
for i in $(seq 0 $((SEED_N - 1))); do
  printf '{"id":"inst-x","source":"session-learner:correction","status":"accepted","session":"seed-%d"}\n' "$i" \
    >> "$T/proposals-history.jsonl"
done
echo '{}' > "$T/instinct-tracking.json"

# Phase 1: Holder takes the lock and sleeps 800 ms. Backfill races against
# the holder ONLY — this guarantees backfill wins the race when holder
# releases (no third party in the race), so we get deterministic PY_OK.
(
  CORTEX_DIR="$T" python3 - <<'PYEOF' > "$T/holder.out" 2>&1
import os, time, file_lock
lock = os.path.join(os.environ["CORTEX_DIR"], ".proposals-history.lock")
tok = file_lock.acquire(lock, timeout_ms=2000, stale_ms=30000)
assert tok, "holder failed to acquire"
print("HOLDER_ACQUIRED", flush=True)
time.sleep(2.0)
file_lock.release(tok)
print("HOLDER_RELEASED", flush=True)
PYEOF
) &
HOLDER_PID=$!

# Wait for HOLDER_ACQUIRED (poll up to ~500ms).
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "HOLDER_ACQUIRED" "$T/holder.out" 2>/dev/null; then break; fi
  python3 -c "import time; time.sleep(0.05)"
done

# Backfill arranca con 50ms de delay tras HOLDER_ACQUIRED. Debe esperar
# al holder. Cuando el holder libera, backfill (único en la cola) gana.
python3 -c "import time; time.sleep(0.05)"
CORTEX_DIR="$T" python3 - <<'PYEOF' > "$T/py.out" 2>&1
import time
import distill_engine as de   # pre-import BEFORE t0 so the heavy module load
                              # is excluded from the measured lock-wait window.
t0 = time.monotonic()
try:
    r = de.backfill_session_data(dry_run=False)
    dt_ms = (time.monotonic() - t0) * 1000
    print(f"PY_OK wait_ms={dt_ms:.0f} wrote_history={r['wrote_history']}")
except RuntimeError as e:
    dt_ms = (time.monotonic() - t0) * 1000
    print(f"PY_ABORT wait_ms={dt_ms:.0f} {e}")
PYEOF

wait "$HOLDER_PID" || true

grep -q "HOLDER_RELEASED" "$T/holder.out" && pass "§B: holder acquired and released cleanly" \
  || fail "§B: holder did not complete: $(cat "$T/holder.out")"

if grep -q "^PY_OK " "$T/py.out"; then
  py_wait=$(grep "^PY_OK " "$T/py.out" | sed -E 's/.*wait_ms=([0-9]+).*/\1/')
  if [ "$py_wait" -ge 600 ]; then
    pass "§B: backfill serialized after holder (wait_ms=$py_wait >= 600)"
  else
    fail "§B: backfill did not wait for holder (wait_ms=$py_wait < 600). py.out=$(cat "$T/py.out")"
  fi
else
  fail "§B: backfill did not return PY_OK: $(cat "$T/py.out")"
fi

# Phase 2: backfill already completed. Now run Node appender — it must
# also acquire the lock (no contention now) and append cleanly. This
# proves the lock cycles correctly between runtimes.
CORTEX_DIR="$T" PROJECT="$PROJECT_ROOT" NODE_N="$NODE_N" node -e '
  const ps = require(process.env.PROJECT + "/hooks/lib/proposals-storage");
  const n = parseInt(process.env.NODE_N, 10);
  const t0 = Date.now();
  for (let i = 0; i < n; i++) {
    ps.splitForPersist([{
      id: "inst-x",
      source: "session-learner:correction",
      status: "accepted",
      session_id: "node-" + i,
    }]);
  }
  console.log("NODE_OK wait_ms=" + (Date.now() - t0));
' > "$T/node.out" 2>&1

if grep -q "^NODE_OK " "$T/node.out"; then
  pass "§B: Node appender completed cleanly after backfill (no leftover lock)"
else
  fail "§B: Node did not return NODE_OK: $(cat "$T/node.out")"
fi

# Final state: backfill normalized 50 seed lines + Node appended 50 new = 100.
total=$(wc -l < "$T/proposals-history.jsonl" | tr -d ' ')
expected=$((SEED_N + NODE_N))
[ "$total" -eq "$expected" ] && pass "§B: total lines == $expected" \
  || fail "§B: total lines $total != $expected"
missing=0
for i in $(seq 0 $((NODE_N - 1))); do
  grep -q "\"node-${i}\"" "$T/proposals-history.jsonl" || missing=$((missing + 1))
done
[ "$missing" -eq 0 ] && pass "§B: all $NODE_N Node appends survived" \
  || fail "§B: $missing Node ids missing"

rm -rf "$T"
trap - EXIT

echo ""
echo "=== Results: $PASS passed, $FAIL failed (across $ROUNDS race rounds + §B) ==="
[ "$FAIL" -eq 0 ]
