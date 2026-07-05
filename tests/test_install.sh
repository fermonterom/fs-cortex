#!/usr/bin/env bash
# Installation tests — fresh install + upgrade simulation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

# Track sandboxes for cleanup on failure
SANDBOXES=()
cleanup() { for s in "${SANDBOXES[@]}"; do rm -rf "$s" 2>/dev/null; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== Installation Tests ==="
echo ""

# ── TEST 1: Fresh install ──────────────────────────────────────────

echo "--- Fresh Install ---"
SANDBOX=$(mktemp -d)
SANDBOXES+=("$SANDBOX")
mkdir -p "$SANDBOX/.claude"

# Run installer (auto-answer prompts with empty input)
printf '\n\n\n\n\n\n' | HOME="$SANDBOX" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

# 1a: Version file created
[ -f "$SANDBOX/.claude/cortex/version" ] && pass "version file created" || fail "no version file"

# 1b: Version content matches
VER=$(cat "$SANDBOX/.claude/cortex/version" 2>/dev/null | tr -d '[:space:]')
grep -q "NEW_VERSION=\"$VER\"" "$PROJECT_ROOT/install.sh" && pass "version matches install.sh ($VER)" || fail "version mismatch: $VER"

# 1c: All hooks installed
for hook in observe.py injector.sh session-start.py session-learner.js; do
    [ -f "$SANDBOX/.claude/hooks/cortex/$hook" ] && pass "hook: $hook installed" || fail "hook: $hook MISSING"
done

# 1d: Python lib modules installed
for lib in dream_cycle.py validate_instinct.py cortex_utils.py yaml-utils.js injector-engine.js; do
    [ -f "$SANDBOX/.claude/hooks/cortex/lib/$lib" ] && pass "lib: $lib installed" || fail "lib: $lib MISSING"
done

# 1e: All 25 commands installed (v4 DESIGN-V4.md §5 added /cx-maintain +
# /cx-review on top of the 22 pre-v4 commands; v4.4.0 added /cx-curate;
# the other 17 became deprecation stubs rather than being deleted).
CMD_COUNT=$(ls "$SANDBOX/.claude/commands/cx-"*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$CMD_COUNT" -eq 25 ] && pass "25 commands installed" || fail "commands: $CMD_COUNT (expected 25)"

# 1f: SKILL.md installed
[ -f "$SANDBOX/.claude/skills/cortex/SKILL.md" ] && pass "SKILL.md installed" || fail "SKILL.md MISSING"

# 1g: CLAUDE.md created with Cortex section
grep -q "## Cortex (Learning System)" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null && pass "CLAUDE.md has Cortex section" || fail "CLAUDE.md missing Cortex section"

# 1h: v4 active set advertised in CLAUDE.md (v4.4.0 — legacy names like
# cx-dream are deprecation stubs and no longer advertised in the section)
grep -q "cx-curate" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null && pass "CLAUDE.md lists cx-curate" || fail "CLAUDE.md missing cx-curate"

# 1i: settings.json has cortex hooks
grep -q "hooks/cortex/" "$SANDBOX/.claude/settings.json" 2>/dev/null && pass "settings.json has cortex hooks" || fail "settings.json missing hooks"

# 1j: Core files created
[ -f "$SANDBOX/.claude/cortex/memory.json" ] && pass "memory.json created" || fail "memory.json MISSING"
[ -f "$SANDBOX/.claude/cortex/reflexes.json" ] && pass "reflexes.json created" || fail "reflexes.json MISSING"

# 1k: Seed laws installed
LAW_COUNT=$(ls "$SANDBOX/.claude/cortex/laws/"*.txt 2>/dev/null | wc -l | tr -d ' ')
[ "$LAW_COUNT" -ge 1 ] && pass "seed laws installed ($LAW_COUNT)" || fail "no seed laws"

# 1l: Seed instincts installed
INST_COUNT=$(ls "$SANDBOX/.claude/cortex/instincts/global/"*.yaml 2>/dev/null | wc -l | tr -d ' ')
[ "$INST_COUNT" -ge 1 ] && pass "seed instincts installed ($INST_COUNT)" || fail "no seed instincts"

# 1m: Directory structure
for dir in laws instincts/global instincts/archive projects evolved/skills evolved/commands evolved/rules exports daily-summaries log; do
    [ -d "$SANDBOX/.claude/cortex/$dir" ] || { fail "dir missing: $dir"; break; }
done
pass "directory structure complete"

rm -rf "$SANDBOX"
echo ""

# ── TEST 2: Upgrade install ────────────────────────────────────────

echo "--- Upgrade Install ---"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/cortex/laws" "$SANDBOX/.claude/cortex/instincts/global" \
         "$SANDBOX/.claude/cortex/projects/test123" "$SANDBOX/.claude/hooks/cortex"

# Simulate existing v3.0.0 installation
echo "3.0.0" > "$SANDBOX/.claude/cortex/version"
echo "My custom law content" > "$SANDBOX/.claude/cortex/laws/custom-law.txt"
cat > "$SANDBOX/.claude/cortex/instincts/global/my-instinct.yaml" << 'YAML'
---
id: my-instinct
trigger: Bash
action: Always run tests
confidence: 0.85
domain: testing
---
YAML
echo '{"version":"3.0.0","config":{"max_observations_mb":10},"stats":{"installed":"2026-01-01","test_marker":"TestUser"}}' > "$SANDBOX/.claude/cortex/memory.json"
echo '{"reflexes":[{"id":"custom","matcher":".*","enabled":true}]}' > "$SANDBOX/.claude/cortex/reflexes.json"
echo '{"test":"observation"}' > "$SANDBOX/.claude/cortex/projects/test123/observations.jsonl"
echo '[{"id":"p1","status":"approved","action":"test"}]' > "$SANDBOX/.claude/cortex/proposals.json"

# Create CLAUDE.md with custom content + old Cortex section + custom section after
cat > "$SANDBOX/.claude/CLAUDE.md" << 'HEREDOC'
# My Personal Instructions

My important custom content here.

## Cortex (Learning System)

Old cortex section with only 11 commands.

## My Custom Section

This must survive the upgrade.
HEREDOC

# Create settings.json with non-cortex hook
echo '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"bash ~/.claude/hooks/my-other-hook.sh"}]}]}}' > "$SANDBOX/.claude/settings.json"

# Run upgrade
printf 'y\n\n\n\n' | HOME="$SANDBOX" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

# 2a: Version updated
NEW_VER=$(cat "$SANDBOX/.claude/cortex/version" 2>/dev/null | tr -d '[:space:]')
[ "$NEW_VER" != "3.0.0" ] && pass "version upgraded (3.0.0 → $NEW_VER)" || fail "version not upgraded"

# 2b: Custom law preserved
grep -q "My custom law content" "$SANDBOX/.claude/cortex/laws/custom-law.txt" 2>/dev/null && pass "custom law preserved" || fail "custom law lost"

# 2c: Custom instinct preserved
[ -f "$SANDBOX/.claude/cortex/instincts/global/my-instinct.yaml" ] && pass "custom instinct preserved" || fail "custom instinct lost"

# 2d: memory.json NOT overwritten (has user data)
grep -q "TestUser" "$SANDBOX/.claude/cortex/memory.json" 2>/dev/null && pass "memory.json preserved (TestUser)" || fail "memory.json overwritten"

# 2e: reflexes.json NOT overwritten
grep -q "custom" "$SANDBOX/.claude/cortex/reflexes.json" 2>/dev/null && pass "reflexes.json preserved" || fail "reflexes.json overwritten"

# 2f: Observations preserved
[ -f "$SANDBOX/.claude/cortex/projects/test123/observations.jsonl" ] && pass "observations preserved" || fail "observations lost"

# 2g: Proposals preserved with status
python3 -c "
import json
with open('$SANDBOX/.claude/cortex/proposals.json') as f:
    p = json.load(f)
assert any(x.get('status') == 'approved' for x in p), 'approved status lost'
print('OK')
" 2>/dev/null | grep -q OK && pass "proposals preserved with status" || fail "proposals lost or status changed"

# 2h: CLAUDE.md — custom header preserved
grep -q "My Personal Instructions" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null && pass "CLAUDE.md header preserved" || fail "CLAUDE.md header lost"

# 2i: CLAUDE.md — custom section after Cortex preserved
grep -q "My Custom Section" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null && pass "CLAUDE.md custom section preserved" || fail "CLAUDE.md custom section lost"

# 2j: CLAUDE.md — old Cortex section replaced (not duplicated)
CORTEX_COUNT=$(grep -c "## Cortex" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null)
[ "$CORTEX_COUNT" -eq 1 ] && pass "Cortex section replaced (not duplicated)" || fail "Cortex section count: $CORTEX_COUNT"

# 2k: CLAUDE.md — updated content (v4 active set present, old content gone)
grep -q "cx-curate" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null && pass "CLAUDE.md updated with cx-curate" || fail "CLAUDE.md not updated"
! grep -q "11 commands" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null && pass "old Cortex content removed" || fail "old Cortex content still present"

# 2l: Non-cortex hook in settings.json preserved
python3 -c "
import json
with open('$SANDBOX/.claude/settings.json') as f:
    s = json.load(f)
hooks = [h for g in s.get('hooks',{}).get('PreToolUse',[]) for h in g.get('hooks',[])]
assert any('my-other-hook' in h.get('command','') for h in hooks), 'custom hook lost'
print('OK')
" 2>/dev/null | grep -q OK && pass "non-cortex hook preserved in settings.json" || fail "non-cortex hook lost"

# 2m: New hooks installed (observe.py)
[ -f "$SANDBOX/.claude/hooks/cortex/observe.py" ] && pass "observe.py installed on upgrade" || fail "observe.py not installed"

# 2n: hooks/lib installed
[ -f "$SANDBOX/.claude/hooks/cortex/lib/dream_cycle.py" ] && pass "hooks/lib installed on upgrade" || fail "hooks/lib not installed"

rm -rf "$SANDBOX"
echo ""

# ── TEST 3: Idempotency (3 runs) ──────────────────────────────────

echo "--- Idempotency (3 consecutive runs) ---"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude"
for i in 1 2 3; do
    printf '\n\n\n\n\n' | HOME="$SANDBOX" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true
done
CORTEX_COUNT=$(grep -c "## Cortex" "$SANDBOX/.claude/CLAUDE.md" 2>/dev/null)
[ "$CORTEX_COUNT" -eq 1 ] && pass "3 runs: 1 Cortex section (no duplication)" || fail "3 runs: $CORTEX_COUNT Cortex sections"
rm -rf "$SANDBOX"
echo ""

# ── TEST 4: Path traversal protection ─────────────────────────────

echo "--- Path Traversal Protection ---"
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude"
# Create a malicious tar containing an entry with '../' component
MALDIR=$(mktemp -d)
MALTAR="$MALDIR/evil.tar.gz"
mkdir -p "$MALDIR/payload"
echo "pwned" > "$MALDIR/payload/laws.txt"
# Force relative ../ into the archive header (GNU+BSD tar syntax)
if ! (cd "$MALDIR" && tar -czf "$MALTAR" --transform 's|^payload/|../cx-malicious/|' payload/laws.txt 2>/dev/null) \
     && ! (cd "$MALDIR" && tar -czf "$MALTAR" -s '|^payload/|../cx-malicious/|' payload/laws.txt 2>/dev/null); then
    fail "path traversal test: could not craft malicious tar (investigate — do NOT green-pass)"
else
    # Verify the archive really contains a '..' component before claiming the test ran
    if ! tar -tzf "$MALTAR" 2>/dev/null | grep -q '\.\.'; then
        fail "path traversal test: crafted tar has no '..' entry (test would have been vacuous)"
    else
        # Try to import — install.sh MUST reject with 'unsafe' or 'abort' in output
        OUT=$(echo "$MALTAR" | HOME="$SANDBOX" bash "$PROJECT_ROOT/install.sh" 2>&1 || true)
        if echo "$OUT" | grep -qi "unsafe\|abort"; then
            pass "path traversal rejected (install.sh detected '..' in archive)"
        else
            fail "path traversal NOT rejected — install.sh accepted a '..' archive (security regression)"
        fi
    fi
fi
rm -rf "$SANDBOX" "$MALDIR"
echo ""

# --- v3.19.0 — env merge tests ---
echo ""
echo "--- v3.19.0: settings.json env merge ---"

# Test: fresh install adds Cortex env var, preserves user's pre-existing env
SANDBOX_ENV=$(mktemp -d)
SANDBOXES+=("$SANDBOX_ENV")
mkdir -p "$SANDBOX_ENV/.claude"
printf '%s\n' '{"env":{"USER_VAR":"keep-me"},"model":"sonnet"}' > "$SANDBOX_ENV/.claude/settings.json"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX_ENV" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true

if python3 -c "
import json
d = json.load(open('$SANDBOX_ENV/.claude/settings.json'))
env = d.get('env', {})
assert env.get('CORTEX_AGENT_DISABLE_REFLEXES') == '1', 'cortex env not set'
assert env.get('USER_VAR') == 'keep-me', 'user env damaged'
" 2>/dev/null; then
    pass "env: install adds CORTEX_AGENT_DISABLE_REFLEXES + preserves USER_VAR"
else
    fail "env: install did not add cortex env or damaged user env"
fi

# Test: idempotency — second install does not duplicate or modify
ENV_BEFORE=$(python3 -c "import json; print(json.dumps(json.load(open('$SANDBOX_ENV/.claude/settings.json'))['env'], sort_keys=True))" 2>/dev/null)
printf '\n\n\n\n\n\n' | HOME="$SANDBOX_ENV" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true
ENV_AFTER=$(python3 -c "import json; print(json.dumps(json.load(open('$SANDBOX_ENV/.claude/settings.json'))['env'], sort_keys=True))" 2>/dev/null)
[ "$ENV_BEFORE" = "$ENV_AFTER" ] && pass "env: install is idempotent" || fail "env: 2nd install changed env (expected unchanged)"

# Test: fresh install with NO pre-existing settings.json creates valid env block
SANDBOX_ENV2=$(mktemp -d)
SANDBOXES+=("$SANDBOX_ENV2")
mkdir -p "$SANDBOX_ENV2/.claude"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX_ENV2" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true
if python3 -c "
import json
d = json.load(open('$SANDBOX_ENV2/.claude/settings.json'))
assert d.get('env', {}).get('CORTEX_AGENT_DISABLE_REFLEXES') == '1'
" 2>/dev/null; then
    pass "env: fresh install (no prior settings) adds env block"
else
    fail "env: fresh install did not produce expected env block"
fi

# Test: install respects user opt-out (existing CORTEX_AGENT_DISABLE_REFLEXES=0 stays)
SANDBOX_ENV3=$(mktemp -d)
SANDBOXES+=("$SANDBOX_ENV3")
mkdir -p "$SANDBOX_ENV3/.claude"
printf '%s\n' '{"env":{"CORTEX_AGENT_DISABLE_REFLEXES":"0"},"model":"sonnet"}' > "$SANDBOX_ENV3/.claude/settings.json"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX_ENV3" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true
OPTOUT=$(python3 -c "import json; print(json.load(open('$SANDBOX_ENV3/.claude/settings.json'))['env']['CORTEX_AGENT_DISABLE_REFLEXES'])" 2>/dev/null)
[ "$OPTOUT" = "0" ] && pass "env: user opt-out (=0) preserved" || fail "env: opt-out clobbered (got '$OPTOUT')"

# ── TEST: non-interactive upgrade does not cancel on a piped 'n' (v3.38.2) ──
echo ""
echo "--- Non-interactive upgrade (piped 'n' must NOT cancel) ---"
SANDBOX_NI=$(mktemp -d)
SANDBOXES+=("$SANDBOX_NI")
mkdir -p "$SANDBOX_NI/.claude"
# Fresh install to create an existing installation.
printf '\n\n\n\n\n\n' | HOME="$SANDBOX_NI" bash "$PROJECT_ROOT/install.sh" > /dev/null 2>&1 || true
# Upgrade run with a stray 'n' on the pipe — pre-fix this aborted at exit 0.
NI_OUT=$(printf 'n\nn\n' | HOME="$SANDBOX_NI" bash "$PROJECT_ROOT/install.sh" 2>&1); NI_RC=$?
if echo "$NI_OUT" | grep -qi "Installation cancelled"; then
    fail "non-interactive upgrade cancelled on piped 'n'"
elif [ "$NI_RC" -eq 0 ] && echo "$NI_OUT" | grep -qi "installed!"; then
    pass "non-interactive upgrade completes despite piped 'n' (rc=0, 'installed!')"
else
    fail "non-interactive upgrade did not complete (rc=$NI_RC)"
fi
# Explicit -y flag with no stdin also completes cleanly (rc=0 + success banner).
NI_OUT2=$(HOME="$SANDBOX_NI" bash "$PROJECT_ROOT/install.sh" -y < /dev/null 2>&1); NI_RC2=$?
{ [ "$NI_RC2" -eq 0 ] && echo "$NI_OUT2" | grep -qi "installed!"; } \
  && pass "-y flag completes the install (rc=0)" || fail "-y flag did not complete (rc=$NI_RC2)"

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
