#!/usr/bin/env bash
# Guard corpus tests (v3.23.4+) — verify that EVERY shipped reflex matcher,
# reflex condition, and global instinct trigger passes the centralized
# regex guard (lib/regex-guard.js + lib/regex_guard.py) in BOTH languages.
#
# Why this exists
#   v3.23.3 silently regressed bash-cat-use-read because its condition
#   crossed length>100 + matched a false-positive ReDoS pattern.
#   test_reflex_matchers.sh only verified the regex semantics in Python;
#   it never asked "does this pattern survive the runtime guard?".
#   This corpus closes that gap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
GUARD_JS="$PROJECT_ROOT/hooks/lib/regex-guard.js"
GUARD_PY="$PROJECT_ROOT/hooks/lib/regex_guard.py"
DEFAULT_REFLEXES="$PROJECT_ROOT/core/reflexes.default.json"
GLOBAL_INSTINCTS_DIR="$HOME/.claude/cortex/instincts/global"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Guard corpus tests (v3.23.4+) ==="

# ── Reflex matchers + conditions (Node guard) ───────────────────────────────
echo ""
echo "--- Reflexes default (Node guard) ---"
TS=$(date +%Y%m%d-%H%M%S)
LOG=/tmp/test-guard-corpus-${TS}.log
node -e "
const { unsafeReason } = require('$GUARD_JS');
const refs = require('$DEFAULT_REFLEXES').reflexes;
let bad = 0;
for (const r of refs) {
  const mr = unsafeReason(r.matcher);
  const cr = r.condition ? unsafeReason(r.condition) : null;
  if (mr) { console.log('REJECT_MATCHER ' + r.id + ' ' + mr); bad++; }
  if (cr) { console.log('REJECT_COND    ' + r.id + ' ' + cr); bad++; }
}
console.log('TOTAL_BAD ' + bad);
console.log('TOTAL ' + refs.length);
" > "$LOG" 2>&1
BAD=$(grep "^TOTAL_BAD " "$LOG" | awk '{print $2}')
TOT=$(grep "^TOTAL " "$LOG" | awk '{print $2}')
[ "$BAD" = "0" ] && pass "all $TOT reflex matchers+conditions accepted by guard" || {
  fail "reflexes rejected: $BAD"
  grep "^REJECT" "$LOG"
}

# Confirm the bash-cat regression specifically — its condition is the
# canonical regression sample.
result=$(node -e "
const { isSafeRegex } = require('$GUARD_JS');
const cond = require('$DEFAULT_REFLEXES').reflexes.find(r => r.id === 'bash-cat-use-read').condition;
console.log(isSafeRegex(cond) ? 'OK' : 'FAIL:' + cond.length);
")
[ "$result" = "OK" ] && pass "bash-cat-use-read condition accepted (Node)" || fail "bash-cat: $result"

# ── Reflex matchers + conditions (Python guard) ─────────────────────────────
echo ""
echo "--- Reflexes default (Python guard) ---"
result=$(PYTHONPATH="$PROJECT_ROOT/hooks/lib" python3 -c "
import json
from regex_guard import unsafe_reason
refs = json.load(open('$DEFAULT_REFLEXES'))['reflexes']
bad = 0
for r in refs:
    if unsafe_reason(r.get('matcher','')): bad += 1
    cond = r.get('condition')
    if cond and unsafe_reason(cond): bad += 1
print(bad)
")
[ "$result" = "0" ] && pass "all reflexes accepted by Python guard" || fail "python rejected: $result"

# ── Global instinct triggers (both guards) ──────────────────────────────────
echo ""
echo "--- Global instincts (Node + Python) ---"
if [ -d "$GLOBAL_INSTINCTS_DIR" ]; then
  result=$(node -e "
  const fs = require('fs');
  const path = require('path');
  const { unsafeReason } = require('$GUARD_JS');
  let bad = 0, tot = 0;
  for (const f of fs.readdirSync('$GLOBAL_INSTINCTS_DIR')) {
    if (!f.endsWith('.yaml')) continue;
    tot++;
    const c = fs.readFileSync(path.join('$GLOBAL_INSTINCTS_DIR', f), 'utf8');
    const m = c.match(/^trigger:\s*(.+)\$/m);
    if (!m) continue;
    let trg = m[1].trim();
    if ((trg.startsWith('\"') && trg.endsWith('\"')) || (trg.startsWith(\"'\") && trg.endsWith(\"'\"))) trg = trg.slice(1, -1);
    const r = unsafeReason(trg);
    if (r) { console.log('REJECT ' + f + ' ' + r); bad++; }
  }
  console.log('TOTAL_BAD ' + bad);
  console.log('TOTAL ' + tot);
  ")
  bad=$(echo "$result" | grep "^TOTAL_BAD " | awk '{print $2}')
  tot=$(echo "$result" | grep "^TOTAL " | awk '{print $2}')
  [ "$bad" = "0" ] && pass "all $tot global instinct triggers accepted (Node)" || {
    fail "global instinct triggers rejected: $bad"
    echo "$result" | grep "^REJECT"
  }
else
  echo "  SKIP: no global instincts directory at $GLOBAL_INSTINCTS_DIR"
fi

# ── Adversarial corpus (must STILL be rejected) ─────────────────────────────
echo ""
echo "--- Adversarial corpus (must reject) ---"
result=$(node -e "
const { isSafeRegex } = require('$GUARD_JS');
const cases = [
  ['(a+)+',           'nested + inside +'],
  ['(a*)*',           'nested * inside *'],
  ['(a+)*',           'nested + inside *'],
  ['a'.repeat(201),   'over MAX_LEN'],
  [Array.from({length: 27}, (_, i) => 'x' + i).join('|'), 'over MAX_PIPES'],
  ['[unterminated',   'invalid regex'],
];
let ok = 0;
for (const [pat, label] of cases) {
  if (!isSafeRegex(pat)) ok++;
  else console.log('FAIL ' + label + ': ' + pat.slice(0,40));
}
console.log('OK ' + ok + '/' + cases.length);
")
got=$(echo "$result" | grep "^OK " | awk '{print $2}')
[ "$got" = "6/6" ] && pass "all 6 adversarial patterns rejected" || {
  fail "adversarial rejection: $got"
  echo "$result" | grep "^FAIL"
}

# ── Safe corpus (must STILL be accepted post-v3.23.4 limit raise) ───────────
echo ""
echo "--- Safe corpus (must accept) ---"
result=$(node -e "
const { isSafeRegex } = require('$GUARD_JS');
const cases = [
  ['(a+)?b',                                   'optional + capture (Q? cannot ReDoS)'],
  ['(?:^|[;&|]\\\\s*)grep\\\\s+(-[a-zA-Z]*[rR][a-zA-Z]*)', 'bash-grep condition'],
  ['Bash.*(npm|node|npx|pnpm)\\\\s+(run|install|test|build|exec)',  'pattern-macos-path-prefix instinct (7 pipes)'],
  ['a'.repeat(200),                            'exactly MAX_LEN'],
  [Array.from({length: 25}, (_, i) => 'x' + i).join('|'), 'exactly MAX_PIPES'],
];
let ok = 0;
for (const [pat, label] of cases) {
  if (isSafeRegex(pat)) ok++;
  else console.log('FAIL ' + label);
}
console.log('OK ' + ok + '/' + cases.length);
")
got=$(echo "$result" | grep "^OK " | awk '{print $2}')
[ "$got" = "5/5" ] && pass "all 5 safe patterns accepted" || {
  fail "safe acceptance: $got"
  echo "$result" | grep "^FAIL"
}

# ── Parity Node ↔ Python ────────────────────────────────────────────────────
echo ""
echo "--- Parity Node ↔ Python (same input → same reason) ---"
PARITY_LOG=/tmp/test-guard-parity-${TS}.log
node -e "
const { unsafeReason } = require('$GUARD_JS');
const cases = [
  '(a+)+', '(a+)?', '(a*)*', '(a|aa)+',
  'a'.repeat(201), 'a'.repeat(200),
  'Bash|Edit|Write',
  Array.from({length: 26}, (_, i) => 'x'+i).join('|'),
  Array.from({length: 25}, (_, i) => 'x'+i).join('|'),
  '[unterminated', '\\\\b(cat|head|tail)\\\\b',
];
console.log(JSON.stringify(cases.map(c => [c, unsafeReason(c)])));
" > "$PARITY_LOG"
PARITY_OK=$(PYTHONPATH="$PROJECT_ROOT/hooks/lib" python3 -c "
import json
from regex_guard import unsafe_reason
cases = json.loads(open('$PARITY_LOG').read())
mismatches = []
for pat, js_reason in cases:
    py_reason = unsafe_reason(pat)
    if (js_reason or '') != (py_reason or ''):
        mismatches.append((pat[:30], js_reason, py_reason))
if mismatches:
    for m in mismatches: print('MISMATCH', m)
    print('FAIL')
else:
    print('OK')
")
if echo "$PARITY_OK" | grep -q "^OK$"; then
  pass "Node and Python guards return identical reasons for 11 corpus inputs"
else
  fail "parity mismatch"
  echo "$PARITY_OK"
fi

# ── Documented gap: (a|aa)+ alternation overlap ─────────────────────────────
echo ""
echo "--- Known gaps (must NOT regress) ---"
result=$(node -e "
const { isSafeRegex } = require('$GUARD_JS');
// (a|aa)+ is technically a ReDoS pattern via alternation overlap. The current
// detector \\([^)]*[+*]\\)[+*] only flags inner +/* quantifiers. This pattern
// is accepted today as a known gap; the live timeout (50ms) catches it if it
// ever gets exercised against pathological input. Documented for v3.24.0+.
console.log(isSafeRegex('(a|aa)+') ? 'ACCEPTED' : 'REJECTED');
")
[ "$result" = "ACCEPTED" ] && pass "(a|aa)+ accepted (known gap, see regex-guard.js header)" || fail "gap regressed: $result"

# ── Live reflexes.json (the user's actual file, not just core defaults) ─────
echo ""
echo "--- Live reflexes.json (user-installed) ---"
LIVE_REFLEXES="$HOME/.claude/cortex/reflexes.json"
if [ -f "$LIVE_REFLEXES" ]; then
  result=$(node -e "
  const { unsafeReason } = require('$GUARD_JS');
  const refs = require('$LIVE_REFLEXES').reflexes;
  let bad = 0;
  for (const r of refs) {
    if (unsafeReason(r.matcher)) { console.log('REJ_M ' + r.id); bad++; }
    if (r.condition && unsafeReason(r.condition)) { console.log('REJ_C ' + r.id); bad++; }
  }
  console.log('BAD ' + bad + ' of ' + refs.length);
  ")
  bad=$(echo "$result" | grep "^BAD " | awk '{print $2}')
  tot=$(echo "$result" | grep "^BAD " | awk '{print $4}')
  [ "$bad" = "0" ] && pass "all $tot live reflexes accepted by guard" || {
    fail "live reflexes rejected: $bad"
    echo "$result" | grep "^REJ"
  }
else
  echo "  SKIP: no live reflexes.json (not installed?)"
fi

# ── Result tally ────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
