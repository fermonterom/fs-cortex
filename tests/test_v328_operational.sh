#!/usr/bin/env bash
# Tests for v3.28.0 operational tools: cx-stop, cx-analyze --deep, daily snapshot
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export CORTEX_DIR="$SANDBOX"
mkdir -p "$SANDBOX/projects/test-proj/instincts" \
         "$SANDBOX/instincts/global" \
         "$SANDBOX/laws" \
         "$SANDBOX/daily-snapshots"

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local script="$2"
  if python3 -c "$script" >/dev/null 2>&1; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    python3 -c "$script" 2>&1 | head -10
    FAIL=$((FAIL + 1))
  fi
}

run_test_bash() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    eval "$cmd" 2>&1 | head -5
    FAIL=$((FAIL + 1))
  fi
}

# Helper: load session-start module using importlib (filename has hyphen)
SS_LOADER="
import importlib.util, sys, os
os.environ['CORTEX_DIR'] = '$SANDBOX'
spec = importlib.util.spec_from_file_location('session_start', '$REPO_ROOT/hooks/session-start.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
"

echo "=== test_v328_operational.sh ==="

# ── write_daily_snapshot ────────────────────────────────────────────────────

run_test "snapshot: creates JSON with correct fields" "
$SS_LOADER
import json, pathlib
# Setup: proposals.json, observations.jsonl, instinct yamls, law txt
pathlib.Path('$SANDBOX/proposals.json').write_text('[{\"id\":\"a\"},{\"id\":\"b\"}]')
# Mix of obs on the snapshot date (2 lines) and other dates (1 line)
pathlib.Path('$SANDBOX/projects/test-proj/observations.jsonl').write_text(
    '{\"ts\":\"2026-05-08T10:00\"}\n'
    '{\"ts\":\"2026-05-08T11:00\"}\n'
    '{\"ts\":\"2026-05-07T09:00\"}\n'
)
pathlib.Path('$SANDBOX/instincts/global/foo.yaml').touch()
pathlib.Path('$SANDBOX/instincts/global/bar.yaml').touch()
pathlib.Path('$SANDBOX/projects/test-proj/instincts/baz.yaml').touch()
pathlib.Path('$SANDBOX/laws/law1.txt').write_text('Law one')
mod.write_daily_snapshot('2026-05-08')
p = pathlib.Path('$SANDBOX/daily-snapshots/2026-05-08.json')
assert p.exists(), 'snapshot file not created'
d = json.loads(p.read_text())
assert d['date'] == '2026-05-08', f'date: {d[\"date\"]}'
assert d['proposals_count'] == 2, f'proposals_count: {d[\"proposals_count\"]}'
assert d['instincts_global'] == 2, f'instincts_global: {d[\"instincts_global\"]}'
assert d['instincts_project_total'] == 1, f'instincts_project_total: {d[\"instincts_project_total\"]}'
assert d['laws_count'] == 1, f'laws_count: {d[\"laws_count\"]}'
# v3.28.5 — split observations into total_active vs on_date
assert 'test-proj' in d['observations_total_active'], 'test-proj missing total_active'
assert d['observations_total_active']['test-proj'] == 3, f'total_active: {d[\"observations_total_active\"][\"test-proj\"]}'
assert d['observations_on_date']['test-proj'] == 2, f'on_date (filtered by 2026-05-08): {d[\"observations_on_date\"][\"test-proj\"]}'
"

run_test "snapshot: idempotent (does not overwrite existing)" "
$SS_LOADER
import json, pathlib
snap = pathlib.Path('$SANDBOX/daily-snapshots/2026-05-07.json')
snap.write_text('{\"marker\": \"original\"}')
mod.write_daily_snapshot('2026-05-07')
d = json.loads(snap.read_text())
assert d.get('marker') == 'original', f'snapshot was overwritten: {d}'
"

run_test "snapshot: graceful when CORTEX_DIR has no subdirs" "
$SS_LOADER
import pathlib
# fresh dir with no projects/instincts/laws
fresh = pathlib.Path('$SANDBOX') / 'empty-snap'
fresh.mkdir()
import os
os.environ['CORTEX_DIR'] = str(fresh)
# reload module with new CORTEX_DIR
spec2 = importlib.util.spec_from_file_location('session_start2', '$REPO_ROOT/hooks/session-start.py')
mod2 = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(mod2)
mod2.write_daily_snapshot('2026-05-06')  # Should not raise
"

# ── cx-stop (session-learner.js runs cleanly) ───────────────────────────────

run_test_bash "cx-stop: session-learner exits 0 with empty stdin" \
  "printf '{}\n' | node '$REPO_ROOT/hooks/session-learner.js'"

# ── cx-analyze --deep (archive directory handling) ──────────────────────────

run_test "cx-analyze --deep: archive dir spec is readable" "
# Verify the --deep section exists in cx-analyze.md
content = open('$REPO_ROOT/commands/cx-analyze.md').read()
assert '--deep' in content, '--deep flag missing from cx-analyze.md'
assert 'observations.archive' in content, 'observations.archive missing from spec'
"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
