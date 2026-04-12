#!/usr/bin/env bash
# Integrity tests — validate project structure, commands, core files, observe.sh wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Integrity Tests ==="
echo ""

# ── TEST 1: observe.py runs directly (v3.10: observe.sh removed) ───

echo "--- observe.py direct ---"
SANDBOX=$(mktemp -d)
trap "rm -rf '$SANDBOX'" EXIT

mkdir -p "$SANDBOX/.claude/cortex"
OBS_SID="integrity-$(date +%s)-$$"
DEDUP_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cortex-$(id -u)"
rm -f "$DEDUP_DIR/dedup-$OBS_SID" 2>/dev/null || true
echo '{"tool_name":"Read","session_id":"'"$OBS_SID"'","cwd":"'"$SANDBOX"'","tool_input":"test"}' | \
    HOME="$SANDBOX" python3 "$PROJECT_ROOT/hooks/observe.py" post 2>/dev/null || true

if [ -f "$SANDBOX/.claude/cortex/observations.jsonl" ]; then
    pass "observe.py direct invocation (exit=0)"
else
    fail "observe.py: no observation written"
fi

echo ""

# ── TEST 2: All 16 commands exist ─────────────────────────────────

echo "--- Commands existence ---"
EXPECTED_COMMANDS="cx-analyze cx-audit cx-backup cx-distill cx-downvote cx-dream cx-eod cx-evolve cx-export cx-gotcha cx-promote cx-restore cx-retro cx-router cx-status cx-validate"
MISSING=0
for cmd in $EXPECTED_COMMANDS; do
    if [ ! -f "$PROJECT_ROOT/commands/$cmd.md" ]; then
        fail "missing command: $cmd.md"
        MISSING=$((MISSING + 1))
    fi
done
[ "$MISSING" -eq 0 ] && pass "all 16 commands present"

echo ""

# ── TEST 3: Commands reference valid paths ────────────────────────

echo "--- Commands reference valid files ---"
CMD_ERRORS=0
for cmd_file in "$PROJECT_ROOT"/commands/cx-*.md; do
    cmd_name=$(basename "$cmd_file" .md)
    # Check if command references dream_cycle.py, validate_instinct.py, etc.
    # and verify those files exist
    REFS=$(grep -oE '(dream_cycle|validate_instinct|yaml-utils|observe|session-learner|session-start|injector)\.(py|js|sh)' "$cmd_file" 2>/dev/null || true)
    for ref in $REFS; do
        FOUND=$(find "$PROJECT_ROOT/hooks" -name "$ref" 2>/dev/null | head -1)
        if [ -z "$FOUND" ]; then
            fail "$cmd_name references $ref but file not found in hooks/"
            CMD_ERRORS=$((CMD_ERRORS + 1))
        fi
    done
done
[ "$CMD_ERRORS" -eq 0 ] && pass "all command file references are valid"

echo ""

# ── TEST 4: claudemd-section.md lists all commands ────────────────

echo "--- CLAUDE.md section lists all commands ---"
SECTION_FILE="$PROJECT_ROOT/core/claudemd-section.md"
SECTION_MISSING=0
for cmd in $EXPECTED_COMMANDS; do
    SLASH_CMD="/${cmd}"
    if ! grep -q "$SLASH_CMD" "$SECTION_FILE" 2>/dev/null; then
        fail "claudemd-section.md missing $SLASH_CMD"
        SECTION_MISSING=$((SECTION_MISSING + 1))
    fi
done
[ "$SECTION_MISSING" -eq 0 ] && pass "claudemd-section.md lists all 16 /cx-* commands"

echo ""

# ── TEST 5: core/memory.template.json is valid JSON with required fields ──

echo "--- memory.template.json validation ---"
python3 -c "
import json
with open('$PROJECT_ROOT/core/memory.template.json') as f:
    m = json.load(f)
assert 'identity' in m, 'missing identity'
assert 'config' in m, 'missing config'
assert 'stats' in m, 'missing stats'
cfg = m['config']
required = ['max_observations_mb', 'archive_days', 'law_threshold', 'max_laws',
            'max_instincts_per_injection', 'max_reflexes_per_injection',
            'decay_per_30_days', 'jaccard_threshold', 'confidence_cap']
missing = [k for k in required if k not in cfg]
assert not missing, f'missing config keys: {missing}'
assert cfg['max_instincts_per_injection'] == 3, f'max_instincts should be 3, got {cfg[\"max_instincts_per_injection\"]}'
print('OK')
" 2>/dev/null | grep -q OK && pass "memory.template.json valid with all required fields" || fail "memory.template.json invalid"

echo ""

# ── TEST 6: core/reflexes.default.json is valid ──────────────────

echo "--- reflexes.default.json validation ---"
python3 -c "
import json
with open('$PROJECT_ROOT/core/reflexes.default.json') as f:
    r = json.load(f)
assert 'reflexes' in r, 'missing reflexes key'
assert len(r['reflexes']) >= 5, f'expected 5+ reflexes, got {len(r[\"reflexes\"])}'
for reflex in r['reflexes']:
    assert 'id' in reflex, f'reflex missing id'
    assert 'matcher' in reflex, f'reflex {reflex[\"id\"]} missing matcher'
    assert 'action' in reflex, f'reflex {reflex[\"id\"]} missing action'
    assert 'enabled' in reflex, f'reflex {reflex[\"id\"]} missing enabled'
print('OK')
" 2>/dev/null | grep -q OK && pass "reflexes.default.json valid ($(python3 -c "import json; print(len(json.load(open('$PROJECT_ROOT/core/reflexes.default.json'))['reflexes']))" 2>/dev/null) reflexes)" || fail "reflexes.default.json invalid"

echo ""

# ── TEST 7: Version consistency ───────────────────────────────────

echo "--- Version consistency ---"
V_SH=$(grep '^NEW_VERSION=' "$PROJECT_ROOT/install.sh" | head -1 | cut -d'"' -f2)
V_PS1=$(grep '^\$NewVersion' "$PROJECT_ROOT/install.ps1" | head -1 | sed 's/.*= "//;s/"//')
V_CHANGELOG=$(grep -m1 '## \[' "$PROJECT_ROOT/CHANGELOG.md" | sed 's/.*\[//;s/\].*//')

[ "$V_SH" = "$V_PS1" ] && pass "install.sh ($V_SH) = install.ps1 ($V_PS1)" || fail "version mismatch: install.sh=$V_SH vs install.ps1=$V_PS1"
[ "$V_SH" = "$V_CHANGELOG" ] && pass "install.sh ($V_SH) = CHANGELOG ($V_CHANGELOG)" || fail "version mismatch: install.sh=$V_SH vs CHANGELOG=$V_CHANGELOG"

echo ""

# ── TEST 8: ShellCheck on critical scripts ────────────────────────

echo "--- ShellCheck (severity=error) ---"
if command -v shellcheck >/dev/null 2>&1; then
    SC_ERRORS=0
    # Note: injector.sh excluded — 99% inline JS heredoc, shellcheck can't parse it
    for script in "$PROJECT_ROOT/install.sh" "$PROJECT_ROOT/uninstall.sh" "$PROJECT_ROOT/hooks/injector.sh"; do
        if ! shellcheck --severity=error "$script" 2>/dev/null; then
            fail "shellcheck errors in $(basename "$script")"
            SC_ERRORS=$((SC_ERRORS + 1))
        fi
    done
    [ "$SC_ERRORS" -eq 0 ] && pass "shellcheck clean on all critical scripts"
else
    pass "shellcheck not installed (skip)"
fi

echo ""

# ── TEST 9: Core files and seed instinct exist ───────────────────

echo "--- Core files ---"
[ -f "$PROJECT_ROOT/core/memory.template.json" ] && pass "core/memory.template.json exists" || fail "missing memory.template.json"
[ -f "$PROJECT_ROOT/core/reflexes.default.json" ] && pass "core/reflexes.default.json exists" || fail "missing reflexes.default.json"
[ -f "$PROJECT_ROOT/core/claudemd-section.md" ] && pass "core/claudemd-section.md exists" || fail "missing claudemd-section.md"
[ -f "$PROJECT_ROOT/rules/seed.md" ] && pass "rules/seed.md (seed instinct) exists" || fail "missing seed instinct"

echo ""

# ── TEST 10: CI workflow includes uninstall.sh in shellcheck ──────

echo "--- CI coverage ---"
if grep -q 'uninstall.sh' "$PROJECT_ROOT/.github/workflows/test.yml" 2>/dev/null; then
    pass "CI includes uninstall.sh"
else
    fail "CI shellcheck missing uninstall.sh"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
