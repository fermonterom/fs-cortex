#!/usr/bin/env bash
# tests/test_install_downgrade.sh — v3.25.1+
#
# Sandbox tests for install.sh's downgrade safeguard. Created after a
# 2026-05-07 incident where a behind-remote local repo silently downgraded
# a fresher install (v3.25.0 -> v3.24.1) because the installer is a
# copy-not-merge of hooks/commands and never compared semver. The safeguard
# aborts on downgrade unless `--allow-downgrade` is passed.
#
# Run: bash tests/test_install_downgrade.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
NEW_VERSION=$(grep -m1 '^NEW_VERSION=' "$INSTALL_SH" | sed -E 's/^NEW_VERSION="([^"]+)"/\1/')

if [ -z "$NEW_VERSION" ]; then
    echo "FAIL: could not extract NEW_VERSION from install.sh"
    exit 1
fi

PASS=0
FAIL=0

run_test() {
    local name=$1 prior=$2 args=$3 expect_rc=$4 expect_v=$5
    local SANDBOX
    SANDBOX=$(mktemp -d)
    mkdir -p "$SANDBOX/.claude"
    if [ -n "$prior" ]; then
        mkdir -p "$SANDBOX/.claude/cortex"
        echo "$prior" > "$SANDBOX/.claude/cortex/version"
    fi
    local LOG="$SANDBOX/install.log"
    # shellcheck disable=SC2086
    printf '\ny\n\n\n' | HOME="$SANDBOX" bash "$INSTALL_SH" $args > "$LOG" 2>&1
    local rc=$?
    local v
    v=$(cat "$SANDBOX/.claude/cortex/version" 2>/dev/null || echo "")
    local ok=1
    if [ "$rc" != "$expect_rc" ]; then
        echo "FAIL ${name}: rc=${rc} want=${expect_rc}"
        ok=0
    fi
    if [ "$v" != "$expect_v" ]; then
        echo "FAIL ${name}: version=${v} want=${expect_v}"
        ok=0
    fi
    if [ $ok -eq 1 ]; then
        echo "PASS ${name}"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  log tail:"
        tail -10 "$LOG" | sed 's/^/    /'
    fi
    rm -rf "$SANDBOX"
}

echo "Testing install.sh v$NEW_VERSION downgrade safeguard..."

run_test "clean_install"          ""            ""                   0 "$NEW_VERSION"
run_test "same_version_refresh"   "$NEW_VERSION" ""                   0 "$NEW_VERSION"
run_test "downgrade_blocked"      "9.99.99"     ""                   1 "9.99.99"
run_test "downgrade_with_flag"    "9.99.99"     "--allow-downgrade"  0 "$NEW_VERSION"
run_test "real_upgrade_path"      "3.0.0"       ""                   0 "$NEW_VERSION"

echo ""
echo "Result: ${PASS}/$((PASS + FAIL)) PASS"
[ $FAIL -eq 0 ]
