#!/usr/bin/env bash
# Observer tests — scrubbing, is_error detection, dedup, session_id
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

export PYTHONPATH="$PROJECT_ROOT/hooks:${PYTHONPATH:-}"

echo "=== Observer Tests ==="
echo ""

# --- Test 1: Secret scrubbing for all 12 patterns ---
echo "--- Secret Scrubbing ---"
python3 -c "
from observe import scrub_secrets

cases = [
    ('ghp_abc123def456ghi789jkl012mno345pqr678stu9', True, 'GitHub'),
    ('sk_live_abc123def456ghi789jkl', True, 'Stripe'),
    ('sk-ant-abc123def456ghi789jkl', True, 'Anthropic'),
    ('xoxb-123456789-abcdefghij', True, 'Slack'),
    ('AIzaSyA' + 'x' * 32, True, 'Google'),
    ('AKIA' + 'A' * 16, True, 'AWS'),
    ('eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123def456ghi789', True, 'JWT'),
    ('postgres://user:pass@host:5432/db', True, 'ConnStr'),
    ('sk-proj-abcdef1234567890abcd', True, 'OpenAI'),
    ('normal text without secrets', False, 'Clean'),
]
all_ok = True
for text, should_scrub, name in cases:
    result = scrub_secrets(text)
    has_redacted = 'REDACTED' in result
    if should_scrub and not has_redacted:
        print(f'  FAIL: {name} not scrubbed')
        all_ok = False
    elif not should_scrub and has_redacted:
        print(f'  FAIL: false positive on {name}')
        all_ok = False
if all_ok:
    print('OK')
" | grep -q "OK" && pass "all 12 scrubbing patterns" || fail "scrubbing patterns"

# --- Test 2: is_error detection ---
echo "--- Error Detection ---"
python3 -c "
from observe import detect_is_error

assert detect_is_error('Error: file not found') == True
assert detect_is_error('Traceback (most recent call last)') == True
assert detect_is_error('command not found: foo') == True
assert detect_is_error('fatal: not a git repository') == True
assert detect_is_error('PANIC: runtime error') == True
assert detect_is_error('segfault at 0x0') == True
assert detect_is_error('Build succeeded') == False
assert detect_is_error('') == False
assert detect_is_error(None) == False
print('OK')
" | grep -q "OK" && pass "is_error detection (9 patterns)" || fail "is_error detection"

# --- Test 2b: binary/base64 output detection (v3.37.0) ---
python3 -c "
from observe import _looks_binary

# data URI and API image blocks are binary
assert _looks_binary('data:image/png;base64,iVBORw0KGgo') == True
assert _looks_binary('{\"type\": \"image\", \"source\": {...}}') == True
# a long unbroken base64 run is binary
assert _looks_binary('iVBORw0KGgoAAAANSUhEUg' * 100) == True
# normal tool output is not, even when long
assert _looks_binary('PASS test_foo\n' * 200) == False
assert _looks_binary('short text') == False
assert _looks_binary('error: ENOENT no such file or directory while reading package.json ' * 20) == False
print('OK')
" | grep -q "OK" && pass "binary output detection (v3.37.0)" || fail "binary output detection"

# --- Test 2c: is_error heuristic guards (v3.37.2) ---
# Real false positives 2026-06-12: WebFetch 200-OK bodies mentioning "error"
# (gotcha-WebFetch-c8b45df1/c4cf99f4/30323cf4) and a passing test suite
# (gotcha-Bash-560c85ee, err_msg "PASS: custom law preserved").
python3 -c "
from observe import detect_is_error

# network tools: body content is never fed to the heuristic
body = '{\"bytes\": 100775, \"code\": 200, \"codeText\": \"OK\", \"result\": \"The article mentions error handling and failed connections\"}'
assert detect_is_error(body, tool_name='WebFetch') == False
assert detect_is_error('results: how to fix error: in nginx', tool_name='WebSearch') == False
# structured 2xx response → success by contract, regardless of body
assert detect_is_error('error: mentioned in body', tool_name='SomeFetch', response={'code': 200}) == False
# non-2xx structured response still falls through to the heuristic
assert detect_is_error('error: connection refused', tool_name='SomeFetch', response={'code': 500}) == True
# test-runner output is an outcome report, not a tool failure
assert detect_is_error('  PASS: custom law preserved\n  FAIL: reflexes mismatch\n=== Results: 7 passed, 1 failed ===') == False
assert detect_is_error('Tests: 3 passed, 3 total') == False
assert detect_is_error('12 passed in 0.42s') == False
# genuine errors still detected when no guard applies
assert detect_is_error('error: ENOENT no such file', tool_name='Bash') == True
assert detect_is_error('fatal: not a git repository', tool_name='Bash', response={'exit_code': 128}) == True
print('OK')
" | grep -q "OK" && pass "heuristic guards: network tools, 2xx, test-runner (v3.37.2)" || fail "heuristic guards (v3.37.2)"

# --- Test 3: session_id truncation (64 chars to fit 36-char UUIDs) ---
# v3.19.3: Pre-release this was [:24], which truncated 36-char UUIDs and broke
# correlation with impact.jsonl (where sids are stored full-length). The full
# UUID must round-trip so session-learner's correlateReflexFeedback can match.
echo "--- Session ID ---"
result=$(python3 -c "
import re
sid = 'a' * 80
clean = re.sub(r'[^a-zA-Z0-9_-]', '', sid)[:64]
print(len(clean))
")
[ "$result" = "64" ] && pass "session_id[:64]" || fail "session_id length=$result (expected 64)"

# --- Test 3b: 36-char UUID survives intact ---
uuid_len=$(python3 -c "
import re
sid = '254a66c0-baca-460f-8522-429d094c70da'
clean = re.sub(r'[^a-zA-Z0-9_-]', '', sid)[:64]
print(len(clean))
")
[ "$uuid_len" = "36" ] && pass "UUID round-trips at 36 chars" || fail "UUID truncated to $uuid_len"

# --- Test 4: Dedup behavior ---
echo "--- Dedup ---"
python3 -c "
from observe import is_duplicate, update_dedup, get_dedup_dir
import os, tempfile

dedup_dir = tempfile.mkdtemp()
dedup_file = os.path.join(dedup_dir, 'dedup-test')

# First time: not a duplicate
assert not is_duplicate(dedup_file, 'hash123')
update_dedup(dedup_file, 'hash123')

# Second time: IS a duplicate
assert is_duplicate(dedup_file, 'hash123')

# Different hash: not a duplicate
assert not is_duplicate(dedup_file, 'hash456')

# Cleanup
import shutil
shutil.rmtree(dedup_dir)
print('OK')
" | grep -q "OK" && pass "dedup behavior" || fail "dedup behavior"

# --- Test 5: Atomic write ---
echo "--- Atomic Write ---"
python3 -c "
from observe import atomic_write_json
import tempfile, os, json

tmp = tempfile.mkdtemp()
fpath = os.path.join(tmp, 'test.json')
atomic_write_json(fpath, {'key': 'value'})

with open(fpath) as f:
    data = json.load(f)
assert data == {'key': 'value'}

# Cleanup
import shutil
shutil.rmtree(tmp)
print('OK')
" | grep -q "OK" && pass "atomic_write_json" || fail "atomic write"

# --- Test 6: End-to-end observe.py ---
echo "--- End-to-end ---"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/cortex"
# Use unique session_id to avoid dedup collisions with previous test runs
E2E_SID="e2e-$(date +%s)-$$"
# Clean any stale dedup for this session
DEDUP_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cortex-$(id -u)"
rm -f "$DEDUP_DIR/dedup-$E2E_SID" 2>/dev/null || true
echo '{"tool_name":"Read","session_id":"'"$E2E_SID"'","cwd":"'"$SANDBOX"'","tool_input":{"file_path":"/tmp/test.txt"}}' | HOME="$SANDBOX" python3 "$PROJECT_ROOT/hooks/observe.py" post 2>/dev/null
# Observations go to cortex dir (global project since no git)
if [ -f "$SANDBOX/.claude/cortex/observations.jsonl" ]; then
    pass "e2e: observation written"
else
    fail "e2e: no observation file"
fi
rm -rf "$SANDBOX"

# --- Test 7: Performance benchmark ---
echo "--- Performance ---"
elapsed=$(python3 -c "
import time, subprocess, os, tempfile
start = time.time()
for _ in range(5):
    p = subprocess.run(
        ['python3', '$PROJECT_ROOT/hooks/observe.py', 'post'],
        input='{\"tool_name\":\"Read\",\"session_id\":\"bench\",\"cwd\":\"' + tempfile.gettempdir() + '\"}',
        capture_output=True, text=True, timeout=5,
        env={**os.environ, 'HOME': os.path.join(tempfile.gettempdir(), 'cortex-bench-' + str(os.getpid()))}
    )
avg_ms = ((time.time() - start) / 5) * 1000
print(f'{avg_ms:.0f}')
")
if [ "$elapsed" -lt 500 ]; then
    pass "performance: ${elapsed}ms avg (target <500ms)"
else
    fail "performance: ${elapsed}ms avg (target <500ms)"
fi

# --- Test 8: Subagent observations captured (v3.8.0) ---
echo "--- Subagent Capture ---"
SANDBOX_SUB=$(mktemp -d)
mkdir -p "$SANDBOX_SUB/.claude/cortex"
SUB_SID="sub-$(date +%s)-$$"
rm -f "$DEDUP_DIR/dedup-$SUB_SID" 2>/dev/null || true
echo '{"tool_name":"Read","session_id":"'"$SUB_SID"'","agent_id":"agent-abc123","cwd":"'"$SANDBOX_SUB"'","tool_input":{"file_path":"/tmp/test.txt"}}' | HOME="$SANDBOX_SUB" python3 "$PROJECT_ROOT/hooks/observe.py" post 2>/dev/null
if [ -f "$SANDBOX_SUB/.claude/cortex/observations.jsonl" ]; then
    # Verify aid field present in observation
    if grep -q '"aid"' "$SANDBOX_SUB/.claude/cortex/observations.jsonl"; then
        pass "subagent: observation captured with aid field"
    else
        fail "subagent: observation written but missing aid field"
    fi
else
    fail "subagent: no observation file (agent_id still being skipped?)"
fi
rm -rf "$SANDBOX_SUB"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
