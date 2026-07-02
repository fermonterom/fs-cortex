#!/usr/bin/env bash
# cx-status collector tests — AD fix #6 (2026-07-02)
#
# commands/cx-status.md's collector is a single embedded python3 heredoc, not
# a standalone script — this test extracts it (between the `python3 <<
# 'COLLECTOR'` / `COLLECTOR` fences) and runs it against a sandboxed HOME so
# it operates on a fake ~/.claude/cortex instead of the real one. The
# collector already respects HOME via os.path.expanduser, so no code change
# was needed to make it testable this way.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CX_STATUS_MD="$PROJECT_ROOT/commands/cx-status.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== cx-status collector tests ==="
echo ""

# Extract the embedded collector script between the heredoc fences.
START_LINE=$(grep -n "^python3 << 'COLLECTOR'$" "$CX_STATUS_MD" | head -1 | cut -d: -f1)
END_LINE=$(grep -n "^COLLECTOR$" "$CX_STATUS_MD" | head -1 | cut -d: -f1)
if [ -z "$START_LINE" ] || [ -z "$END_LINE" ]; then
  fail "could not locate collector heredoc fences in cx-status.md"
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi
COLLECTOR_PY=$(mktemp -t cx-status-collector.XXXXXX.py)
sed -n "$((START_LINE + 1)),$((END_LINE - 1))p" "$CX_STATUS_MD" > "$COLLECTOR_PY"

echo "--- AD fix #6: registry last_seen (snake_case) read correctly ---"

SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.claude/cortex/projects"
cat > "$SANDBOX/.claude/cortex/projects/registry.json" <<'JSON'
{
  "abc123def456": {
    "name": "snake-case-project",
    "root": "/tmp/snake-case-project",
    "remote": "",
    "last_seen": "2026-06-30T10:00:00Z"
  },
  "789ghi012jkl": {
    "name": "legacy-camelcase-project",
    "root": "/tmp/legacy-camelcase-project",
    "remote": "",
    "lastSeen": "2026-06-15T08:00:00Z"
  },
  "000no-timestamp": {
    "name": "no-timestamp-project",
    "root": "/tmp/no-timestamp-project",
    "remote": ""
  }
}
JSON

OUT=$(cd "$SANDBOX" && HOME="$SANDBOX" python3 "$COLLECTOR_PY" 2>&1)
if ! echo "$OUT" | python3 -c "import json,sys; json.loads(sys.stdin.read())" >/dev/null 2>&1; then
  fail "collector did not emit valid JSON: $OUT"
else
  snake_seen=$(echo "$OUT" | python3 -c "
import json,sys
data=json.loads(sys.stdin.read())
p={x['name']: x['last_seen'] for x in data['projects']}
print(p.get('snake-case-project','MISSING'))
")
  [ "$snake_seen" = "2026-06-30T10:00:00Z" ] && pass "registry last_seen (snake_case) surfaced verbatim" || fail "snake_case last_seen: got '$snake_seen'"

  legacy_seen=$(echo "$OUT" | python3 -c "
import json,sys
data=json.loads(sys.stdin.read())
p={x['name']: x['last_seen'] for x in data['projects']}
print(p.get('legacy-camelcase-project','MISSING'))
")
  [ "$legacy_seen" = "2026-06-15T08:00:00Z" ] && pass "legacy lastSeen (camelCase) fallback still works" || fail "camelCase fallback: got '$legacy_seen'"

  no_ts_seen=$(echo "$OUT" | python3 -c "
import json,sys
data=json.loads(sys.stdin.read())
p={x['name']: x['last_seen'] for x in data['projects']}
print(p.get('no-timestamp-project','MISSING'))
")
  [ "$no_ts_seen" = "?" ] && pass "missing both fields degrades to '?' (no crash)" || fail "no-timestamp fallback: got '$no_ts_seen'"
fi

rm -rf "$SANDBOX" "$COLLECTOR_PY"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
