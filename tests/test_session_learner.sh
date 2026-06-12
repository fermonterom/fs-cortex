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
        proposals.push({ id: `gotcha-${errorTool}-${hash}`, trigger: errorTool, action: `When ${errorTool} fails: ${fixSummary}`, confidence: 0.50, domain: 'error-recovery', source: 'session-learner:error-fix', status: 'pending', detected: TODAY, session: obs.sid || 'unknown' });
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

// v3.29.0 §4.6: detectWorkflowChains helper removed — the real detector was
// retired in this release (descriptive action + trigger that loses sequence
// context). The retired-detector absence test below asserts the function is
// gone from the production module too.

module.exports = { detectErrorResolutions, detectUserCorrections, isError, extractFilePath, shortHash };
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

# --- Test 5+6: Retired detectors absent from production module (v3.29.0 §4.6) ---
# detectRepetitions and detectWorkflowChains were deleted in v3.29.0. These
# two assertions ensure no future commit re-adds them silently — if the
# functions reappear, both tests fail loudly.
echo "--- Retired Detectors (v3.29.0 §4.6) ---"
result=$(node -e "
const m = require('$PROJECT_ROOT/hooks/session-learner.js');
console.log(typeof m.detectRepetitions === 'undefined' ? 'OK' : 'FAIL:' + typeof m.detectRepetitions);
")
[ "$result" = "OK" ] && pass "detectRepetitions absent from production module" || fail "retire-repetitions: $result"

result=$(node -e "
const m = require('$PROJECT_ROOT/hooks/session-learner.js');
console.log(typeof m.detectWorkflowChains === 'undefined' ? 'OK' : 'FAIL:' + typeof m.detectWorkflowChains);
")
[ "$result" = "OK" ] && pass "detectWorkflowChains absent from production module" || fail "retire-workflow: $result"

# Also verify the function definitions are gone from source (not just unexported).
result=$(grep -c '^function detectRepetitions\|^function detectWorkflowChains' "$PROJECT_ROOT/hooks/session-learner.js" || true)
[ "$result" = "0" ] && pass "retired function declarations removed from source" || fail "retire-source: found $result declaration(s)"

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

# --- Test 8: Command usage timeline detection (v3.8.0) ---
# v3.35.2: sandbox CORTEX_DIR — detectCommandUsage now also scans the global
# stream, so the test must not read (or write a cursor into) the live install.
echo "--- Command Timeline ---"
T8="$(mktemp -d -t learner-t8-XXXXXX)"
result=$(CORTEX_DIR="$T8" node -e "
// Load detectCommandUsage from the real module
const { detectCommandUsage } = require('$PROJECT_ROOT/hooks/session-learner.js');
// Mock fs.appendFileSync to capture timeline writes only (not log writes)
const fs = require('fs');
const origAppend = fs.appendFileSync;
const origMkdir = fs.mkdirSync;
let written = '';
fs.appendFileSync = (p, data) => {
  if (p.includes('timeline.jsonl')) { written = data; }
  else { origAppend(p, data); }
};
fs.mkdirSync = (p, opts) => { try { origMkdir(p, opts); } catch(_) {} };

const obs = [
  { tool: 'Skill', input: '{\"skill\":\"cx-dream\"}', ts: '2026-01-01T00:00:00Z', pid: 'abc123' },
  { tool: 'Skill', input: '{\"skill\":\"cx-status\"}', ts: '2026-01-01T00:01:00Z', pid: 'abc123' },
  { tool: 'Read', input: '/tmp/file.txt', ts: '2026-01-01T00:02:00Z', pid: 'abc123' },
  { tool: 'Skill', input: '{\"skill\":\"commit\"}', ts: '2026-01-01T00:03:00Z', pid: 'abc123' },
];
detectCommandUsage(obs);

fs.appendFileSync = origAppend;
fs.mkdirSync = origMkdir;

// Should have 2 cx- entries (cx-dream, cx-status), not 'commit'
const lines = written.trim().split('\n');
const cmds = lines.map(l => JSON.parse(l).cmd);
console.log(cmds.length === 2 && cmds.includes('cx-dream') && cmds.includes('cx-status') ? 'OK' : 'FAIL:' + JSON.stringify(cmds));
")
[ "$result" = "OK" ] && pass "timeline detects cx-* commands only" || fail "timeline: $result"
rm -rf "$T8"

# --- Test 8b: timeline scans global stream with cursor (v3.35.2, #56 audit) ---
# cx-* commands run from project-less cwds land in CORTEX_DIR/observations.jsonl
# (pid=global), which the learner never loads — the timeline silently died.
T8B="$(mktemp -d -t learner-t8b-XXXXXX)"
printf '{"ts":"2026-06-10T09:00:00Z","ev":"ts","tool":"Skill","sid":"x1","pid":"global","input":"{\\"skill\\": \\"cx-promote\\"}"}\n{"ts":"2026-06-10T09:05:00Z","ev":"ts","tool":"Bash","sid":"x1","pid":"global","input":"ls"}\n' > "$T8B/observations.jsonl"
result=$(CORTEX_DIR="$T8B" node -e "
const { detectCommandUsage } = require('$PROJECT_ROOT/hooks/session-learner.js');
const fs = require('fs');
detectCommandUsage([]);   // no session obs — must pick up the global stream
const tl = process.env.CORTEX_DIR + '/log/timeline.jsonl';
const first = fs.readFileSync(tl, 'utf8').trim().split('\n');
const cursor = fs.readFileSync(process.env.CORTEX_DIR + '/.timeline-cursor', 'utf8').trim();
detectCommandUsage([]);   // cursor must prevent reprocessing
const second = fs.readFileSync(tl, 'utf8').trim().split('\n');
const cmd = JSON.parse(first[0]).cmd;
console.log(JSON.stringify({n1: first.length, n2: second.length, cmd, cursorAdvanced: cursor === '2026-06-10T09:05:00Z'}));
")
echo "$result" | grep -q '"n1":1' && pass "root-scan detects global cx- command" || fail "8b detect: $result"
echo "$result" | grep -q '"cmd":"cx-promote"' && pass "root-scan extracts command name" || fail "8b cmd: $result"
echo "$result" | grep -q '"n2":1' && pass "cursor prevents duplicate on second run" || fail "8b idempotent: $result"
echo "$result" | grep -q '"cursorAdvanced":true' && pass "cursor advances to max ts seen" || fail "8b cursor: $result"
rm -rf "$T8B"

echo ""
echo "--- regex-utils (v3.29.0 §4.2) ---"

# escapeRegex must turn every ECMAScript regex metacharacter into a literal.
# We test the canonical metaset (. * + ? ^ $ { } ( ) | [ ] \) and verify the
# resulting pattern (a) compiles, and (b) matches the original literal input.
result=$(node -e "
const { escapeRegex } = require('$PROJECT_ROOT/hooks/lib/regex-utils.js');
const tricky = 'a.b*c+d?e^f\$g{h}(i)|j[k]\\\\l';
const escaped = escapeRegex(tricky);
let compiles = false, matches = false;
try {
  const re = new RegExp(escaped);
  compiles = true;
  matches = re.test(tricky);
} catch (_) {}
console.log(compiles && matches ? 'OK' : 'FAIL:' + escaped);
")
[ "$result" = "OK" ] && pass "escapeRegex makes all metachars literal" || fail "escapeRegex: $result"

# Idempotency on empty/null/undefined — must never throw, always returns ''.
result=$(node -e "
const { escapeRegex } = require('$PROJECT_ROOT/hooks/lib/regex-utils.js');
const a = escapeRegex(null);
const b = escapeRegex(undefined);
const c = escapeRegex('');
console.log(a === '' && b === '' && c === '' ? 'OK' : 'FAIL:' + JSON.stringify([a,b,c]));
")
[ "$result" = "OK" ] && pass "escapeRegex handles null/undefined/empty without throwing" || fail "escape-empty: $result"

echo ""
echo "--- detectFileCoupling (v3.29.0 §4.2 rewrite) ---"

# Generate enough Edit observations across two sessions to clear
# FILE_COUPLING_MIN_COUNT*2 (=10) and have foo.ts + bar.ts edited together
# in FILE_COUPLING_MIN_COUNT (=5) sessions. Then assert the emitted proposal
# has a valid regex trigger that matches Edit-on-foo.ts and does NOT match
# Edit-on-baz.ts, plus scope/project_id/confidence per §4.2.
result=$(node -e "
const { detectFileCoupling } = require('$PROJECT_ROOT/hooks/session-learner.js');
const obs = [];
for (let s = 0; s < 5; s++) {
  obs.push({ tool: 'Edit', input: JSON.stringify({ file_path: '/repo/foo.ts' }), ts: '2026-01-0' + (s+1) + 'T00:00:00Z', sid: 's' + s, _projectId: 'projX' });
  obs.push({ tool: 'Edit', input: JSON.stringify({ file_path: '/repo/bar.ts' }), ts: '2026-01-0' + (s+1) + 'T00:01:00Z', sid: 's' + s, _projectId: 'projX' });
}
const props = detectFileCoupling(obs);
const cp = props.find(p => p.id.startsWith('coupling-'));
if (!cp) { console.log('FAIL:no-proposal'); process.exit(0); }
// (1) trigger compiles
let compiles = false; try { new RegExp(cp.trigger); compiles = true; } catch(_) {}
// (2) trigger matches Edit foo.ts in the runtime matcher form
const matcherInput = 'Edit ' + JSON.stringify({ file_path: '/repo/foo.ts' });
const matchPos = new RegExp(cp.trigger).test(matcherInput);
// (3) trigger does NOT match Edit baz.ts
const matchNeg = new RegExp(cp.trigger).test('Edit ' + JSON.stringify({ file_path: '/repo/baz.ts' }));
// (4) scope + project_id + confidence + domain
const meta = cp.scope === 'project' && cp.project_id === 'projX' && cp.confidence === 0.55 && cp.domain === 'coupling';
console.log(JSON.stringify({ compiles, matchPos, matchNeg, meta, trigger: cp.trigger }));
")
echo "$result" | grep -q '\"compiles\":true' && pass "file-coupling trigger compiles as RegExp" || fail "coupling-compile: $result"
echo "$result" | grep -q '\"matchPos\":true' && pass "file-coupling trigger matches Edit on coupled file" || fail "coupling-pos: $result"
echo "$result" | grep -q '\"matchNeg\":false' && pass "file-coupling trigger does NOT match unrelated file" || fail "coupling-neg: $result"
echo "$result" | grep -q '\"meta\":true' && pass "file-coupling meta: scope=project, project_id, conf=0.55, domain=coupling" || fail "coupling-meta: $result"

# Special-char filenames are escaped (no regex injection from filenames like
# `app.config[old].ts`). The trigger must still compile and the embedded
# segment must round-trip as a literal match.
result=$(node -e "
const { detectFileCoupling } = require('$PROJECT_ROOT/hooks/session-learner.js');
const obs = [];
for (let s = 0; s < 5; s++) {
  obs.push({ tool: 'Edit', input: JSON.stringify({ file_path: '/repo/app.config[old].ts' }), ts: 't' + s, sid: 's' + s, _projectId: 'projX' });
  obs.push({ tool: 'Edit', input: JSON.stringify({ file_path: '/repo/safe.ts' }), ts: 't' + s + 'b', sid: 's' + s, _projectId: 'projX' });
}
const cp = detectFileCoupling(obs).find(p => p.id.startsWith('coupling-'));
if (!cp) { console.log('FAIL:no-proposal'); process.exit(0); }
let compiles = false; try { new RegExp(cp.trigger); compiles = true; } catch (_) {}
const matchTricky = compiles && new RegExp(cp.trigger).test('Edit ' + JSON.stringify({ file_path: '/repo/app.config[old].ts' }));
console.log(compiles && matchTricky ? 'OK' : 'FAIL:' + cp.trigger);
")
[ "$result" = "OK" ] && pass "file-coupling escapes special chars in filenames" || fail "coupling-escape: $result"

echo ""
echo "--- detectUserCorrections (v3.29.0 §4.3 rewrite) ---"

# Three overlapping edits to the same file must emit a correction proposal
# with the §4.3 contract: domain 'correction' (NOT 'user-preference', NOT
# 'gotcha'), confidence 0.55, scope 'project', project_id propagated from
# observations[0]._projectId, imperative action starting with "Before
# editing", trigger regex compiles + matches the file via the runtime form.
result=$(node -e "
const { detectUserCorrections } = require('$PROJECT_ROOT/hooks/session-learner.js');
const old = 'XXXXXXXXXXXXXXXXXXXXXX';   // long enough to register as overlap
const obs = [
  { tool: 'Edit', input: JSON.stringify({ file_path: '/r/foo.ts', old_string: old }), sid: 's1', _projectId: 'projQ' },
  { tool: 'Edit', input: JSON.stringify({ file_path: '/r/foo.ts', old_string: old }), sid: 's1', _projectId: 'projQ' },
  { tool: 'Edit', input: JSON.stringify({ file_path: '/r/foo.ts', old_string: old }), sid: 's1', _projectId: 'projQ' },
];
const props = detectUserCorrections(obs);
const c = props[0];
if (!c) { console.log('FAIL:no-proposal'); process.exit(0); }
let compiles = false; try { new RegExp(c.trigger); compiles = true; } catch (_) {}
const matchPos = compiles && new RegExp(c.trigger).test('Edit ' + JSON.stringify({ file_path: '/r/foo.ts' }));
const meta = (
  c.domain === 'correction' &&
  c.confidence === 0.55 &&
  c.scope === 'project' &&
  c.project_id === 'projQ' &&
  typeof c.action === 'string' && c.action.startsWith('Before editing foo.ts')
);
console.log(JSON.stringify({ compiles, matchPos, meta, trigger: c.trigger, domain: c.domain }));
")
echo "$result" | grep -q '\"compiles\":true' && pass "user-correction trigger compiles" || fail "correction-compile: $result"
echo "$result" | grep -q '\"matchPos\":true' && pass "user-correction trigger matches Edit on file" || fail "correction-pos: $result"
echo "$result" | grep -q '\"meta\":true' && pass "user-correction meta: domain=correction, conf=0.55, scope=project, action imperative" || fail "correction-meta: $result"

# Below-threshold (2 edits) must produce NOTHING (overlap+3-edit gate still
# enforced). Guards against accidental floor-lowering when §4.3 was rewritten.
result=$(node -e "
const { detectUserCorrections } = require('$PROJECT_ROOT/hooks/session-learner.js');
const obs = [
  { tool: 'Edit', input: JSON.stringify({ file_path: '/r/foo.ts', old_string: 'XXX' }), sid: 's1' },
  { tool: 'Edit', input: JSON.stringify({ file_path: '/r/foo.ts', old_string: 'XXX' }), sid: 's1' },
];
console.log(detectUserCorrections(obs).length === 0 ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "user-correction below-threshold (2 edits) = no proposal" || fail "correction-floor: $result"

echo ""
echo "--- detectAgentSubtypes (v3.29.0 §4.4 rewrite) ---"

# 4 Agent calls of the same subtype, 2 errored (50%, above 30% threshold) —
# must emit one agent-quality proposal with the §4.4 contract: domain
# 'agent-quality' (no change, was already correct), confidence 0.50, action
# starts with "Before spawning Agent subagent_type=" (imperative), trigger
# is the literal string 'Agent'.
result=$(node -e "
const { detectAgentSubtypes } = require('$PROJECT_ROOT/hooks/session-learner.js');
const obs = [
  { tool: 'Agent', input: JSON.stringify({ subagent_type: 'flaky-agent', description: 'try x' }), output: 'Error: failed', err: true, sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({ subagent_type: 'flaky-agent', description: 'try y' }), output: 'Error: failed', err: true, sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({ subagent_type: 'flaky-agent', description: 'try z' }), output: 'OK', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({ subagent_type: 'flaky-agent', description: 'try w' }), output: 'OK', sid: 's1' },
];
const p = detectAgentSubtypes(obs).find(x => x.domain === 'agent-quality');
if (!p) { console.log('FAIL:no-proposal'); process.exit(0); }
const meta = (
  p.domain === 'agent-quality' &&
  p.confidence === 0.50 &&
  p.trigger === 'Agent' &&
  typeof p.action === 'string' && p.action.startsWith('Before spawning Agent subagent_type=\"flaky-agent\"')
);
console.log(meta ? 'OK' : 'FAIL:' + JSON.stringify(p));
")
[ "$result" = "OK" ] && pass "agent-subtype meta: domain=agent-quality, conf=0.50, imperative action" || fail "subtype-meta: $result"

# Below-threshold error rate (10%) must NOT emit a proposal.
result=$(node -e "
const { detectAgentSubtypes } = require('$PROJECT_ROOT/hooks/session-learner.js');
const obs = [];
for (let i = 0; i < 10; i++) {
  obs.push({ tool: 'Agent', input: JSON.stringify({ subagent_type: 'healthy-agent' }), output: 'OK', sid: 's1' });
}
obs.push({ tool: 'Agent', input: JSON.stringify({ subagent_type: 'healthy-agent' }), output: 'Error: failed', err: true, sid: 's1' });
console.log(detectAgentSubtypes(obs).length === 0 ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "agent-subtype below 30% error rate = no proposal" || fail "subtype-floor: $result"

echo ""
echo "--- detectAgentPatterns (v3.29.0 §4.5 threshold 3→4) ---"

# 3 similar Agent uses are now BELOW threshold (pre-v3.29 emitted at 3).
result=$(node -e "
const { detectAgentPatterns } = require('$PROJECT_ROOT/hooks/session-learner.js');
const desc = 'investigate auth bug deeply';
const obs = Array.from({length:3}, (_,i) => ({ tool: 'Agent', input: JSON.stringify({ description: desc }), sid: 's' + i }));
console.log(detectAgentPatterns(obs).length === 0 ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "agent-patterns at items=3 = no proposal (was 1 pre-v3.29)" || fail "agent-3: $result"

# 4 similar uses → 1 proposal, conf 0.60 (clear margin above 0.55 floor).
result=$(node -e "
const { detectAgentPatterns } = require('$PROJECT_ROOT/hooks/session-learner.js');
const desc = 'investigate auth bug deeply';
const obs = Array.from({length:4}, (_,i) => ({ tool: 'Agent', input: JSON.stringify({ description: desc }), sid: 's' + i }));
const p = detectAgentPatterns(obs);
const ok = p.length === 1 && Math.abs(p[0].confidence - 0.60) < 0.001 && p[0].domain === 'agent-evolution';
console.log(ok ? 'OK' : 'FAIL:' + JSON.stringify(p));
")
[ "$result" = "OK" ] && pass "agent-patterns at items=4 → 1 proposal, conf=0.60, domain=agent-evolution" || fail "agent-4: $result"

echo ""
echo "--- evalToolSubstitution (v3.23.7+ aligned-or-ignored) ---"

# Extract evalToolSubstitution from session-learner.js and run 4 scenarios
LEARNER="$PROJECT_ROOT/hooks/session-learner.js"
result=$(node -e "
$(sed -n '/^function evalToolSubstitution/,/^}/p' "$LEARNER")

const ev = {
  expected_tool: 'Read',
  anti_tool: 'Bash',
  anti_pattern: '(?:^|[;&|]\\\\s*)(cat|head|tail)\\\\s+\\\\S+\\\\.(py|js|md)',
  window: 3,
};

// Scenario 1: pivot to Read in window → useful
const obs1 = [
  { tool: 'Bash', input: '{\"command\":\"cat foo.py\"}' },
  { tool: 'Read', input: '{\"file_path\":\"foo.py\"}' },
  { tool: 'Edit', input: '{}' },
  { tool: 'Bash', input: '{}' },
];
const r1 = evalToolSubstitution(ev, obs1, 0);

// Scenario 2: reincidence with anti_pattern → noise
// Note: anti_pattern requires a separator (semicolon/ampersand/pipe) or
// start-of-string before cat/head/tail. Use a compound command — single
// cat/head/tail in JSON-encoded input rarely matches because of the
// leading wrapper before the command value.
const obs2 = [
  { tool: 'Bash', input: '{\"command\":\"ls; cat foo.py\"}' },
  { tool: 'Bash', input: '{\"command\":\"echo X\"}' },
  { tool: 'Bash', input: '{\"command\":\"echo Y | head bar.js\"}' },  // reincidence
  { tool: 'Edit', input: '{}' },
];
const r2 = evalToolSubstitution(ev, obs2, 0);

// Scenario 3: no pivot, no reincidence, but window has follow-up → useful (aligned)
const obs3 = [
  { tool: 'Bash', input: '{\"command\":\"cat foo.py\"}' },
  { tool: 'Edit', input: '{}' },
  { tool: 'TodoWrite', input: '{}' },
  { tool: 'Agent', input: '{}' },
];
const r3 = evalToolSubstitution(ev, obs3, 0);

// Scenario 4: no follow-up at all (last event in observations) → ignore
const obs4 = [
  { tool: 'Bash', input: '{\"command\":\"cat foo.py\"}' },
];
const r4 = evalToolSubstitution(ev, obs4, 0);

console.log(JSON.stringify({r1, r2, r3, r4}));
")
echo "$result" | grep -q '\"r1\":\"useful\"' && pass "pivot to expected_tool → useful" || fail "scenario 1: $result"
echo "$result" | grep -q '\"r2\":\"noise\"' && pass "reincidence with anti_pattern → noise" || fail "scenario 2: $result"
echo "$result" | grep -q '\"r3\":\"useful\"' && pass "aligned (follow-up, no reincidence) → useful (v3.23.7 fix)" || fail "scenario 3: $result"
echo "$result" | grep -q '\"r4\":\"ignore\"' && pass "no follow-up → ignore" || fail "scenario 4: $result"

echo ""
echo "--- v3.36.1: semantic fix summary + proposal quality gate (audit) ---"

S_QG=$(mktemp -d)

# summarizeFixInput: semantic extraction instead of raw JSON blobs
result=$(CORTEX_DIR="$S_QG" node -e "
const m = require('$LEARNER');
const a = m.summarizeFixInput('Bash', JSON.stringify({command: 'uv run pytest -x'}));
const b = m.summarizeFixInput('Edit', JSON.stringify({file_path: '/Users/x/repo/src/app.ts', old_string: 'foo', new_string: 'bar'}));
const c = m.summarizeFixInput('Bash', '');
const d = m.summarizeFixInput('Agent', JSON.stringify({weird: 1}));
const ok = a === 'uv run pytest -x' && b === 'Edit app.ts' && c === '' && d === '';
console.log(ok ? 'OK' : 'FAIL:' + JSON.stringify({a, b, c, d}));
process.exit(0);
")
[ "$result" = "OK" ] && pass "summarizeFixInput: command / basename / empty / unknown" || fail "summarize: $result"

# detectErrorResolutions: a fix observation with no teachable input emits NO proposal
# (v3.37.0 fixtures: error tc carries err_msg, failing input lives on the prior ts)
result=$(CORTEX_DIR="$S_QG" node -e "
const m = require('$LEARNER');
const obs = [
  { tool: 'Bash', ev: 'ts', input: '{\"command\":\"pytest -x suites/\"}', ts: '2026-06-10T09:59:58Z' },
  { tool: 'Bash', ev: 'tc', err: true, err_msg: 'error: boom', output: 'error: boom', ts: '2026-06-10T10:00:00Z' },
  { tool: 'Bash', ev: 'ts', input: '', ts: '2026-06-10T10:00:30Z' },
  { tool: 'Bash', ev: 'tc', output: 'all good', ts: '2026-06-10T10:00:31Z' },
];
const r = m.detectErrorResolutions(obs);
console.log(r.length === 0 ? 'OK' : 'FAIL:' + JSON.stringify(r));
process.exit(0);
")
[ "$result" = "OK" ] && pass "hollow fix (empty input) → no proposal emitted" || fail "hollow-fix: $result"

# detectErrorResolutions: Edit fix carries basename, never old_string/raw JSON;
# v3.37.0: trigger derived from the failing input, err signature in action,
# evidence samples attached.
result=$(CORTEX_DIR="$S_QG" node -e "
const m = require('$LEARNER');
const obs = [
  { tool: 'Bash', ev: 'ts', input: '{\"command\":\"pnpm vitest run --filter web\"}', ts: '2026-06-10T09:59:59Z' },
  { tool: 'Bash', ev: 'tc', err: true, err_msg: 'error: fail in suite web', output: 'error: fail', ts: '2026-06-10T10:00:00Z' },
  { tool: 'Edit', ev: 'ts', input: '{\"file_path\":\"/Users/x/repo/lib/util.js\",\"old_string\":\"aaa\",\"new_string\":\"bbb\"}', ts: '2026-06-10T10:00:20Z' },
];
const r = m.detectErrorResolutions(obs);
const ok = r.length === 1
  && r[0].action.includes('Edit util.js')
  && r[0].action.includes('fails with \"error: fail in suite web\"')
  && !r[0].action.includes('old_string')
  && !r[0].action.includes('/Users/')
  && r[0].trigger !== 'Bash'
  && new RegExp(r[0].trigger, 'i').test('Bash {\"command\":\"pnpm vitest run --filter web\"}')
  && !new RegExp(r[0].trigger, 'i').test('Bash {}')
  && r[0].scope === 'global'
  && r[0].sample_input.includes('vitest')
  && r[0].err_msg === 'error: fail in suite web';
console.log(ok ? 'OK' : 'FAIL:' + JSON.stringify(r));
process.exit(0);
")
[ "$result" = "OK" ] && pass "Edit fix → basename, specific trigger, err sig, samples" || fail "edit-fix: $result"

# v3.37.0: error without err_msg → no proposal (evidence required)
result=$(CORTEX_DIR="$S_QG" node -e "
const m = require('$LEARNER');
const obs = [
  { tool: 'Bash', ev: 'ts', input: '{\"command\":\"pnpm vitest run\"}', ts: '2026-06-10T09:59:59Z' },
  { tool: 'Bash', ev: 'tc', err: true, output: 'error: fail', ts: '2026-06-10T10:00:00Z' },
  { tool: 'Edit', ev: 'ts', input: '{\"file_path\":\"/x/util.js\",\"old_string\":\"a\",\"new_string\":\"b\"}', ts: '2026-06-10T10:00:20Z' },
];
console.log(m.detectErrorResolutions(obs).length === 0 ? 'OK' : 'FAIL');
process.exit(0);
")
[ "$result" = "OK" ] && pass "error without err_msg → no proposal (v3.37.0)" || fail "no-errmsg: $result"

# v3.37.0: project-specific evidence (URL in err sig) → scope project, never global
result=$(CORTEX_DIR="$S_QG" node -e "
const m = require('$LEARNER');
const obs = [
  { tool: 'WebFetch', ev: 'ts', input: '{\"url\":\"https://ptah.sh/docs\",\"prompt\":\"extract pricing tiers\"}', ts: '2026-06-10T09:59:59Z', pid: 'abc123def456' },
  { tool: 'WebFetch', ev: 'tc', err: true, err_msg: '404 Not Found: https://ptah.sh/docs', output: '404', ts: '2026-06-10T10:00:00Z', pid: 'abc123def456' },
  { tool: 'WebFetch', ev: 'ts', input: '{\"url\":\"https://ptah.sh/\",\"prompt\":\"extract pricing tiers\"}', ts: '2026-06-10T10:00:10Z', pid: 'abc123def456' },
  { tool: 'WebFetch', ev: 'tc', output: 'Pricing: free tier...', ts: '2026-06-10T10:00:12Z', pid: 'abc123def456' },
];
const r = m.detectErrorResolutions(obs);
const ok = r.length === 1 && r[0].scope === 'project' && r[0].project_id === 'abc123def456';
console.log(ok ? 'OK' : 'FAIL:' + JSON.stringify(r));
process.exit(0);
")
[ "$result" = "OK" ] && pass "URL evidence → scope project + project_id (v3.37.0)" || fail "scope-project: $result"

# v3.37.0: agent-pattern trigger is never bare 'Agent'
result=$(CORTEX_DIR="$S_QG" node -e "
const m = require('$LEARNER');
const obs = Array.from({length: 4}, (_, i) => ({
  tool: 'Agent', ev: 'ts',
  input: JSON.stringify({ description: 'analyze playbook observations', prompt: 'x' }),
  ts: '2026-06-10T10:0' + i + ':00Z',
}));
const r = m.detectAgentPatterns(obs);
const ok = r.length === 1 && r[0].trigger !== 'Agent' && /Agent/.test(r[0].trigger);
console.log(ok ? 'OK' : 'FAIL:' + JSON.stringify(r));
process.exit(0);
")
[ "$result" = "OK" ] && pass "agent-pattern trigger scoped, not bare 'Agent' (v3.37.0)" || fail "agent-trigger: $result"

# writeProposals: quality gate rejects hollow actions before persisting
result=$(CORTEX_DIR="$S_QG" node -e "
const fs = require('fs');
const m = require('$LEARNER');
m.writeProposals([
  { id: 'gotcha-hollow', action: 'When Bash fails with similar pattern, try: ', status: 'pending', detected: '2026-06-10' },
  { id: 'gotcha-short', action: 'too short', status: 'pending', detected: '2026-06-10' },
  { id: 'gotcha-valid', action: 'When npm install fails with EACCES, clear the npm cache and retry the install.', status: 'pending', detected: '2026-06-10' },
]);
const live = JSON.parse(fs.readFileSync('$S_QG/proposals.json', 'utf8'));
const ids = live.map(p => p.id).sort();
console.log(JSON.stringify(ids) === JSON.stringify(['gotcha-valid']) ? 'OK' : 'FAIL:' + JSON.stringify(ids));
process.exit(0);
")
[ "$result" = "OK" ] && pass "writeProposals gate: hollow + short rejected, valid persisted" || fail "gate: $result"

# v3.37.1: rejection tombstones — an id rejected in proposals-history.jsonl
# never resurrects as pending, regardless of re-detection (the 6-week noise
# loop: same gotcha id was re-rejected 9 times in the live corpus).
result=$(CORTEX_DIR="$S_QG" node -e "
const fs = require('fs');
fs.rmSync('$S_QG/proposals.json', { force: true });
fs.writeFileSync('$S_QG/proposals-history.jsonl', JSON.stringify(
  { id: 'gotcha-zombie', status: 'rejected', rejected_by: 'cx-cleanup', action: 'old garbage' }
) + '\n');
const m = require('$LEARNER');
m.writeProposals([
  { id: 'gotcha-zombie', action: 'When Bash fails with EACCES on install, retry with the project-local prefix.', status: 'pending', detected: '2026-06-12' },
  { id: 'gotcha-fresh', action: 'When pnpm vitest fails with missing snapshot, run with --update to regenerate.', status: 'pending', detected: '2026-06-12' },
]);
const live = JSON.parse(fs.readFileSync('$S_QG/proposals.json', 'utf8'));
const ids = live.map(p => p.id).sort();
console.log(JSON.stringify(ids) === JSON.stringify(['gotcha-fresh']) ? 'OK' : 'FAIL:' + JSON.stringify(ids));
process.exit(0);
")
[ "$result" = "OK" ] && pass "tombstone gate: rejected id never resurrects (v3.37.1)" || fail "tombstone: $result"

# v3.37.2: isError heuristic guards — WebFetch 200-OK bodies and test-runner
# output are not errors (real false positives gotcha-WebFetch-c8b45df1 and
# gotcha-Bash-560c85ee). Explicit err flag always wins.
result=$(CORTEX_DIR="$S_QG" node -e "
const m = require('$LEARNER');
const webfetch200 = { tool: 'WebFetch', ev: 'tc', output: '{\"bytes\": 100775, \"code\": 200, \"codeText\": \"OK\", \"result\": \"mentions error handling and failed connections\"}' };
const structured2xx = { tool: 'Bash', ev: 'tc', output: '{\"bytes\": 73114, \"code\": 200, \"codeText\": \"OK\", \"result\": \"error: word in body\"}' };
const testlog = { tool: 'Bash', ev: 'tc', output: '  PASS: custom law preserved\n  FAIL: reflexes mismatch\n=== Results: 7 passed, 1 failed ===' };
const realErr = { tool: 'Bash', ev: 'tc', output: 'error: ENOENT no such file' };
const explicitErr = { tool: 'WebFetch', ev: 'tc', err: true, output: '404 Not Found' };
const ok = !m.isError(webfetch200) && !m.isError(structured2xx) && !m.isError(testlog)
  && m.isError(realErr) && m.isError(explicitErr);
console.log(ok ? 'OK' : 'FAIL');
process.exit(0);
")
[ "$result" = "OK" ] && pass "isError guards: 200-OK body + test log skipped, real/explicit kept (v3.37.2)" || fail "iserror-guards: $result"

# v3.37.2: end-to-end — a WebFetch 200-OK body followed by a successful call
# emits NO error-fix proposal (the c8b45df1 false-positive shape)
result=$(CORTEX_DIR="$S_QG" node -e "
const m = require('$LEARNER');
const obs = [
  { tool: 'WebFetch', ev: 'ts', input: '{\"url\":\"https://example.com/monitoring\",\"prompt\":\"extract RAM numbers\"}', ts: '2026-06-12T10:00:00Z' },
  { tool: 'WebFetch', ev: 'tc', err_msg: '{\"code\": 200, \"result\": \"error handling failed\"}', output: '{\"bytes\": 100775, \"code\": 200, \"codeText\": \"OK\", \"result\": \"error handling failed\"}', ts: '2026-06-12T10:00:02Z' },
  { tool: 'WebFetch', ev: 'ts', input: '{\"url\":\"https://example.com/other\",\"prompt\":\"extract CPU numbers\"}', ts: '2026-06-12T10:00:10Z' },
  { tool: 'WebFetch', ev: 'tc', output: 'Pricing: free tier', ts: '2026-06-12T10:00:12Z' },
];
console.log(m.detectErrorResolutions(obs).length === 0 ? 'OK' : 'FAIL:' + JSON.stringify(m.detectErrorResolutions(obs)));
process.exit(0);
")
[ "$result" = "OK" ] && pass "WebFetch 200-OK body → no error-fix proposal (v3.37.2)" || fail "webfetch-200: $result"
rm -rf "$S_QG"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
