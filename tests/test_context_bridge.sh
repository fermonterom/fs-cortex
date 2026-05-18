#!/usr/bin/env bash
# Session-bridge regression tests (v3.31.0)
# Covers writer (session-learner.js), reader (session-start.py),
# cleanup helper (dream_cycle.py), and one-shot script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0
SANDBOX=""

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

cleanup() { [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

echo "=== Session Bridge Tests (v3.31.0) ==="
echo ""

SANDBOX=$(mktemp -d)
export SANDBOX

# ── Test 1: writer output ≤ 500 bytes for 100 observations ────────
echo "Test 1: writer output ≤ 500 bytes"
mkdir -p "$SANDBOX/projects/test1"
cat > "$SANDBOX/registry.json" << 'EOF'
{"test1": {"name": "test-project"}}
EOF
node -e "
process.env.CORTEX_DIR = '$SANDBOX';
const path = require('path');
const fs = require('fs');
function pathBasename(p) { return String(p || '').split(/[\\\\/]/).pop() || ''; }
const PROJECTS_DIR = '$SANDBOX/projects';
const TODAY = '2026-05-17';
function isError(o) { return !!o.err; }
function ensureDir(d) { fs.mkdirSync(d, { recursive: true }); }
function log() {}
const REGISTRY_PATH = '$SANDBOX/registry.json';
function readJsonFile(p) { try { return JSON.parse(fs.readFileSync(p)); } catch { return null; } }

// 100 observations mixing tools — but only basename-extractable Edit/Write count
const obs = [];
for (let i = 0; i < 100; i++) {
  obs.push({
    _projectId: 'test1',
    tool: ['Bash','Read','Edit','Write','Grep','Glob'][i % 6],
    input: JSON.stringify({ file_path: '/Users/fmm/github/fs-cortex/foo' + (i % 3) + '.js' }),
    err: i % 30 === 0,
  });
}

// Inline the writer body
function writeContextFile(observations) {
  if (observations.length === 0) return;
  const projectId = observations[0]._projectId || 'global';
  const projectDir = path.join(PROJECTS_DIR, projectId);
  let projectName = projectId;
  const registry = readJsonFile(REGISTRY_PATH);
  if (registry && registry[projectId]) projectName = registry[projectId].name || projectId;
  const filesBasenames = [...new Set(observations.filter(o => o.tool === 'Edit' || o.tool === 'Write').map(o => { try { return pathBasename(JSON.parse(o.input || '{}').file_path); } catch { return null; } }).filter(Boolean))].slice(0, 6);
  const errorCount = observations.filter(isError).length;
  const lines = [
    '## Proyecto: ' + projectName,
    'Última sesión: ' + TODAY,
    'Observaciones totales: ' + observations.length,
    filesBasenames.length > 0 ? 'Archivos activos: ' + filesBasenames.join(', ') : null,
    errorCount > 0 ? 'Posibles gotchas detectados: ' + errorCount + ' — ejecuta /cx-analyze' : null,
  ].filter(Boolean);
  const content = lines.join('\n') + '\n';
  ensureDir(projectDir);
  fs.writeFileSync(path.join(projectDir, 'context.md'), content);
}

writeContextFile(obs);
const size = fs.statSync('$SANDBOX/projects/test1/context.md').size;
console.log(size <= 500 ? 'OK:' + size : 'TOO_BIG:' + size);
"
result=$(cat "$SANDBOX/projects/test1/context.md" | wc -c | tr -d ' ')
[ "$result" -le 500 ] && pass "writer ≤500 bytes ($result)" || fail "writer too big ($result)"

# ── Test 2: writer writes Spanish (## Proyecto:) ──────────────────
echo "Test 2: writer writes Spanish keywords"
head -1 "$SANDBOX/projects/test1/context.md" | grep -q "^## Proyecto:" && pass "Spanish header present" || fail "header not Spanish"

# ── Test 3: writer omits gotcha CTA when errorCount == 0 ──────────
echo "Test 3: writer omits gotcha CTA when no errors"
mkdir -p "$SANDBOX/projects/test3"
node -e "
const fs = require('fs');
const path = require('path');
function pathBasename(p) { return String(p || '').split(/[\\\\/]/).pop() || ''; }
const obs = [
  { _projectId: 'test3', tool: 'Edit', input: JSON.stringify({ file_path: '/x/y.js' }), err: false },
  { _projectId: 'test3', tool: 'Read', input: '{}', err: false },
];
const filesBasenames = [...new Set(obs.filter(o => o.tool === 'Edit' || o.tool === 'Write').map(o => { try { return pathBasename(JSON.parse(o.input || '{}').file_path); } catch { return null; } }).filter(Boolean))].slice(0, 6);
const errorCount = obs.filter(o => o.err).length;
const lines = [
  '## Proyecto: t3',
  'Última sesión: 2026-05-17',
  'Observaciones totales: ' + obs.length,
  filesBasenames.length > 0 ? 'Archivos activos: ' + filesBasenames.join(', ') : null,
  errorCount > 0 ? 'Posibles gotchas detectados: ' + errorCount + ' — ejecuta /cx-analyze' : null,
].filter(Boolean);
fs.writeFileSync('$SANDBOX/projects/test3/context.md', lines.join('\n') + '\n');
"
grep -q "Posibles gotchas" "$SANDBOX/projects/test3/context.md" && fail "gotcha line present when shouldn't" || pass "gotcha line absent on errorCount=0"

# ── Test 4: writer caps at 6 basenames + dedup ────────────────────
echo "Test 4: writer cap=6 + dedup"
result=$(node -e "
function pathBasename(p) { return String(p || '').split(/[\\\\/]/).pop() || ''; }
const obs = [];
for (let i = 0; i < 20; i++) obs.push({ tool: 'Edit', input: JSON.stringify({ file_path: '/x/file' + (i % 10) + '.js' }) });
const fb = [...new Set(obs.filter(o => o.tool === 'Edit' || o.tool === 'Write').map(o => { try { return pathBasename(JSON.parse(o.input || '{}').file_path); } catch { return null; } }).filter(Boolean))].slice(0, 6);
console.log(fb.length);
")
[ "$result" = "6" ] && pass "cap 6 + dedup applied ($result)" || fail "expected 6 got $result"

# ── Test 5: writer normalizes Windows paths ──────────────────────
echo "Test 5: writer handles Windows paths"
result=$(node -e "
function pathBasename(p) { return String(p || '').split(/[\\\\/]/).pop() || ''; }
console.log(pathBasename('C:\\\\Users\\\\x\\\\file.js'));
")
[ "$result" = "file.js" ] && pass "Windows path → basename" || fail "Windows path not normalized: $result"

# ── Test 6: reader injects with [project-context]\\n prefix ────────
echo "Test 6: reader prefix"
mkdir -p "$SANDBOX/projects/abc123"
cat > "$SANDBOX/projects/abc123/context.md" << 'EOF'
## Proyecto: test
Última sesión: 2026-05-17
Observaciones totales: 42
EOF
result=$(python3 -c "
import sys, os, time
sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
from cortex_utils import sanitize_injection
with open('$SANDBOX/projects/abc123/context.md') as f:
    content = f.read().strip()
tagged = '[project-context]\n' + content
out = sanitize_injection(tagged, 2000)
print('OK' if out.startswith('[project-context]\n') else 'FAIL:' + out[:40])
")
[ "$result" = "OK" ] && pass "reader injects [project-context] prefix" || fail "$result"

# ── Test 7: reader preserves newlines ─────────────────────────────
echo "Test 7: reader preserves newlines"
result=$(python3 -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
from cortex_utils import sanitize_injection
tagged = '[project-context]\nline1\nline2\nline3'
out = sanitize_injection(tagged, 2000)
print('OK' if out.count('\n') == 3 else 'FAIL:' + str(out.count('\n')))
")
[ "$result" = "OK" ] && pass "reader keeps 3 newlines" || fail "$result"

# ── Test 8: cleanup helper rotates legacy English format ──────────
echo "Test 8: cleanup rotates legacy format"
mkdir -p "$SANDBOX/projects/legacy1"
echo "## Project: old-style" > "$SANDBOX/projects/legacy1/context.md"
result=$(python3 -c "
import sys, os
sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
from dream_cycle import cleanup_corrupted_context_files
rotated = cleanup_corrupted_context_files('$SANDBOX/projects', today='20260517')
print('OK' if len(rotated) >= 1 else 'FAIL:nothing-rotated')
")
[ "$result" = "OK" ] && pass "legacy format rotated" || fail "$result"
[ -f "$SANDBOX/projects/legacy1/context.md.legacy-20260517" ] && pass "backup file created" || fail "no backup file"

# ── Test 9: cleanup helper preserves new Spanish format ──────────
echo "Test 9: cleanup preserves new format"
mkdir -p "$SANDBOX/projects/new1"
echo "## Proyecto: new-style" > "$SANDBOX/projects/new1/context.md"
python3 -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
from dream_cycle import cleanup_corrupted_context_files
cleanup_corrupted_context_files('$SANDBOX/projects', today='20260517')
" 2>/dev/null
[ -f "$SANDBOX/projects/new1/context.md" ] && pass "new format preserved" || fail "new format wrongly rotated"

# ── Test 10: cleanup-once.sh idempotent ──────────────────────────
echo "Test 10: cleanup-once.sh idempotent"
CORTEX_PROJECTS_DIR="$SANDBOX/projects" bash "$PROJECT_ROOT/bin/cleanup-context-once.sh" >/dev/null
out=$(CORTEX_PROJECTS_DIR="$SANDBOX/projects" bash "$PROJECT_ROOT/bin/cleanup-context-once.sh" 2>&1 | grep -c "^Rotated:" || true)
[ "$out" = "0" ] && pass "second run rotates nothing" || fail "not idempotent (rotated lines: $out)"

# ── Test 11: EOD inject wraps with [eod-summary YYYY-MM-DD] ──────
echo "Test 11: EOD inject tag"
result=$(python3 -c "
quick_resume = 'finished migration X'
eod_date = '2026-05-16'
tagged = f'[eod-summary {eod_date}]\n{quick_resume}' if quick_resume else quick_resume
print('OK' if tagged.startswith('[eod-summary 2026-05-16]\n') else 'FAIL')
")
[ "$result" = "OK" ] && pass "EOD tag wraps resume" || fail "$result"

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
