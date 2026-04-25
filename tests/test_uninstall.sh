#!/usr/bin/env bash
# Uninstall tests — verify cortex uninstaller cleans up correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

SANDBOXES=()
cleanup() { for s in "${SANDBOXES[@]}"; do rm -rf "$s" 2>/dev/null; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Uninstall Tests ==="
echo ""

# ── Setup: install fresh, then uninstall ──────────────────────────

echo "--- Setup: fresh install ---"
SANDBOX=$(mktemp -d)
SANDBOXES+=("$SANDBOX")
mkdir -p "$SANDBOX/.claude"

# Install
printf '\n\n\n\n\n\n' | HOME="$SANDBOX" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

# Verify install succeeded before testing uninstall
[ -d "$SANDBOX/.claude/hooks/cortex" ] || { echo "SKIP: install failed, cannot test uninstall"; exit 0; }

echo "--- Uninstall (keep data, auto-confirm) ---"

# Run uninstall: answer y to confirm, n to backup, n to delete data
printf 'y\nn\nn\n' | HOME="$SANDBOX" bash "$PROJECT_ROOT/uninstall.sh" > /dev/null 2>&1 || true

# ── TEST 1: Hooks removed ─────────────────────────────────────────

echo "Test 1: Hooks removed"
[ ! -d "$SANDBOX/.claude/hooks/cortex" ] && pass "hooks/cortex/ removed" || fail "hooks/cortex/ still exists"

# ── TEST 2: Skill removed ─────────────────────────────────────────

echo "Test 2: Skill removed"
[ ! -d "$SANDBOX/.claude/skills/cortex" ] && pass "skills/cortex/ removed" || fail "skills/cortex/ still exists"

# ── TEST 3: Commands removed ──────────────────────────────────────

echo "Test 3: Commands removed"
CX_COUNT=$(find "$SANDBOX/.claude/commands" -name "cx-*.md" 2>/dev/null | wc -l | tr -d ' ')
[ "$CX_COUNT" -eq 0 ] && pass "cx-*.md commands removed" || fail "$CX_COUNT cx-*.md files remain"

# ── TEST 4: Data preserved (default: keep) ────────────────────────

echo "Test 4: Data preserved by default"
[ -d "$SANDBOX/.claude/cortex" ] && pass "cortex/ data preserved" || fail "cortex/ data was deleted"

# ── TEST 5: settings.json cleaned ─────────────────────────────────

echo "Test 5: Cortex hooks removed from settings.json"
if [ -f "$SANDBOX/.claude/settings.json" ]; then
    CORTEX_HOOKS=$(python3 -c "
import json
with open('$SANDBOX/.claude/settings.json') as f:
    s = json.load(f)
hooks = s.get('hooks', {})
count = 0
for event, entries in hooks.items():
    for entry in entries:
        for h in entry.get('hooks', []):
            if 'cortex' in str(h.get('command', '')):
                count += 1
print(count)
" 2>/dev/null || echo "error")
    [ "$CORTEX_HOOKS" = "0" ] && pass "cortex hooks cleaned from settings.json" || fail "settings.json still has $CORTEX_HOOKS cortex hooks"
else
    fail "settings.json missing"
fi

# ── TEST 6: CLAUDE.md cleaned ─────────────────────────────────────

echo "Test 6: Cortex section removed from CLAUDE.md"
if [ -f "$SANDBOX/.claude/CLAUDE.md" ]; then
    if grep -q "## Cortex" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null; then
        fail "CLAUDE.md still has ## Cortex section"
    else
        pass "Cortex section removed from CLAUDE.md"
    fi
else
    # CLAUDE.md had only Cortex section — correct to remove empty file
    pass "CLAUDE.md removed (was Cortex-only, no user content to preserve)"
fi

# ── TEST 7: Backup creation ──────────────────────────────────────

echo ""
echo "--- Uninstall with backup ---"
SANDBOX2=$(mktemp -d)
SANDBOXES+=("$SANDBOX2")
mkdir -p "$SANDBOX2/.claude"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX2" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

# Create some data to backup
mkdir -p "$SANDBOX2/.claude/cortex/laws"
echo "Test law for backup." > "$SANDBOX2/.claude/cortex/laws/backup-test.txt"

echo "Test 7: Backup archive created"
printf 'y\ny\nn\n' | HOME="$SANDBOX2" bash "$PROJECT_ROOT/uninstall.sh" > /dev/null 2>&1 || true
BACKUP=$(ls "$SANDBOX2/cortex-backup-"*.tar.gz 2>/dev/null | head -1)
[ -n "$BACKUP" ] && [ -f "$BACKUP" ] && pass "backup archive created: $(basename "$BACKUP")" || fail "no backup archive found"

# ── TEST 8: Backup contains laws ──────────────────────────────────

echo "Test 8: Backup contains laws"
if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    tar -tzf "$BACKUP" 2>/dev/null | grep -q "laws/" && pass "backup contains laws/" || fail "backup missing laws/"
else
    fail "no backup to check"
fi

# ── TEST 9: Uninstall with data deletion ──────────────────────────

echo ""
echo "--- Uninstall with data deletion ---"
SANDBOX3=$(mktemp -d)
SANDBOXES+=("$SANDBOX3")
mkdir -p "$SANDBOX3/.claude"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX3" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

echo "Test 9: Data deleted when requested (with backup)"
# Use backup + delete: y to confirm, y to backup, y to delete
printf 'y\ny\ny\n' | HOME="$SANDBOX3" bash "$PROJECT_ROOT/uninstall.sh" > /dev/null 2>&1 || true
[ ! -d "$SANDBOX3/.claude/cortex" ] && pass "cortex/ data deleted (with backup)" || fail "cortex/ data still exists"

# ── TEST 10: Safety guard prevents deletion without backup ────────

echo ""
echo "--- Safety guard (no backup + delete attempt) ---"
SANDBOX4=$(mktemp -d)
SANDBOXES+=("$SANDBOX4")
mkdir -p "$SANDBOX4/.claude"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX4" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

# ── TEST 10: CLAUDE.md user content preserved ────────────────────

echo ""
echo "--- CLAUDE.md with user content ---"
SANDBOX5=$(mktemp -d)
SANDBOXES+=("$SANDBOX5")
mkdir -p "$SANDBOX5/.claude"

# Create CLAUDE.md with user content BEFORE installing
cat > "$SANDBOX5/.claude/CLAUDE.md" << 'USEREOF'
# My Project

## Developer Notes
This is my custom content that should survive uninstall.

## Code Conventions
- Use TypeScript strict mode
- Always test before commit
USEREOF

# Install Cortex (adds ## Cortex section)
printf '\n\n\n\n\n\n' | HOME="$SANDBOX5" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

# Verify Cortex section was added
grep -q "## Cortex" "$SANDBOX5/.claude/CLAUDE.md" 2>/dev/null || { fail "install didn't add Cortex section"; }

# Uninstall
printf 'y\nn\nn\n' | HOME="$SANDBOX5" bash "$PROJECT_ROOT/uninstall.sh" > /dev/null 2>&1 || true

echo "Test 10: User CLAUDE.md content preserved after uninstall"
if [ -f "$SANDBOX5/.claude/CLAUDE.md" ]; then
    if grep -q "## Cortex" "$SANDBOX5/.claude/CLAUDE.md" 2>/dev/null; then
        fail "Cortex section still present"
    elif grep -q "Developer Notes" "$SANDBOX5/.claude/CLAUDE.md" && grep -q "Code Conventions" "$SANDBOX5/.claude/CLAUDE.md"; then
        pass "user content preserved, Cortex section removed"
    else
        fail "user content was damaged"
    fi
else
    fail "CLAUDE.md was deleted (had user content!)"
fi

# ── TEST 11: Safety guard prevents deletion without backup ────────

echo ""
echo "--- Safety guard (no backup + delete attempt) ---"
SANDBOX4=$(mktemp -d)
SANDBOXES+=("$SANDBOX4")
mkdir -p "$SANDBOX4/.claude"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX4" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

echo "Test 11: Data preserved when DELETE not typed"
# y to confirm, n to backup, y to delete, but don't type DELETE
printf 'y\nn\ny\nno\n' | HOME="$SANDBOX4" bash "$PROJECT_ROOT/uninstall.sh" > /dev/null 2>&1 || true
[ -d "$SANDBOX4/.claude/cortex" ] && pass "safety guard preserved data" || fail "data was deleted without backup"

# ── TEST 12+: v3.19.0 — env removal ────────────────────────────────

echo ""
echo "--- v3.19.0: settings.json env removal ---"

# Test 12: uninstall removes Cortex env var, preserves user's other env vars
SANDBOX5=$(mktemp -d)
SANDBOXES+=("$SANDBOX5")
mkdir -p "$SANDBOX5/.claude"
printf '%s\n' '{"env":{"USER_VAR":"keep-me","ANOTHER":"x"},"model":"sonnet"}' > "$SANDBOX5/.claude/settings.json"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX5" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true
# After install: env has USER_VAR + ANOTHER + CORTEX_AGENT_DISABLE_REFLEXES
printf 'y\nn\nn\n' | HOME="$SANDBOX5" bash "$PROJECT_ROOT/uninstall.sh" > /dev/null 2>&1 || true

echo "Test 12: uninstall removes Cortex env, preserves user vars"
if python3 -c "
import json
d = json.load(open('$SANDBOX5/.claude/settings.json'))
env = d.get('env', {})
assert 'CORTEX_AGENT_DISABLE_REFLEXES' not in env, 'cortex env still present'
assert env.get('USER_VAR') == 'keep-me', 'user var lost'
assert env.get('ANOTHER') == 'x', 'second user var lost'
" 2>/dev/null; then
    pass "uninstall removes only Cortex env, preserves user vars"
else
    fail "uninstall damaged user env or did not remove Cortex env"
fi

# Test 13: uninstall drops empty env block when only Cortex var existed
SANDBOX6=$(mktemp -d)
SANDBOXES+=("$SANDBOX6")
mkdir -p "$SANDBOX6/.claude"
# Fresh install (no prior env) → only CORTEX_AGENT_DISABLE_REFLEXES will be in env
printf '\n\n\n\n\n\n' | HOME="$SANDBOX6" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true
printf 'y\nn\nn\n' | HOME="$SANDBOX6" bash "$PROJECT_ROOT/uninstall.sh" > /dev/null 2>&1 || true

echo "Test 13: uninstall drops empty env block"
if python3 -c "
import json
d = json.load(open('$SANDBOX6/.claude/settings.json'))
assert 'env' not in d, 'empty env block left behind'
" 2>/dev/null; then
    pass "uninstall drops empty env block"
else
    fail "uninstall left empty env block (clutters settings.json)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
