#!/usr/bin/env bash
# test_deploy_drift.sh — v3.34.1 anti-drift guard
# Root cause of "Cortex a medias": edits land in the repo but install.sh is
# never run, so the live system runs stale code. check_deploy_drift() warns at
# SessionStart when the deployed version is behind the repo's install.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SS="$PROJECT_ROOT/hooks/session-start.py"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

SANDBOX="$(mktemp -d -t cortex-drift-test-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
echo "=== Deploy Drift Guard Tests (sandbox: $SANDBOX) ==="
echo

# call check_deploy_drift() with CORTEX_DIR pointed at the sandbox
run() {
  CORTEX_DIR="$SANDBOX/cortex" python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('ss', '$SS')
ss = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ss)
r = ss.check_deploy_drift()
print(r if r else 'NONE')
"
}

# fake repo with a given NEW_VERSION in install.sh
make_repo() { mkdir -p "$SANDBOX/repo"; printf 'NEW_VERSION="%s"\n' "$1" > "$SANDBOX/repo/install.sh"; }
set_deployed() { mkdir -p "$SANDBOX/cortex"; printf '%s\n' "$1" > "$SANDBOX/cortex/version"; }
set_repo_path() { printf '%s\n' "$1" > "$SANDBOX/cortex/.repo-path"; }

# ── Test 1: deployed behind repo → warns ─────────────────────────────────────
echo "Test 1: deployed 3.33.0 < repo 3.34.0 → DRIFT warning"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
set_deployed "3.33.0"; make_repo "3.34.0"; set_repo_path "$SANDBOX/repo"
OUT=$(run)
echo "$OUT" | grep -qi "drift" && pass "warns on drift: ${OUT:0:60}" || fail "no warning: $OUT"
echo "$OUT" | grep -q "3.33.0" && echo "$OUT" | grep -q "3.34.0" && pass "warning cites both versions" || fail "versions missing: $OUT"

# ── Test 2: versions equal → no warning ──────────────────────────────────────
echo "Test 2: deployed == repo (3.34.0) → no warning"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
set_deployed "3.34.0"; make_repo "3.34.0"; set_repo_path "$SANDBOX/repo"
[ "$(run)" = "NONE" ] && pass "no warning when in sync" || fail "warned despite in-sync"

# ── Test 3: deployed AHEAD of repo → no warning ──────────────────────────────
echo "Test 3: deployed 3.35.0 > repo 3.34.0 → no warning"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
set_deployed "3.35.0"; make_repo "3.34.0"; set_repo_path "$SANDBOX/repo"
[ "$(run)" = "NONE" ] && pass "no warning when ahead" || fail "warned despite ahead"

# ── Test 4: no .repo-path → silent (legacy install) ──────────────────────────
echo "Test 4: missing .repo-path → silent"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
set_deployed "3.33.0"; make_repo "3.34.0"
[ "$(run)" = "NONE" ] && pass "silent without .repo-path" || fail "warned without repo path"

# ── Test 5: repo path points nowhere → silent ────────────────────────────────
echo "Test 5: stale .repo-path (no install.sh) → silent"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
set_deployed "3.33.0"; set_repo_path "$SANDBOX/does-not-exist"
[ "$(run)" = "NONE" ] && pass "silent on stale repo path" || fail "crashed/warned on bad path"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
