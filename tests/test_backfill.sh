#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Backfill Tests (v3.33.0 C5) ==="

T="$(mktemp -d -t backfill-XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/instincts/global" "$T/archive"

cat > "$T/instincts/global/inst-eligible.yaml" <<'YAML'
---
id: inst-eligible
trigger: 'Bash'
action: 'Always verify output'
confidence: 0.9500
domain: gotcha
---
YAML

cat > "$T/instincts/global/inst-lowconf.yaml" <<'YAML'
---
id: inst-lowconf
trigger: 'Edit'
action: 'Check files'
confidence: 0.9000
domain: gotcha
---
YAML

cat > "$T/instinct-tracking.json" <<'JSON'
{
  "inst-eligible": {"count": 0, "sessions": [], "projects_seen": [], "first_seen": "2026-01-01T00:00:00Z", "last_seen": "2026-01-01T00:00:00Z"},
  "inst-lowconf": {"count": 0, "sessions": [], "projects_seen": [], "first_seen": "2026-01-01T00:00:00Z", "last_seen": "2026-01-01T00:00:00Z"}
}
JSON

cat > "$T/proposals-history.jsonl" <<'JSONL'
{"id":"inst-eligible","source":"session-learner:correction","status":"accepted","session":"s1"}
{"id":"inst-eligible","source":"session-learner:correction","status":"accepted","session":"s2"}
{"id":"inst-eligible","source":"session-learner:correction","status":"accepted","session":"s3"}
{"id":"inst-eligible","source":"session-learner:correction","status":"accepted","session_id":"s4"}
{"id":"inst-lowconf","source":"session-learner:coupling","status":"accepted","session":"x1"}
{"id":"inst-lowconf","source":"session-learner:coupling","status":"accepted","session":"x2"}
{"id":"inst-lowconf","source":"session-learner:coupling","status":"accepted","session":"x3"}
{"id":"rej-noise","source":"session-learner:correction","status":"rejected","session":"s2","rejection_category":"noise"}
JSONL

H1="$(shasum "$T/proposals-history.jsonl" | awk '{print $1}')"
TR1="$(shasum "$T/instinct-tracking.json" | awk '{print $1}')"

# Dry run: no writes
out=$(CORTEX_DIR="$T" python3 - <<'PYEOF'
import distill_engine as de
r = de.backfill_session_data(dry_run=True)
print(r['dry_run'], r['normalized'], r['tracking_rebuilt'], r['newly_eligible'], r['wrote_history'], r['wrote_tracking'])
PYEOF
)
if echo "$out" | grep -q "True 7 1 1 False False"; then
  pass "dry-run reports normalize/rebuild/eligible without writing"
else
  fail "dry-run report unexpected: $out"
fi

H2="$(shasum "$T/proposals-history.jsonl" | awk '{print $1}')"
TR2="$(shasum "$T/instinct-tracking.json" | awk '{print $1}')"
[ "$H1" = "$H2" ] && [ "$TR1" = "$TR2" ] && pass "dry-run leaves files unchanged" || fail "dry-run mutated files"

# Apply: writes + backup
out=$(CORTEX_DIR="$T" python3 - <<'PYEOF'
import distill_engine as de
r = de.backfill_session_data(dry_run=False)
print(r['dry_run'], r['normalized'], r['tracking_rebuilt'], r['newly_eligible'], len(r['backup_files']), r['wrote_history'], r['wrote_tracking'])
PYEOF
)
if echo "$out" | grep -q "False 7 1 1 2 True True"; then
  pass "apply writes history+tracking with backups"
else
  fail "apply report unexpected: $out"
fi

python3 - <<PYEOF
import json
from pathlib import Path
base = Path('$T')
# all rows with legacy session now include session_id
for line in base.joinpath('proposals-history.jsonl').read_text(encoding='utf-8').splitlines():
    if not line.strip():
        continue
    row = json.loads(line)
    if row.get('session') and not row.get('session_id'):
        raise SystemExit(1)
tracking = json.loads(base.joinpath('instinct-tracking.json').read_text(encoding='utf-8'))
assert tracking['inst-eligible']['sessions'] == ['s1', 's2', 's3', 's4']
assert tracking['inst-lowconf']['sessions'] == []
print('OK')
PYEOF
if [ $? -eq 0 ]; then pass "normalize + hybrid eligibility behavior correct"; else fail "normalize/hybrid verification failed"; fi

if ls "$T"/archive/backfill-* >/dev/null 2>&1; then
  pass "backup directory created"
else
  fail "backup directory missing"
fi

# Regression guard 1: lossless line-preserving rewrite on apply.
T_LOSSLESS="$(mktemp -d -t backfill-lossless-XXXXXX)"
mkdir -p "$T_LOSSLESS/archive"
cat > "$T_LOSSLESS/proposals-history.jsonl" <<'JSONL'
{"id":"ok-1","source":"session-learner:correction","status":"accepted","session":"s1"}
not-json-line
["array-not-dict"]
JSONL
cat > "$T_LOSSLESS/instinct-tracking.json" <<'JSON'
{}
JSON
in_nonblank=$(grep -cve '^[[:space:]]*$' "$T_LOSSLESS/proposals-history.jsonl")
out=$(CORTEX_DIR="$T_LOSSLESS" python3 - <<'PYEOF'
import distill_engine as de
de.backfill_session_data(dry_run=False)
PYEOF
)
out_nonblank=$(grep -cve '^[[:space:]]*$' "$T_LOSSLESS/proposals-history.jsonl")
python3 - <<PYEOF
import json
from pathlib import Path
p = Path("$T_LOSSLESS/proposals-history.jsonl")
lines = p.read_text(encoding="utf-8").splitlines()
assert "not-json-line" in lines
assert '["array-not-dict"]' in lines
rows = [json.loads(l) for l in lines if l.strip().startswith("{")]
assert rows[0]["session_id"] == "s1"
print("OK")
PYEOF
if [ $? -eq 0 ] && [ "$out_nonblank" -ge "$in_nonblank" ]; then
  pass "lossless apply preserves corrupt/non-dict lines and normalizes valid row"
else
  fail "lossless apply regression failed"
fi
rm -rf "$T_LOSSLESS"

# Regression guard 2: concurrency guard aborts and preserves original.
T_CONC="$(mktemp -d -t backfill-conc-XXXXXX)"
mkdir -p "$T_CONC/archive"
cat > "$T_CONC/proposals-history.jsonl" <<'JSONL'
{"id":"ok-1","source":"session-learner:correction","status":"accepted","session":"s1"}
JSONL
cat > "$T_CONC/instinct-tracking.json" <<'JSON'
{}
JSON
H_ORIG="$(shasum "$T_CONC/proposals-history.jsonl" | awk '{print $1}')"
out=$(CORTEX_DIR="$T_CONC" python3 - <<'PYEOF'
import distill_engine as de
orig = de.json.loads
state = {"calls": 0, "done": False}
def mutating_loads(line):
    obj = orig(line)
    state["calls"] += 1
    if not state["done"] and state["calls"] >= 3 and isinstance(obj, dict):
        with open(de.PROPOSALS_HISTORY_FILE, "a", encoding="utf-8") as fh:
            fh.write('{"id":"concurrent"}\n')
        state["done"] = True
    return obj
de.json.loads = mutating_loads
try:
    de.backfill_session_data(dry_run=False)
except Exception as e:
    print(type(e).__name__, str(e))
finally:
    de.json.loads = orig
PYEOF
)
H_AFTER="$(shasum "$T_CONC/proposals-history.jsonl" | awk '{print $1}')"
if echo "$out" | grep -q "history changed during run, aborted" && [ "$H_ORIG" != "$H_AFTER" ]; then
  # The mutation happened, but backfill must not overwrite it.
  if grep -q '"id":"concurrent"' "$T_CONC/proposals-history.jsonl" && ! grep -q '"session_id":"s1"' "$T_CONC/proposals-history.jsonl"; then
    pass "concurrency guard aborts write and leaves concurrently-changed file intact"
  else
    fail "concurrency guard altered file despite abort"
  fi
else
  fail "concurrency guard did not trigger as expected: $out"
fi
rm -rf "$T_CONC"

# Idempotent second apply
out=$(CORTEX_DIR="$T" python3 - <<'PYEOF'
import distill_engine as de
r = de.backfill_session_data(dry_run=False)
print(r['normalized'], r['tracking_rebuilt'], r['newly_eligible'])
PYEOF
)
if echo "$out" | grep -q "0 0 0"; then
  pass "idempotent second apply is no-op"
else
  fail "idempotency failed: $out"
fi

# ── CLI --apply re-enabled in v3.35.0 (issue #49 closed) ─────────────────────
# The operator-facing `_cmd_backfill(apply=True)` now writes. The cross-runtime
# lock (HISTORY_LOCK_FILE) closes the Stop-hook race; see
# tests/test_backfill_concurrency.sh for the actual concurrency proof.
T_APPLY="$(mktemp -d -t backfill-apply-XXXXXX)"
mkdir -p "$T_APPLY/archive" "$T_APPLY/instincts/global"
cat > "$T_APPLY/instincts/global/inst-cli.yaml" <<'YAML'
---
id: inst-cli
trigger: 'Bash'
action: 'noop'
confidence: 0.5
domain: gotcha
---
YAML
cat > "$T_APPLY/proposals-history.jsonl" <<'JSONL'
{"id":"inst-cli","source":"session-learner:correction","status":"accepted","session":"legacy-1"}
JSONL
cat > "$T_APPLY/instinct-tracking.json" <<'JSON'
{}
JSON
H_APPLY_BEFORE="$(shasum "$T_APPLY/proposals-history.jsonl" | awk '{print $1}')"
out=$(CORTEX_DIR="$T_APPLY" python3 - <<'PYEOF'
import io, contextlib
import distill_engine as de
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    de._cmd_backfill(apply=True)
msg = buf.getvalue()
flags = []
if "Backfill applied:" in msg: flags.append("APPLIED")
if "deferred" in msg.lower() or "[GATED]" in msg: flags.append("STILLGATED")
if "wrote_history" in msg: flags.append("WROTE")
print(" ".join(flags) or "NONE")
PYEOF
)
H_APPLY_AFTER="$(shasum "$T_APPLY/proposals-history.jsonl" | awk '{print $1}')"
if echo "$out" | grep -q "APPLIED" && ! echo "$out" | grep -q "STILLGATED"; then
  pass "CLI --apply now writes (gate removed in v3.35.0)"
else
  fail "CLI --apply output unexpected: $out"
fi
[ "$H_APPLY_BEFORE" != "$H_APPLY_AFTER" ] && pass "CLI --apply mutates history (legacy session normalized)" \
  || fail "CLI --apply did not mutate history"
ls "$T_APPLY"/archive/backfill-* >/dev/null 2>&1 && pass "CLI --apply creates backup before writing" \
  || fail "CLI --apply should create backup directory"
rm -rf "$T_APPLY"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
