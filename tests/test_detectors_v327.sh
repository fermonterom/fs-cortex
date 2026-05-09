#!/usr/bin/env bash
# Tests for v3.27.0 detectors: detectAgentSubtypes, detectFileCoupling, detectTimeOfDayPatterns
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEARNER="$REPO_ROOT/hooks/session-learner.js"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local script="$2"
  if node -e "$script" >/dev/null 2>&1; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    node -e "$script" 2>&1 | head -5
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_detectors_v327.sh ==="

# ── detectAgentSubtypes ─────────────────────────────────────────────────────

run_test "agent-subtypes: emits at 3 uses with >30% errors" "
process.env.CORTEX_DIR = '$SANDBOX';
const { detectAgentSubtypes } = require('$LEARNER');
const obs = [
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: true,  ts: '2026-05-09T10:00:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: true,  ts: '2026-05-09T10:01:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: false, ts: '2026-05-09T10:02:00Z', sid: 's1' },
];
const result = detectAgentSubtypes(obs);
if (result.length !== 1) throw new Error('expected 1 proposal, got ' + result.length);
if (!result[0].id.includes('explore')) throw new Error('id mismatch: ' + result[0].id);
if (result[0].confidence !== 0.45) throw new Error('confidence: ' + result[0].confidence);
// v3.28.5 — schema completeness assertions
if (result[0].status !== 'pending') throw new Error('status missing or wrong: ' + result[0].status);
if (result[0].source !== 'session-learner:agent-error-rate') throw new Error('source mismatch: ' + result[0].source);
"

run_test "v3.28.5: agent-subtypes slugifies dangerous chars in subtype" "
process.env.CORTEX_DIR = '$SANDBOX';
const { detectAgentSubtypes } = require('$LEARNER');
const obs = [
  { tool: 'Agent', input: JSON.stringify({subagent_type: '../../etc/passwd'}), err: true,  ts: '2026-05-09T10:00:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: '../../etc/passwd'}), err: true,  ts: '2026-05-09T10:01:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: '../../etc/passwd'}), err: false, ts: '2026-05-09T10:02:00Z', sid: 's1' },
];
const result = detectAgentSubtypes(obs);
if (result.length !== 1) throw new Error('expected 1 proposal, got ' + result.length);
const id = result[0].id;
if (id.includes('/') || id.includes('..')) throw new Error('id not slugified: ' + id);
if (!/^agent-error-rate-[a-z0-9_-]+\$/.test(id)) throw new Error('id has unsafe chars: ' + id);
"

run_test "agent-subtypes: no emit with fewer than 3 uses" "
process.env.CORTEX_DIR = '$SANDBOX';
const { detectAgentSubtypes } = require('$LEARNER');
const obs = [
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: true,  ts: '2026-05-09T10:00:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: true,  ts: '2026-05-09T10:01:00Z', sid: 's1' },
];
const result = detectAgentSubtypes(obs);
if (result.length !== 0) throw new Error('expected 0 proposals, got ' + result.length);
"

run_test "agent-subtypes: no emit when error rate <30%" "
process.env.CORTEX_DIR = '$SANDBOX';
const { detectAgentSubtypes } = require('$LEARNER');
const obs = [
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: false, ts: '2026-05-09T10:00:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: false, ts: '2026-05-09T10:01:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: false, ts: '2026-05-09T10:02:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: false, ts: '2026-05-09T10:03:00Z', sid: 's1' },
  { tool: 'Agent', input: JSON.stringify({subagent_type: 'Explore'}), err: true,  ts: '2026-05-09T10:04:00Z', sid: 's1' },
];
const result = detectAgentSubtypes(obs);
if (result.length !== 0) throw new Error('expected 0 proposals for 20% error rate, got ' + result.length);
"

# ── detectFileCoupling ──────────────────────────────────────────────────────

run_test "file-coupling: emits with 5+ sessions of same pair" "
process.env.CORTEX_DIR = '$SANDBOX';
const { detectFileCoupling } = require('$LEARNER');
const obs = [];
for (let i = 0; i < 5; i++) {
  obs.push({ tool: 'Edit', input: JSON.stringify({file_path: '/a/foo.ts'}), sid: 'session-' + i });
  obs.push({ tool: 'Edit', input: JSON.stringify({file_path: '/a/bar.ts'}), sid: 'session-' + i });
}
const result = detectFileCoupling(obs);
if (result.length !== 1) throw new Error('expected 1 proposal, got ' + result.length);
if (result[0].occurrences !== 5) throw new Error('occurrences: ' + result[0].occurrences);
if (!result[0].action.includes('foo.ts') || !result[0].action.includes('bar.ts')) throw new Error('action missing filenames: ' + result[0].action);
// v3.28.5 — schema completeness assertions
if (result[0].status !== 'pending') throw new Error('status missing or wrong: ' + result[0].status);
if (result[0].source !== 'session-learner:file-coupling') throw new Error('source mismatch: ' + result[0].source);
"

run_test "file-coupling: no emit with fewer than 5 sessions" "
process.env.CORTEX_DIR = '$SANDBOX';
const { detectFileCoupling } = require('$LEARNER');
const obs = [];
for (let i = 0; i < 4; i++) {
  obs.push({ tool: 'Edit', input: JSON.stringify({file_path: '/a/foo.ts'}), sid: 'session-' + i });
  obs.push({ tool: 'Edit', input: JSON.stringify({file_path: '/a/bar.ts'}), sid: 'session-' + i });
}
const result = detectFileCoupling(obs);
if (result.length !== 0) throw new Error('expected 0 proposals, got ' + result.length);
"

run_test "file-coupling: ignores obs without file_path" "
process.env.CORTEX_DIR = '$SANDBOX';
const { detectFileCoupling } = require('$LEARNER');
const obs = [];
for (let i = 0; i < 5; i++) {
  obs.push({ tool: 'Edit', input: JSON.stringify({file_path: '/a/foo.ts'}), sid: 'session-' + i });
  obs.push({ tool: 'Edit', input: JSON.stringify({}), sid: 'session-' + i }); // no file_path
}
const result = detectFileCoupling(obs);
if (result.length !== 0) throw new Error('expected 0 proposals (no complete pairs), got ' + result.length);
"

# ── detectTimeOfDayPatterns ─────────────────────────────────────────────────

run_test "time-of-day: writes productivity-patterns.json with correct buckets" "
const fs = require('fs');
const path = require('path');
const cortexDir = path.join('$SANDBOX', 'tod-test-' + process.pid);
fs.mkdirSync(cortexDir, {recursive: true});
process.env.CORTEX_DIR = cortexDir;
const { detectTimeOfDayPatterns } = require('$LEARNER');
const obs = [
  { tool: 'Bash', ts: '2026-05-09T10:00:00Z', err: false, sid: 's1' },
  { tool: 'Read', ts: '2026-05-09T10:30:00Z', err: false, sid: 's1' },
  { tool: 'Edit', ts: '2026-05-09T14:00:00Z', err: true,  sid: 's1' },
];
const r = detectTimeOfDayPatterns(obs);
if (!Array.isArray(r) || r.length !== 0) throw new Error('expected [], got ' + JSON.stringify(r));
const ppPath = path.join(cortexDir, 'productivity-patterns.json');
if (!fs.existsSync(ppPath)) throw new Error('productivity-patterns.json not written');
const data = JSON.parse(fs.readFileSync(ppPath, 'utf8'));
if (!data.buckets) throw new Error('missing buckets field');
if (!data.by_hour) throw new Error('missing by_hour field');
if (data.buckets.morning.total !== 2) throw new Error('morning total: ' + data.buckets.morning.total);
if (data.buckets.afternoon.total !== 1) throw new Error('afternoon total: ' + data.buckets.afternoon.total);
if (data.buckets.afternoon.errors !== 1) throw new Error('afternoon errors: ' + data.buckets.afternoon.errors);
"

run_test "time-of-day: returns empty array (no proposals)" "
const fs = require('fs');
const path = require('path');
const cortexDir = path.join('$SANDBOX', 'tod-empty-' + process.pid);
fs.mkdirSync(cortexDir, {recursive: true});
process.env.CORTEX_DIR = cortexDir;
const { detectTimeOfDayPatterns } = require('$LEARNER');
const r = detectTimeOfDayPatterns([{ tool: 'Bash', ts: '2026-05-09T09:00:00Z', sid: 's1' }]);
if (!Array.isArray(r) || r.length !== 0) throw new Error('expected [], got ' + JSON.stringify(r));
"

run_test "time-of-day: merge accumulates correctly when file already exists" "
const fs = require('fs');
const path = require('path');
const cortexDir = path.join('$SANDBOX', 'tod-merge-' + process.pid);
fs.mkdirSync(cortexDir, {recursive: true});
process.env.CORTEX_DIR = cortexDir;
const { detectTimeOfDayPatterns } = require('$LEARNER');
// First run: 2 morning obs
detectTimeOfDayPatterns([
  { tool: 'Bash', ts: '2026-05-09T08:00:00Z', sid: 's1' },
  { tool: 'Read', ts: '2026-05-09T09:00:00Z', sid: 's1' },
]);
// Second run: 1 more morning obs
detectTimeOfDayPatterns([
  { tool: 'Edit', ts: '2026-05-09T11:00:00Z', sid: 's2' },
]);
const ppPath = path.join(cortexDir, 'productivity-patterns.json');
const data = JSON.parse(fs.readFileSync(ppPath, 'utf8'));
if (data.buckets.morning.total !== 3) throw new Error('merged morning total: ' + data.buckets.morning.total);
"

run_test "time-of-day: reflect data has expected JSON structure" "
const fs = require('fs');
const path = require('path');
const cortexDir = path.join('$SANDBOX', 'tod-reflect-' + process.pid);
fs.mkdirSync(cortexDir, {recursive: true});
process.env.CORTEX_DIR = cortexDir;
const { detectTimeOfDayPatterns } = require('$LEARNER');
detectTimeOfDayPatterns([
  { tool: 'Bash', ts: '2026-05-09T19:00:00Z', err: true, sid: 's1' },
  { tool: 'Bash', ts: '2026-05-09T20:00:00Z', err: true, sid: 's1' },
  { tool: 'Edit', ts: '2026-05-09T21:00:00Z', err: false, sid: 's1' },
]);
const data = JSON.parse(fs.readFileSync(path.join(cortexDir, 'productivity-patterns.json'), 'utf8'));
// Verify required fields for --reflect formatting
if (!data.updated) throw new Error('missing updated');
if (!data.summary) throw new Error('missing summary');
if (!data.insights) throw new Error('missing insights');
// Evening bucket should have 2 errors out of 3 (>10%) → insight generated
if (data.insights.length === 0) throw new Error('expected insight for high error bucket, got none');
if (!data.insights[0].includes('evening')) throw new Error('insight does not mention evening: ' + data.insights[0]);
"

run_test "time-of-day: corrupted JSON aborts write (no clobber)" "
const fs = require('fs');
const path = require('path');
const cortexDir = path.join('$SANDBOX', 'tod-corrupt-' + process.pid);
fs.mkdirSync(cortexDir, {recursive: true});
process.env.CORTEX_DIR = cortexDir;
const { detectTimeOfDayPatterns } = require('$LEARNER');
const ppPath = path.join(cortexDir, 'productivity-patterns.json');
fs.writeFileSync(ppPath, '{invalid json{{', 'utf8');
const result = detectTimeOfDayPatterns([{ tool: 'Bash', ts: '2026-05-09T10:00:00Z', sid: 's1' }]);
if (!Array.isArray(result) || result.length !== 0) throw new Error('expected [] on corrupt file, got ' + JSON.stringify(result));
const contents = fs.readFileSync(ppPath, 'utf8');
if (contents !== '{invalid json{{') throw new Error('corrupted file was overwritten: ' + contents.slice(0, 40));
"

run_test "file-coupling: file paths containing :: do not corrupt pair split" "
process.env.CORTEX_DIR = '$SANDBOX';
const { detectFileCoupling } = require('$LEARNER');
const obs = [];
for (let i = 0; i < 5; i++) {
  obs.push({ tool: 'Edit', input: JSON.stringify({file_path: '/a/foo::special.ts'}), sid: 'session-' + i });
  obs.push({ tool: 'Edit', input: JSON.stringify({file_path: '/a/bar.ts'}), sid: 'session-' + i });
}
const result = detectFileCoupling(obs);
if (result.length !== 1) throw new Error('expected 1 proposal, got ' + result.length);
if (!result[0].action.includes('foo::special.ts')) throw new Error('filename mangled in action: ' + result[0].action);
"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
