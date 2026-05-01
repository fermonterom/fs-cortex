#!/usr/bin/env bash
# yaml_normalize.py tests — stdlib-only refactor (v3.23.2+)
# Verify: no PyYAML import, normalize_file detects+fixes bad double-quoted escapes,
# normalize_all skips already-clean files, idempotent, no false rewrites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB="$PROJECT_ROOT/hooks/lib"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== yaml_normalize.py tests (stdlib-only) ==="
echo ""

# --- Test 1: Module imports without PyYAML ---
echo "--- Test 1: stdlib-only import ---"
result=$(python3 -c "
import sys
sys.path.insert(0, '$LIB')
# Block PyYAML to prove the module does not need it
sys.modules['yaml'] = None
import yaml_normalize
print('OK' if hasattr(yaml_normalize, 'normalize_all') else 'FAIL')
" 2>&1)
[ "$result" = "OK" ] && pass "module imports cleanly without PyYAML" || fail "import: $result"

# --- Test 2: _has_broken_dq_line detects bad backslash escape ---
echo "--- Test 2: detects bad double-quoted escapes ---"
result=$(python3 -c "
import sys; sys.path.insert(0, '$LIB')
from yaml_normalize import _has_broken_dq_line
bad = 'id: x\ntrigger: \"Bash.*\\\\.env\"\n'
print('OK' if _has_broken_dq_line(bad) else 'FAIL')
")
[ "$result" = "OK" ] && pass "detects \\\\. inside double quotes on trigger key" || fail "detect-dq: $result"

# --- Test 3: _has_broken_dq_line ignores valid escapes ---
result=$(python3 -c "
import sys; sys.path.insert(0, '$LIB')
from yaml_normalize import _has_broken_dq_line
ok = 'id: x\ntrigger: \"plain text with \\n newline\"\n'
print('OK' if not _has_broken_dq_line(ok) else 'FAIL')
")
[ "$result" = "OK" ] && pass "ignores valid \\n escape" || fail "valid-escape: $result"

# --- Test 4: _has_broken_dq_line ignores non-REGEX_KEYS lines ---
result=$(python3 -c "
import sys; sys.path.insert(0, '$LIB')
from yaml_normalize import _has_broken_dq_line
# bad escape but key is 'evidence' (not in REGEX_KEYS) — must NOT trigger
not_regex_key = 'id: x\nevidence: \"raw \\\\. literal in evidence is fine\"\n'
print('OK' if not _has_broken_dq_line(not_regex_key) else 'FAIL')
")
[ "$result" = "OK" ] && pass "ignores bad escape on non-regex keys (evidence, id, etc.)" || fail "non-regex-key: $result"

# --- Test 5: normalize_file rewrites bad → single-quoted ---
echo "--- Test 5: normalize_file end-to-end ---"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/bad.yaml" <<'EOF'
---
id: gotcha-test-bad
trigger: "Bash.*\.env"
action: "Verify .env in .gitignore"
confidence: 0.7
---
EOF
result=$(python3 -c "
import sys; sys.path.insert(0, '$LIB')
from yaml_normalize import normalize_file
print('OK' if normalize_file('$SANDBOX/bad.yaml') else 'FAIL-no-change')
")
[ "$result" = "OK" ] && pass "rewrites file containing bad escape" || fail "rewrite: $result"
# Verify the rewrite used single quotes
if grep -q "trigger: 'Bash" "$SANDBOX/bad.yaml" && ! grep -q 'trigger: "Bash' "$SANDBOX/bad.yaml"; then
    pass "rewritten file uses single quotes for trigger"
else
    fail "rewritten file should use single quotes"
    cat "$SANDBOX/bad.yaml"
fi
rm -rf "$SANDBOX"

# --- Test 6: normalize_file idempotent on already-clean file ---
echo "--- Test 6: idempotent on clean file ---"
SANDBOX=$(mktemp -d)
cat > "$SANDBOX/clean.yaml" <<'EOF'
---
id: pattern-test-clean
trigger: 'Bash.*\.env'
action: 'Already single-quoted, do not touch'
confidence: 0.8
---
EOF
ORIG_HASH=$(shasum "$SANDBOX/clean.yaml" | cut -d' ' -f1)
result=$(python3 -c "
import sys; sys.path.insert(0, '$LIB')
from yaml_normalize import normalize_file
# Should return False (no changes needed)
r = normalize_file('$SANDBOX/clean.yaml')
print('OK' if r is False else 'FAIL-rewrote')
")
[ "$result" = "OK" ] && pass "returns False for already-clean file" || fail "idempotent-return: $result"
NEW_HASH=$(shasum "$SANDBOX/clean.yaml" | cut -d' ' -f1)
[ "$ORIG_HASH" = "$NEW_HASH" ] && pass "file unchanged on disk" || fail "file content changed unexpectedly"
rm -rf "$SANDBOX"

# --- Test 7: normalize_all skips clean dir, fixes broken files ---
echo "--- Test 7: normalize_all on sandbox CORTEX_DIR ---"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/instincts/global"
mkdir -p "$SANDBOX/projects/abc123/instincts"

cat > "$SANDBOX/instincts/global/clean.yaml" <<'EOF'
---
id: clean
trigger: 'Bash.*\.env'
---
EOF
cat > "$SANDBOX/instincts/global/broken.yaml" <<'EOF'
---
id: broken
trigger: "Bash.*\.env"
---
EOF
cat > "$SANDBOX/projects/abc123/instincts/proj_broken.yaml" <<'EOF'
---
id: proj_broken
action: "Use \. in regex"
---
EOF
result=$(CORTEX_DIR="$SANDBOX" python3 -c "
import sys; sys.path.insert(0, '$LIB')
from yaml_normalize import normalize_all
print(normalize_all())
")
[ "$result" = "2" ] && pass "normalize_all repaired exactly 2 files (1 global + 1 project)" || fail "normalize_all count: $result"
# Verify clean.yaml was NOT touched
if grep -q "trigger: 'Bash" "$SANDBOX/instincts/global/clean.yaml"; then
    pass "clean.yaml left unchanged"
else
    fail "clean.yaml should have remained untouched"
fi
rm -rf "$SANDBOX"

# --- Test 8: normalize_all skips archive subdirs ---
echo "--- Test 8: archive directories ignored ---"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/instincts/global/archive"
cat > "$SANDBOX/instincts/global/archive/old.yaml" <<'EOF'
---
id: old
trigger: "broken \. should stay broken in archive"
---
EOF
result=$(CORTEX_DIR="$SANDBOX" python3 -c "
import sys; sys.path.insert(0, '$LIB')
from yaml_normalize import normalize_all
print(normalize_all())
")
[ "$result" = "0" ] && pass "archive/ subdir not touched (count=0)" || fail "archive: $result"
rm -rf "$SANDBOX"

# --- Test 9: missing CORTEX_DIR returns 0 cleanly ---
echo "--- Test 9: missing dir is graceful ---"
result=$(CORTEX_DIR="/tmp/nonexistent-cortex-$$" python3 -c "
import sys; sys.path.insert(0, '$LIB')
from yaml_normalize import normalize_all
print(normalize_all())
")
[ "$result" = "0" ] && pass "missing dir returns 0" || fail "missing-dir: $result"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
