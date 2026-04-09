#!/usr/bin/env bash
# YAML utils tests — shared parser, field update, file listing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

YAML_UTILS="$PROJECT_ROOT/hooks/lib/yaml-utils.js"

echo "=== YAML Utils Tests ==="
echo ""

# --- Test 1: Parse float confidence ---
echo "--- parseYamlFrontmatter ---"
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter('---\nconfidence: 0.75\n---\nBody');
console.log(r.fields.confidence === 0.75 ? 'OK' : 'FAIL:' + typeof r.fields.confidence + '=' + r.fields.confidence);
")
[ "$result" = "OK" ] && pass "float 0.75 parsed correctly" || fail "float: $result"

# --- Test 2: Parse integer ---
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter('---\noccurrences: 42\n---\n');
console.log(r.fields.occurrences === 42 ? 'OK' : 'FAIL:' + r.fields.occurrences);
")
[ "$result" = "OK" ] && pass "integer 42 parsed correctly" || fail "int: $result"

# --- Test 3: Parse quoted string ---
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter('---\naction: \"hello world\"\n---\n');
console.log(r.fields.action === 'hello world' ? 'OK' : 'FAIL:' + r.fields.action);
")
[ "$result" = "OK" ] && pass "quoted string parsed" || fail "quoted: $result"

# --- Test 4: Parse single-quoted string ---
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter(\"---\nid: 'my-instinct'\n---\n\");
console.log(r.fields.id === 'my-instinct' ? 'OK' : 'FAIL:' + r.fields.id);
")
[ "$result" = "OK" ] && pass "single-quoted string parsed" || fail "single-q: $result"

# --- Test 5: Parse bare string ---
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter('---\ndomain: security\n---\n');
console.log(r.fields.domain === 'security' ? 'OK' : 'FAIL:' + r.fields.domain);
")
[ "$result" = "OK" ] && pass "bare string parsed" || fail "bare: $result"

# --- Test 6: No frontmatter returns null ---
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter('No frontmatter here');
console.log(r === null ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "no frontmatter returns null" || fail "null: $result"

# --- Test 7: Body extraction ---
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter('---\nid: test\n---\nThe body content');
console.log(r.body === 'The body content' ? 'OK' : 'FAIL:' + r.body);
")
[ "$result" = "OK" ] && pass "body extracted correctly" || fail "body: $result"

# --- Test 8: Colon in value ---
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter('---\naction: check http://example.com for errors\n---\n');
console.log(r.fields.action.includes('http://example.com') ? 'OK' : 'FAIL:' + r.fields.action);
")
[ "$result" = "OK" ] && pass "colon in value preserved" || fail "colon: $result"

# --- Test 9: updateYamlField replaces existing ---
echo "--- updateYamlField ---"
result=$(node -e "
const { updateYamlField } = require('$YAML_UTILS');
const input = '---\nconfidence: 0.50\nid: test\n---\n';
const updated = updateYamlField(input, 'confidence', 0.85);
console.log(updated.includes('0.85') && !updated.includes('0.50') ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "updateYamlField replaces value" || fail "update: $result"

# --- Test 10: updateYamlField adds new field ---
result=$(node -e "
const { updateYamlField } = require('$YAML_UTILS');
const input = '---\nid: test\n---\n';
const updated = updateYamlField(input, 'last_seen', '2026-04-09');
console.log(updated.includes('last_seen') ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "updateYamlField adds new field" || fail "add: $result"

# --- Test 11: listYamlFiles ---
echo "--- listYamlFiles ---"
SANDBOX=$(mktemp -d)
touch "$SANDBOX/a.yaml" "$SANDBOX/b.yml" "$SANDBOX/c.txt" "$SANDBOX/d.json"
result=$(node -e "
const { listYamlFiles } = require('$YAML_UTILS');
const files = listYamlFiles('$SANDBOX');
console.log(files.length === 2 ? 'OK' : 'FAIL:' + files.length);
")
rm -rf "$SANDBOX"
[ "$result" = "OK" ] && pass "listYamlFiles finds .yaml + .yml only" || fail "list: $result"

# --- Test 12: listYamlFiles on missing dir ---
result=$(node -e "
const { listYamlFiles } = require('$YAML_UTILS');
const files = listYamlFiles('/nonexistent/path');
console.log(files.length === 0 ? 'OK' : 'FAIL');
")
[ "$result" = "OK" ] && pass "listYamlFiles returns [] for missing dir" || fail "missing: $result"

# --- Test 13: Zero confidence ---
result=$(node -e "
const { parseYamlFrontmatter } = require('$YAML_UTILS');
const r = parseYamlFrontmatter('---\nconfidence: 0.00\n---\n');
console.log(r.fields.confidence === 0 ? 'OK' : 'FAIL:' + r.fields.confidence);
")
[ "$result" = "OK" ] && pass "zero confidence 0.00 parsed" || fail "zero: $result"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
