#!/usr/bin/env bash
# Reflex matchers regex tests — verify v3.23.3 fix for compound commands
# and r/R flag position.
#
# Background (Sprint 5 v3.20.0 → v3.23.3):
#   The matchers for bash-cat-use-read, bash-grep-use-grep-tool, bash-find-use-glob
#   had two regex bugs that made them blind to ~95% of real-world Bash commands:
#     1. Anchor `^` rejected compound commands (cmd1; cmd2 / cmd1 && cmd2 / cmd1 | cmd2)
#     2. `[a-zA-Z]*[rR]` required r/R as the LAST letter of the flag prefix,
#        missing common flags like -rn, -rE, -RE
#
#   Effect: 0 fires post-resetAt across 6 days of intensive Bash use (when impact.jsonl
#   showed 95+133+78 = 306 real fires the matchers should have caught).
#
#   Fix:
#     - `^` → `(?:^|[;&|]\s*)`  (capture compound commands)
#     - `-[a-zA-Z]*[rR]` → `-[a-zA-Z]*[rR][a-zA-Z]*`  (r/R anywhere in flag prefix)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

DEFAULT_JSON="$PROJECT_ROOT/core/reflexes.default.json"

echo "=== Reflex matcher regex tests (v3.23.3+) ==="
echo ""

# Run all tests via Python to use the actual regex engine
python3 << PYEOF
import json
import re
import sys

data = json.load(open('$DEFAULT_JSON'))
reflexes = {r['id']: r for r in data['reflexes']}

# --- bash-cat-use-read ---
r = reflexes['bash-cat-use-read']
rx = re.compile(r['condition'])
positives = [
    ('cat /tmp/x.py | head -50',                                    'simple cat with .py'),
    ('ls; echo "---"; cat ~/.claude/settings.json | head -50',      'compound with ;'),
    ('cd ~ && cat /private/tmp/foo.md',                             'compound with &&'),
    ('echo X | cat /tmp/foo.json',                                  'compound with |'),
    ('head -100 ~/.claude/cortex/projects/abc/observations.jsonl',  'head with .jsonl extension'),
    ('tail -50 /Users/fmm/.zshrc.json | grep foo',                  'tail then pipe'),
]
negatives = [
    ('cat ~/.claude/cortex/version',  'no extension'),
    ('echo hello world',              'unrelated'),
    ('cat /etc/hosts',                'no recognized extension'),
]
print("--- bash-cat-use-read (compound + extensions) ---")
for s, label in positives:
    m = bool(rx.search(s))
    print(f"  {'PASS' if m else 'FAIL'}: positive [{label}]: {s[:70]}")
for s, label in negatives:
    m = bool(rx.search(s))
    print(f"  {'PASS' if not m else 'FAIL'}: negative [{label}]: {s[:70]}")

# --- bash-grep-use-grep-tool ---
r = reflexes['bash-grep-use-grep-tool']
rx = re.compile(r['condition'])
positives = [
    ('grep -r pattern .',                       'plain -r'),
    ('grep -R pattern .',                       'plain -R'),
    ('grep -rn pattern .',                      '-rn (r first)'),
    ('grep -rE "v3\\\\." dir/',                 '-rE'),
    ('grep -nR foo .',                          '-nR (R last)'),
    ('grep -rni foo .',                         '-rni'),
    ('cd / && grep -rn pattern dir/',           'compound with &&'),
    ('ls; grep -r pattern .',                   'compound with ;'),
    ('echo X | grep -rn foo',                   'compound with pipe (rare but valid)'),
]
negatives = [
    ('grep pattern file.txt',     'no -r/-R'),
    ('grep -i pattern file.txt',  '-i but no r/R'),
    ('grep -nE pattern file.txt', '-nE no r/R'),
]
print("--- bash-grep-use-grep-tool (compound + r/R position) ---")
for s, label in positives:
    m = bool(rx.search(s))
    print(f"  {'PASS' if m else 'FAIL'}: positive [{label}]: {s[:70]}")
for s, label in negatives:
    m = bool(rx.search(s))
    print(f"  {'PASS' if not m else 'FAIL'}: negative [{label}]: {s[:70]}")

# --- bash-find-use-glob ---
r = reflexes['bash-find-use-glob']
rx = re.compile(r['condition'])
positives = [
    ('find . -name "*.py"',                            'simple find -name'),
    ('cd / && find ~/.claude -name "SKILL.md"',        'compound with &&'),
    ('ls; find /tmp -name "foo*"',                     'compound with ;'),
]
negatives = [
    ('find . -name "*.py" -delete',                    'has -delete (excluded)'),
    ('find . -name "*.py" -exec rm {} \\;',            'has -exec (excluded)'),
    ('find . -newer foo',                              'no -name'),
    ('echo find',                                       'word "find" only'),
]
print("--- bash-find-use-glob (compound + exclusions) ---")
for s, label in positives:
    m = bool(rx.search(s))
    print(f"  {'PASS' if m else 'FAIL'}: positive [{label}]: {s[:70]}")
for s, label in negatives:
    m = bool(rx.search(s))
    print(f"  {'PASS' if not m else 'FAIL'}: negative [{label}]: {s[:70]}")
PYEOF

# Tally PASS/FAIL counts from python output
TS=$(date +%Y%m%d-%H%M%S)
LOG=/tmp/test-reflex-matchers-${TS}.log
python3 << PYEOF > "$LOG" 2>&1
import json, re
data = json.load(open('$DEFAULT_JSON'))
reflexes = {r['id']: r for r in data['reflexes']}
total_pass = 0
total_fail = 0
all_cases = {
    'bash-cat-use-read': [
        ('cat /tmp/x.py | head -50', True),
        ('ls; echo "---"; cat ~/.claude/settings.json | head -50', True),
        ('cd ~ && cat /private/tmp/foo.md', True),
        ('echo X | cat /tmp/foo.json', True),
        ('head -100 ~/.claude/cortex/projects/abc/observations.jsonl', True),
        ('tail -50 /Users/fmm/.zshrc.json | grep foo', True),
        ('cat ~/.claude/cortex/version', False),
        ('echo hello world', False),
        ('cat /etc/hosts', False),
    ],
    'bash-grep-use-grep-tool': [
        ('grep -r pattern .', True),
        ('grep -R pattern .', True),
        ('grep -rn pattern .', True),
        ('grep -rE "v3" dir/', True),
        ('grep -nR foo .', True),
        ('grep -rni foo .', True),
        ('cd / && grep -rn pattern dir/', True),
        ('ls; grep -r pattern .', True),
        ('echo X | grep -rn foo', True),
        ('grep pattern file.txt', False),
        ('grep -i pattern file.txt', False),
        ('grep -nE pattern file.txt', False),
    ],
    'bash-find-use-glob': [
        ('find . -name "*.py"', True),
        ('cd / && find ~/.claude -name "SKILL.md"', True),
        ('ls; find /tmp -name "foo*"', True),
        ('find . -name "*.py" -delete', False),
        ('find . -name "*.py" -exec rm {} \\;', False),
        ('find . -newer foo', False),
        ('echo find', False),
    ],
}
for rid, cases in all_cases.items():
    rx = re.compile(reflexes[rid]['condition'])
    for s, want in cases:
        got = bool(rx.search(s))
        if got == want: total_pass += 1
        else: total_fail += 1
print(f"PASS_TOTAL:{total_pass}")
print(f"FAIL_TOTAL:{total_fail}")
PYEOF
PASS_TOTAL=$(grep "^PASS_TOTAL:" "$LOG" | cut -d: -f2)
FAIL_TOTAL=$(grep "^FAIL_TOTAL:" "$LOG" | cut -d: -f2)
PASS=$PASS_TOTAL
FAIL=$FAIL_TOTAL

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
