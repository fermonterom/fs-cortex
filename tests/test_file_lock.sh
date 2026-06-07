#!/usr/bin/env bash
# test_file_lock.sh — issue #49.
# Unit tests for hooks/lib/file_lock.py and hooks/lib/file-lock.js.
# Covers: acquire/release, timeout, stale steal (dead PID), live-PID guard,
# and cross-runtime serialization (Python <-> Node) on the SAME lockfile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== file_lock tests (issue #49) ==="

T="$(mktemp -d -t filelock-XXXXXX)"
umask 077
trap 'rm -rf "$T"' EXIT

LOCK="$T/test.lock"

# --- Test 1: Python acquire/release happy path ---
out=$(LOCK="$LOCK" python3 - <<'PYEOF'
import os, file_lock
lock = os.environ["LOCK"]
tok = file_lock.acquire(lock, timeout_ms=1000)
assert tok == lock, f"expected token={lock}, got {tok}"
assert os.path.exists(lock), "lockfile not created"
file_lock.release(tok)
assert not os.path.exists(lock), "lockfile not removed"
print("OK")
PYEOF
)
[ "$out" = "OK" ] && pass "Python acquire/release happy path" || fail "Python happy path: $out"

# --- Test 2: Python contended acquire returns None after timeout ---
out=$(LOCK="$LOCK" python3 - <<'PYEOF'
import os, time, file_lock
lock = os.environ["LOCK"]
tok1 = file_lock.acquire(lock, timeout_ms=500)
assert tok1, "first acquire failed"
t0 = time.monotonic()
tok2 = file_lock.acquire(lock, timeout_ms=300)
dt = (time.monotonic() - t0) * 1000
assert tok2 is None, f"expected None, got {tok2}"
assert 250 <= dt <= 1200, f"timeout out of range: {dt:.0f}ms"
file_lock.release(tok1)
print("OK")
PYEOF
)
[ "$out" = "OK" ] && pass "Python contended acquire times out" || fail "Python timeout: $out"

# --- Test 3: Python steals stale lock (dead PID + old mtime) ---
out=$(LOCK="$LOCK" python3 - <<'PYEOF'
import os, json, time, file_lock
lock = os.environ["LOCK"]
# Plant a stale lockfile with a definitely-dead PID and very old mtime.
with open(lock, "w") as f:
    f.write(json.dumps({"pid": 2147483646, "ts": 0, "host": "fake", "owner": "py"}))
# Push mtime far into the past.
os.utime(lock, (time.time() - 600, time.time() - 600))
tok = file_lock.acquire(lock, timeout_ms=1000, stale_ms=1000)
assert tok == lock, f"expected token={lock}, got {tok}"
file_lock.release(tok)
print("OK")
PYEOF
)
[ "$out" = "OK" ] && pass "Python steals stale lock (dead PID + old mtime)" || fail "Python stale steal: $out"

# --- Test 4: Python does NOT steal stale lock if PID is alive ---
out=$(LOCK="$LOCK" python3 - <<'PYEOF'
import os, json, time, file_lock
lock = os.environ["LOCK"]
# Plant a stale-by-mtime lockfile but with OUR PID (definitely alive).
with open(lock, "w") as f:
    f.write(json.dumps({"pid": os.getpid(), "ts": 0, "host": "self", "owner": "py"}))
os.utime(lock, (time.time() - 600, time.time() - 600))
tok = file_lock.acquire(lock, timeout_ms=500, stale_ms=1000)
assert tok is None, f"expected None (alive PID owns lock), got {tok}"
os.unlink(lock)
print("OK")
PYEOF
)
[ "$out" = "OK" ] && pass "Python refuses to steal live-PID lock" || fail "Python live-PID guard: $out"

# --- Test 5: Node acquire/release happy path ---
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: node not on PATH (cross-runtime tests skipped)"
else
out=$(LOCK="$LOCK" PROJECT="$PROJECT_ROOT" node -e '
  const fileLock = require(process.env.PROJECT + "/hooks/lib/file-lock");
  const lock = process.env.LOCK;
  const tok = fileLock.acquire(lock, { timeoutMs: 1000 });
  if (tok !== lock) { console.log("FAIL token=" + tok); process.exit(1); }
  const fs = require("fs");
  if (!fs.existsSync(lock)) { console.log("FAIL not created"); process.exit(1); }
  fileLock.release(tok);
  if (fs.existsSync(lock)) { console.log("FAIL not removed"); process.exit(1); }
  console.log("OK");
')
[ "$out" = "OK" ] && pass "Node acquire/release happy path" || fail "Node happy path: $out"

# --- Test 6: Node contended acquire times out ---
out=$(LOCK="$LOCK" PROJECT="$PROJECT_ROOT" node -e '
  const fileLock = require(process.env.PROJECT + "/hooks/lib/file-lock");
  const lock = process.env.LOCK;
  const tok1 = fileLock.acquire(lock, { timeoutMs: 500 });
  if (!tok1) { console.log("FAIL first acquire"); process.exit(1); }
  const t0 = Date.now();
  const tok2 = fileLock.acquire(lock, { timeoutMs: 300 });
  const dt = Date.now() - t0;
  if (tok2 !== null) { console.log("FAIL expected null got " + tok2); process.exit(1); }
  if (dt < 250 || dt > 1200) { console.log("FAIL timeout " + dt + "ms"); process.exit(1); }
  fileLock.release(tok1);
  console.log("OK");
')
[ "$out" = "OK" ] && pass "Node contended acquire times out" || fail "Node timeout: $out"

# --- Test 7: cross-runtime — Python holds, Node waits, then acquires ---
# Python acquires, writes a readiness marker, holds 800 ms. Node waits for the
# marker (NOT a timing guess), then must block on acquire until Python releases.
READY7="$T/py_ready"
rm -f "$READY7" "$LOCK"
LOCK="$LOCK" READY="$READY7" python3 - <<'PYEOF' &
import os, time, file_lock
lock = os.environ["LOCK"]
tok = file_lock.acquire(lock, timeout_ms=2000)
assert tok
open(os.environ["READY"], "w").write("1")           # signal: lock held
time.sleep(0.8)
file_lock.release(tok)
PYEOF
PY_PID=$!
LOCK="$LOCK" READY="$READY7" PROJECT="$PROJECT_ROOT" node -e '
  const fs = require("fs");
  const lock = process.env.LOCK;
  const ready = process.env.READY;
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    if (fs.existsSync(ready)) break;          // Python has the lock
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  }
  if (!fs.existsSync(ready)) { console.log("FAIL python never signalled"); process.exit(1); }
  const fileLock = require(process.env.PROJECT + "/hooks/lib/file-lock");
  const t0 = Date.now();
  const tok = fileLock.acquire(lock, { timeoutMs: 5000 });
  const dt = Date.now() - t0;
  if (tok !== lock) { console.log("FAIL got " + tok); process.exit(1); }
  if (dt < 100) { console.log("FAIL did not wait (dt=" + dt + ")"); process.exit(1); }
  fileLock.release(tok);
  console.log("OK " + dt);
' > "$T/cross.out" 2>&1
wait "$PY_PID" || true
rm -f "$READY7"
if grep -q "^OK " "$T/cross.out"; then
  pass "cross-runtime: Python holds, Node waits, then acquires"
else
  fail "cross-runtime py->node: $(cat "$T/cross.out")"
fi
rm -f "$LOCK"

# --- Test 8: cross-runtime reverse — Node holds, Python waits, then acquires ---
# Node acquires, writes a readiness marker, holds 800 ms. Python waits for the
# marker (NOT a timing guess), then must block on acquire until Node releases.
READY="$T/node_ready"
rm -f "$READY" "$LOCK"
LOCK="$LOCK" READY="$READY" PROJECT="$PROJECT_ROOT" node -e '
  const fs = require("fs");
  const fileLock = require(process.env.PROJECT + "/hooks/lib/file-lock");
  const lock = process.env.LOCK;
  const tok = fileLock.acquire(lock, { timeoutMs: 2000 });
  if (!tok) { process.stderr.write("node failed to acquire\n"); process.exit(1); }
  fs.writeFileSync(process.env.READY, "1");           // signal: lock held
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 800);
  fileLock.release(tok);
' &
NODE_PID=$!
# Guard with `|| true`: a non-zero exit (assert) must NOT kill the script
# under `set -e`; the grep below is the verdict.
LOCK="$LOCK" READY="$READY" python3 - <<'PYEOF' > "$T/cross2.out" 2>&1 || true
import os, time, file_lock
lock = os.environ["LOCK"]
ready = os.environ["READY"]
# Wait for Node's readiness marker — Node has the lock once this exists.
deadline = time.monotonic() + 3.0
while time.monotonic() < deadline:
    if os.path.exists(ready):
        break
    time.sleep(0.02)
assert os.path.exists(ready), "node never signalled readiness"
t0 = time.monotonic()
tok = file_lock.acquire(lock, timeout_ms=5000)
dt = (time.monotonic() - t0) * 1000
assert tok == lock, f"got {tok}"
assert dt >= 100, f"did not wait (dt={dt:.0f})"
file_lock.release(tok)
print(f"OK {dt:.0f}")
PYEOF
wait "$NODE_PID" || true
rm -f "$READY"
if grep -q "^OK " "$T/cross2.out"; then
  pass "cross-runtime: Node holds, Python waits, then acquires"
else
  fail "cross-runtime node->py: $(cat "$T/cross2.out")"
fi
fi  # end node-required block

# --- Test 9: AD P0-1 — release verifies nonce ---
# If a stale-stealer reclaims the lock while we are paused, our release()
# must NOT unlink the stealer's lockfile. Simulate by:
#  1) acquire as Python A,
#  2) manually rewrite the on-disk payload with a different nonce (= stealer),
#  3) call A.release() — it must NOT remove the file.
out=$(LOCK="$LOCK" python3 - <<'PYEOF'
import os, json, file_lock
lock = os.environ["LOCK"]
tok = file_lock.acquire(lock, timeout_ms=1000)
assert tok == lock
# Simulate stealer reclaim: rewrite payload with a different nonce.
with open(lock, "w") as f:
    f.write(json.dumps({"pid": os.getpid(), "ts": 0, "nonce": "STEALER-DEADBEEF", "owner": "py"}))
file_lock.release(tok)
assert os.path.exists(lock), "release() unlinked a stealer-owned lock"
os.unlink(lock)
print("OK")
PYEOF
)
[ "$out" = "OK" ] && pass "Python release verifies nonce (P0-1)" || fail "Python nonce check: $out"

if command -v node >/dev/null 2>&1; then
out=$(LOCK="$LOCK" PROJECT="$PROJECT_ROOT" node -e '
  const fs = require("fs");
  const fileLock = require(process.env.PROJECT + "/hooks/lib/file-lock");
  const lock = process.env.LOCK;
  const tok = fileLock.acquire(lock, { timeoutMs: 1000 });
  if (!tok) { console.log("FAIL acquire"); process.exit(1); }
  // Simulate stealer reclaim.
  fs.writeFileSync(lock, JSON.stringify({pid: process.pid, ts: 0, nonce: "STEALER-DEADBEEF", owner: "node"}));
  fileLock.release(tok);
  if (!fs.existsSync(lock)) { console.log("FAIL release unlinked stealer lock"); process.exit(1); }
  fs.unlinkSync(lock);
  console.log("OK");
')
[ "$out" = "OK" ] && pass "Node release verifies nonce (P0-1)" || fail "Node nonce check: $out"
fi

# --- Test 10: AD round 2/3 — concurrent stealers via rename-to-claim ---
# Plant ONE stale lockfile (dead PID + old mtime), then launch 8 concurrent
# acquirers as independent OS processes (bash background jobs — NOT
# multiprocessing, which re-imports `<stdin>` under macOS spawn and fork-bombs).
#
# AD round 3 determinism fix: a START BARRIER removes process-startup spread as
# a confound. Each worker writes a `ready-i` marker, then spin-waits for a `GO`
# file before calling acquire — so all 8 race from the same instant regardless
# of how slowly the CI runner spawned them. The winner HOLDS the lock 6 s while
# STAYING ALIVE (PID alive → fresh lock never looks stale to peers); acquirer
# timeout is 2000 ms ≪ 6 s, so the 7 losers time out → LOSE. With atomic
# rename-to-claim, exactly ONE process reclaims the stale lock. The pre-fix bug
# (two stealers both unlink+create) would let >1 win. Assertion: WINS == 1.
RACEDIR="$T/race"
rm -rf "$RACEDIR"; mkdir -p "$RACEDIR"
rm -f "$LOCK"
GO="$RACEDIR/GO"
# Plant the stale lock from a single process.
LOCK="$LOCK" python3 -c '
import os, json, time
lock = os.environ["LOCK"]
with open(lock, "w") as f:
    f.write(json.dumps({"pid": 2147483646, "ts": 0, "nonce": "stale-nonce", "owner": "py"}))
os.utime(lock, (time.time() - 600, time.time() - 600))
'
# Launch 8 acquirers. Each signals readiness, waits for GO, then races.
for i in $(seq 0 7); do
  LOCK="$LOCK" RES="$RACEDIR/r$i" READY="$RACEDIR/ready-$i" GO="$GO" python3 -c '
import os, time, file_lock
open(os.environ["READY"], "w").write("1")
# Spin-wait for the GO barrier (max 10s safety).
deadline = time.monotonic() + 10
while time.monotonic() < deadline and not os.path.exists(os.environ["GO"]):
    time.sleep(0.005)
tok = file_lock.acquire(os.environ["LOCK"], timeout_ms=2000, stale_ms=1000)
open(os.environ["RES"], "w").write("WIN" if tok else "LOSE")
if tok:
    time.sleep(6)   # hold, stay alive → peers see a fresh non-stale lock
' &
done
# Wait until all 8 workers are ready, then fire the barrier.
for _ in $(seq 1 200); do
  ready=$(find "$RACEDIR" -maxdepth 1 -name 'ready-*' | wc -l | tr -d ' ')
  [ "$ready" -eq 8 ] && break
  python3 -c "import time; time.sleep(0.02)"
done
touch "$GO"
wait
wins=$(find "$RACEDIR" -maxdepth 1 -name 'r[0-9]' -type f -exec grep -l "WIN" {} + 2>/dev/null | wc -l | tr -d ' ')
results=$(find "$RACEDIR" -maxdepth 1 -name 'r[0-9]' -type f | wc -l | tr -d ' ')
rm -f "$LOCK"; rm -rf "$RACEDIR"
if [ "$wins" -eq 1 ] && [ "$results" -eq 8 ]; then
  pass "Python rename-to-claim race: exactly 1 winner among 8 (wins=$wins)"
else
  fail "Python rename-to-claim race: wins=$wins (expected 1), results=$results/8"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
