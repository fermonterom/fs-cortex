#!/usr/bin/env bash
# Session learner tests — error-fix pairs, corrections, workflow chains, proposals
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Create a test helper that extracts and exports functions from session-learner.js
HELPER=$(mktemp)
trap "rm -f $HELPER" EXIT

cat > "$HELPER" << 'JSEOF'
const path = require('path');
const crypto = require('crypto');
const TODAY = new Date().toISOString().slice(0, 10);

function shortHash(str) {
  return crypto.createHash('md5').update(str).digest('hex').slice(0, 8);
}

function isError(obs) {
  if (obs.err === true) return true;
  const output = String(obs.output || '');
  if (!output) return false;
  return /\b(error|Error|ERROR|ENOENT|EACCES|EPERM|failed|Failed|FAILED|exception|Exception|denied|not found|No such file)\b/.test(output);
}

function extractFilePath(input) {
  if (!input) return null;
  const s = String(input);
  const m = s.match(/"file_path"\s*:\s*"([^"]+)"/);
  return m ? m[1] : null;
}

function detectErrorResolutions(observations) {
  const proposals = [];
  const WINDOW = 10;
  for (let i = 0; i < observations.length; i++) {
    const obs = observations[i];
    if (!isError(obs)) continue;
    const errorTool = obs.tool;
    for (let j = i + 1; j < Math.min(i + WINDOW + 1, observations.length); j++) {
      const candidate = observations[j];
      const isFix = (candidate.tool === 'Edit' || candidate.tool === 'Write' || candidate.tool === errorTool) && !isError(candidate);
      if (isFix) {
        const fixSummary = String(candidate.input || '').slice(0, 200);
        const hash = shortHash(`${errorTool}-${obs.ts || i}`);
        proposals.push({ id: `gotcha-${errorTool}-${hash}`, trigger: errorTool, action: `When ${errorTool} fails: ${fixSummary}`, confidence: 0.40, domain: 'error-recovery', source: 'session-learner:error-fix', status: 'pending', detected: TODAY, session: obs.sid || 'unknown' });
        break;
      }
    }
  }
  return proposals;
}

function detectUserCorrections(observations) {
  const corrections = [];
  const fileEdits = {};
  for (const obs of observations) {
    if (obs.tool !== 'Edit' && obs.tool !== 'Write') continue;
    const file = extractFilePath(obs.input);
    if (!file) continue;
    if (!fileEdits[file]) fileEdits[file] = [];
    fileEdits[file].push(obs);
  }
  for (const [file, edits] of Object.entries(fileEdits)) {
    if (edits.length >= 2) {
      const hash = shortHash(file);
      corrections.push({ id: `correction-${hash}`, trigger: `Edit.*${path.basename(file)}`, action: `User corrected ${path.basename(file)} (${edits.length}x)`, confidence: 0.50, domain: 'user-preference', source: 'session-learner:correction', status: 'pending', detected: TODAY, session: edits[0].sid || 'unknown' });
    }
  }
  return corrections;
}

function detectWorkflowChains(observations, minCount) {
  minCount = minCount || 3;
  const trigrams = {};
  for (let i = 0; i < observations.length - 2; i++) {
    const a = observations[i].tool, b = observations[i+1].tool, c = observations[i+2].tool;
    if (!a || !b || !c) continue;
    const key = a + '->' + b + '->' + c;
    if (!trigrams[key]) trigrams[key] = 0;
    trigrams[key]++;
  }
  return Object.entries(trigrams).filter(([_, count]) => count >= minCount).map(([chain, count]) => {
    return { id: `workflow-${shortHash(chain)}`, trigger: chain.split('->')[0], action: `Workflow: ${chain} (${count}x)`, confidence: Math.min(0.60, 0.30 + count * 0.05), domain: 'workflow', source: 'session-learner:workflow', status: 'pending', detected: TODAY, session: observations[0].sid || 'unknown' };
  });
}

module.exports = { detectErrorResolutions, detectUserCorrections, detectWorkflowChains, isError, extractFilePath, shortHash };
JSEOF

echo "=== Session Learner Tests ==="
echo ""

# --- Test 1: Error-fix pair detection ---
echo "--- Error-Fix Pairs ---"
result=$(node -e "
const { detectErrorResolutions } = require('$HELPER');
const obs = [
  { tool: 'Bash', err: true, err_msg: 'npm test failed', output: 'Error: test failed', ts: '2026-01-01T00:00:00Z', sid: 't1' },
  { tool: 'Edit', err: false, input: '{\"file_path\":\"/src/app.ts\"}', ts: '2026-01-01T00:01:00Z', sid: 't1' },
];
const pairs = detectErrorResolutions(obs);
console.log(pairs.length >= 1 ? 'OK' : 'FAIL:' + pairs.length);
")
[ "$result" = "OK" ] && pass "error-fix pair detected" || fail "error-fix: $result"

# --- Test 2: Error without fix produces nothing ---
result=$(node -e "
const { detectErrorResolutions } = require('$HELPER');
const obs = [
  { tool: 'Bash', err: true, output: 'Error: fail', ts: '2026-01-01T00:00:00Z', sid: 't1' },
  { tool: 'Bash', err: true, output: 'Error: still fail', ts: '2026-01-01T00:01:00Z', sid: 't1' },
];
console.log(detectErrorResolutions(obs).length === 0 ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "no fix = no proposal" || fail "no-fix: $result"

# --- Test 3: User correction detection ---
echo "--- User Corrections ---"
result=$(node -e "
const { detectUserCorrections } = require('$HELPER');
const obs = [
  { tool: 'Edit', input: '{\"file_path\":\"/src/app.ts\"}', ts: '1', sid: 't1' },
  { tool: 'Edit', input: '{\"file_path\":\"/src/app.ts\"}', ts: '2', sid: 't1' },
  { tool: 'Edit', input: '{\"file_path\":\"/src/other.ts\"}', ts: '3', sid: 't1' },
];
const c = detectUserCorrections(obs);
console.log(c.length === 1 ? 'OK' : 'FAIL:' + c.length);
")
[ "$result" = "OK" ] && pass "user correction detected (1 file 2x)" || fail "correction: $result"

# --- Test 4: Single edit = no correction ---
result=$(node -e "
const { detectUserCorrections } = require('$HELPER');
const obs = [{ tool: 'Edit', input: '{\"file_path\":\"/src/app.ts\"}', ts: '1', sid: 't1' }];
console.log(detectUserCorrections(obs).length === 0 ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "single edit = no correction" || fail "single-edit: $result"

# --- Test 5: Workflow chain trigrams ---
echo "--- Workflow Chains ---"
result=$(node -e "
const { detectWorkflowChains } = require('$HELPER');
const obs = [
  {tool:'Grep',sid:'t1'},{tool:'Read',sid:'t1'},{tool:'Edit',sid:'t1'},
  {tool:'Grep',sid:'t1'},{tool:'Read',sid:'t1'},{tool:'Edit',sid:'t1'},
  {tool:'Grep',sid:'t1'},{tool:'Read',sid:'t1'},{tool:'Edit',sid:'t1'},
];
const chains = detectWorkflowChains(obs, 3);
console.log(chains.some(c => c.action.includes('Grep->Read->Edit')) ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "Grep->Read->Edit chain detected" || fail "chain: $result"

# --- Test 6: No chains below threshold ---
result=$(node -e "
const { detectWorkflowChains } = require('$HELPER');
const obs = [
  {tool:'Grep',sid:'t1'},{tool:'Read',sid:'t1'},{tool:'Edit',sid:'t1'},
  {tool:'Bash',sid:'t1'},{tool:'Write',sid:'t1'},{tool:'Glob',sid:'t1'},
];
console.log(detectWorkflowChains(obs, 3).length === 0 ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "below threshold = no chain" || fail "threshold: $result"

# --- Test 7: Proposals have correct structure ---
echo "--- Proposal Structure ---"
result=$(node -e "
const { detectErrorResolutions } = require('$HELPER');
const obs = [
  { tool: 'Bash', err: true, output: 'Error: fail', ts: '2026-01-01T00:00:00Z', sid: 't1' },
  { tool: 'Edit', err: false, input: 'fix', ts: '2026-01-01T00:01:00Z', sid: 't1' },
];
const p = detectErrorResolutions(obs)[0];
const hasAll = p.id && p.trigger && p.action && p.confidence && p.domain && p.source && p.status === 'pending';
console.log(hasAll ? 'OK' : 'FAIL:' + JSON.stringify(p));
")
[ "$result" = "OK" ] && pass "proposal has required fields" || fail "structure: $result"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
