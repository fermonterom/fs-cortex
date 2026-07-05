#!/usr/bin/env bash
# test_distill_v4.sh — v4 deterministic promotion gate tests.
# Scope: docs/DESIGN-V4.md §3 + docs/audit-cortex-2026-07-02.md follow-ups #1-2.
# Validates ONLY the v4 changes to hooks/lib/distill_engine.py:
#   1. _derive_law_line never embeds a raw/truncated regex trigger.
#   2. auto_promote_to_law's new deterministic gate (confidence >= 0.95,
#      projects_seen >= 3, occurrences_v4 >= 10, no noise in 14d) promotes
#      and auto-archives the source instinct.
#   3. A confident-but-single-project instinct is NOT promoted.
#   4. law_eligible:false is respected as an explicit veto.
#   5. (bonus) lazy occurrences -> occurrences_legacy/occurrences_v4 migration.
# Does NOT re-validate the pre-v4 gate (sustained-14d, sessions>=3,
# useful>=5, law_eligible:true) — that behavior was intentionally retired
# by this change; see tests/test_distill_engine.sh for the superseded
# suite (left in place, now stale against v4 — out of scope here).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PYTHONPATH="$PROJECT_ROOT/hooks/lib:${PYTHONPATH:-}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

SANDBOX="$(mktemp -d -t cortex-distill-v4-test-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== Distill Engine v4 Tests (sandbox: $SANDBOX) ==="
echo

# ── Helper: write a minimal instinct YAML ────────────────────────────────────
# make_instinct <dir> <id> <conf> <extra_fields...>
# extra_fields is raw multiline YAML appended inside the frontmatter block.
make_instinct() {
  local dir="$1" iid="$2" conf="$3"
  shift 3
  local extra="${*:-}"
  mkdir -p "$dir"
  cat > "$dir/${iid}.yaml" <<YAML
---
id: ${iid}
confidence: ${conf}
domain: testing
trigger: 'SomeTool'
action: 'Always do the thing for testing'
last_seen: 2026-07-01
first_seen: 2026-06-01
project_id: proj-alpha
project_name: test-project
${extra}
---
YAML
}

# Common preamble: import distill_engine with CORTEX_DIR pointed at $1,
# redundantly re-pinning every module-level path constant (belt-and-
# suspenders — matches tests/test_distill_engine.sh convention; the
# `export CORTEX_DIR` before invoking python already makes this correct
# at import time, this just guards against import-order surprises).
py_preamble() {
  local dir="$1"
  cat <<PY
import sys, os; sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
os.environ['CORTEX_DIR'] = '$dir'
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$dir')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
PY
}

# ── Test 1: law derived from a regex trigger never embeds raw regex ─────────
echo "--- Test 1: derive-law-line-no-raw-regex ---"
result=$(python3 -c "
$(py_preamble "$SANDBOX/t1")
fields = {
    'action': 'Always confirm output before continuing with the next pipeline step',
    'trigger': 'Bash|Edit|Write(file_path|old_string)',
}
line = de._derive_law_line(fields)
has_pipe = '|' in line
opens = line.count('(')
closes = line.count(')')
unbalanced = opens != closes
print(repr(line))
print(has_pipe, unbalanced)
")
echo "  law line: $(echo "$result" | head -1)"
if echo "$result" | tail -1 | grep -q "^False False$"; then
  pass "derive-law-line-no-raw-regex: no '|' and no unbalanced parens"
else
  fail "derive-law-line-no-raw-regex: got '$(echo "$result" | tail -1)'"
fi

# Plain-text long trigger still cuts at a word boundary (not mid-word).
result2=$(python3 -c "
$(py_preamble "$SANDBOX/t1b")
fields = {
    'action': 'confirm the migration output looks correct before merging',
    'trigger': 'the deploy pipeline finishes running every single background job',
}
line = de._derive_law_line(fields)
print(line)
")
if echo "$result2" | grep -qE "^When [a-z ]+, confirm the migration"; then
  pass "derive-law-line-plain-trigger: word-boundary cut, no mid-word truncation"
else
  fail "derive-law-line-plain-trigger: got '$result2'"
fi

# ── Test 2: 0.96 conf / 4 projects / occurrences_v4=12 → promoted + archived
echo "--- Test 2: promote-meets-v4-gate ---"
T2="$SANDBOX/t2"
make_instinct "$T2/instincts/global" "t2-mature" "0.9600" \
  "occurrences_v4: 12
projects_seen:
  - proj-alpha
  - proj-beta
  - proj-gamma
  - proj-delta"
# No impact.jsonl on purpose — exercises the "impact log not accessible,
# skip noise check" branch of Criteria 4.

result=$(python3 -c "
$(py_preamble "$T2")
promoted, candidates = de.auto_promote_to_law()
promoted_ids = [p['id'] for p in promoted]
law_path = de.LAWS_DIR / 't2-mature.txt'
law_written = law_path.exists() and law_path.read_text().strip() != ''
src_gone = not (de.INSTINCTS_DIR / 't2-mature.yaml').exists()
import glob
archived = glob.glob(str(de.INSTINCTS_DIR / 'archive' / 't2-mature.promoted-to-law-*.yaml'))
klog = de.KNOWLEDGE_LOG.read_text() if de.KNOWLEDGE_LOG.exists() else ''
logged_archive = 'archived' in klog and 't2-mature' in klog
print('t2-mature' in promoted_ids, law_written, src_gone, len(archived) == 1, logged_archive)
")
if echo "$result" | grep -q "^True True True True True$"; then
  pass "promote-meets-v4-gate: promoted, law written, source archived + logged"
else
  fail "promote-meets-v4-gate: got '$result'"
fi

# ── Test 3: 0.99 conf but only 1 project → NOT promoted ─────────────────────
echo "--- Test 3: promote-rejects-single-project ---"
T3="$SANDBOX/t3"
make_instinct "$T3/instincts/global" "t3-single-project" "0.9900" \
  "occurrences_v4: 12"
# project_id: proj-alpha only (from make_instinct defaults) — no projects_seen.

result=$(python3 -c "
$(py_preamble "$T3")
promoted, candidates = de.auto_promote_to_law()
promoted_ids = [p['id'] for p in promoted]
cand = next((c for c in candidates if c['id'] == 't3-single-project'), None)
reason_ok = cand is not None and any('projects' in r for r in cand['reasons'])
src_still_there = (de.INSTINCTS_DIR / 't3-single-project.yaml').exists()
print('t3-single-project' not in promoted_ids, reason_ok, src_still_there)
")
if echo "$result" | grep -q "^True True True$"; then
  pass "promote-rejects-single-project: not promoted, reason mentions projects, source untouched"
else
  fail "promote-rejects-single-project: got '$result'"
fi

# ── Test 4: law_eligible:false vetoes even a fully-qualifying instinct ──────
echo "--- Test 4: law-eligible-false-vetoes ---"
T4="$SANDBOX/t4"
make_instinct "$T4/instincts/global" "t4-vetoed" "0.9900" \
  "occurrences_v4: 20
law_eligible: false
projects_seen:
  - proj-alpha
  - proj-beta
  - proj-gamma"

result=$(python3 -c "
$(py_preamble "$T4")
promoted, candidates = de.auto_promote_to_law()
promoted_ids = [p['id'] for p in promoted]
in_candidates = any(c['id'] == 't4-vetoed' for c in candidates)
src_still_there = (de.INSTINCTS_DIR / 't4-vetoed.yaml').exists()
print('t4-vetoed' not in promoted_ids, not in_candidates, src_still_there)
")
if echo "$result" | grep -q "^True True True$"; then
  pass "law-eligible-false-vetoes: not promoted, not even a candidate, untouched"
else
  fail "law-eligible-false-vetoes: got '$result'"
fi

# ── Test 5 (bonus): lazy occurrences -> occurrences_legacy/occurrences_v4 ───
echo "--- Test 5: lazy-occurrences-migration ---"
T5="$SANDBOX/t5"
make_instinct "$T5/instincts/global" "t5-legacy-occ" "0.9700" \
  "occurrences: 999"
# Only 1 project → will not promote, but migration must still run (it's
# unconditional on touch, independent of whether the instinct promotes).

result=$(python3 -c "
$(py_preamble "$T5")
de.auto_promote_to_law()
text = (de.INSTINCTS_DIR / 't5-legacy-occ.yaml').read_text()
has_legacy = 'occurrences_legacy: 999' in text
has_v4_zero = 'occurrences_v4: 0' in text
has_old_key = any(l.strip().startswith('occurrences:') for l in text.splitlines())
print(has_legacy, has_v4_zero, not has_old_key)
")
if echo "$result" | grep -q "^True True True$"; then
  pass "lazy-occurrences-migration: occurrences_legacy=999, occurrences_v4=0, old key gone"
else
  fail "lazy-occurrences-migration: got '$result'"
fi

# ── Test 6: saturated law cap auto-swaps a mature zero-impact victim ────────
echo "--- Test 6: saturated-cap-auto-swap ---"
T6="$SANDBOX/t6"
mkdir -p "$T6/laws"
OLD_TS=$(python3 -c "import datetime; print((datetime.datetime.now() - datetime.timedelta(days=40)).strftime('%Y%m%d%H%M'))")
for i in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  echo "Existing law $i unique content" > "$T6/laws/law-$i.txt"
  touch -t "$OLD_TS" "$T6/laws/law-$i.txt"
done
make_instinct "$T6/instincts/global" "t6-auto-swap" "0.9600" \
  "occurrences_v4: 12
projects_seen:
  - proj-alpha
  - proj-beta
  - proj-gamma"

result=$(python3 -c "
$(py_preamble "$T6")
promoted, candidates = de.auto_promote_to_law()
p = promoted[0] if promoted else {}
victim = p.get('swapped_out')
new_law = (de.LAWS_DIR / 't6-auto-swap.txt').exists()
victim_gone = victim and not (de.LAWS_DIR / f'{victim}.txt').exists()
archive_hit = victim and list((de.LAWS_DIR / 'archive').glob(f'{victim}.*.txt'))
print(p.get('id') == 't6-auto-swap', bool(victim), new_law, bool(victim_gone), bool(archive_hit))
")
if echo "$result" | grep -q "^True True True True True$"; then
  pass "saturated-cap-auto-swap: new law written, victim archived, swapped_out reported"
else
  fail "saturated-cap-auto-swap: got '$result'"
fi

# ── Test 7: victim younger than 30d blocks auto-swap and surfaces candidate ──
echo "--- Test 7: saturated-cap-young-victim-blocked ---"
T7="$SANDBOX/t7"
mkdir -p "$T7/laws"
YOUNG_TS=$(python3 -c "import datetime; print((datetime.datetime.now() - datetime.timedelta(days=10)).strftime('%Y%m%d%H%M'))")
for i in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  echo "Young law $i unique content" > "$T7/laws/law-$i.txt"
  touch -t "$YOUNG_TS" "$T7/laws/law-$i.txt"
done
make_instinct "$T7/instincts/global" "t7-young-blocked" "0.9700" \
  "occurrences_v4: 12
projects_seen:
  - proj-alpha
  - proj-beta
  - proj-gamma"

result=$(python3 -c "
$(py_preamble "$T7")
promoted, candidates = de.auto_promote_to_law()
cand = next((c for c in candidates if c['id'] == 't7-young-blocked'), None)
reason = ' '.join(cand.get('reasons', [])) if cand else ''
print(not promoted, cand is not None, 'age' in reason and '< 30d' in reason, not (de.LAWS_DIR / 't7-young-blocked.txt').exists())
")
if echo "$result" | grep -q "^True True True True$"; then
  pass "saturated-cap-young-victim-blocked: no swap, candidate reason mentions age < 30d"
else
  fail "saturated-cap-young-victim-blocked: got '$result'"
fi

# ── Test 8: expire_stale_proposals rejects only old pending proposals ───────
echo "--- Test 8: expire-stale-proposals ---"
T8="$SANDBOX/t8"
mkdir -p "$T8"
OLD_DETECTED=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=40)).strftime('%Y-%m-%d'))")
TODAY_DETECTED=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d'))")
python3 - <<PYEOF
import json
from pathlib import Path
Path('$T8/proposals.json').write_text(json.dumps([
  {'id': 'old-pending', 'status': 'pending', 'detected': '$OLD_DETECTED'},
  {'id': 'fresh-pending', 'status': 'pending', 'detected': '$TODAY_DETECTED'},
], indent=2), encoding='utf-8')
PYEOF

result=$(python3 -c "
$(py_preamble "$T8")
de.PROPOSALS_FILE = de.CORTEX_DIR / 'proposals.json'
expired = de.expire_stale_proposals()
props = de._load_proposals()
old = next(p for p in props if p['id'] == 'old-pending')
fresh = next(p for p in props if p['id'] == 'fresh-pending')
print(expired == [{'id': 'old-pending', 'detected': '$OLD_DETECTED'}], old.get('status') == 'rejected', old.get('rejected_by') == 'cx-maintain-ttl', fresh.get('status') == 'pending')
")
if echo "$result" | grep -q "^True True True True$"; then
  pass "expire-stale-proposals: old pending rejected, fresh pending untouched"
else
  fail "expire-stale-proposals: got '$result'"
fi

# ── Test 9: dry-run mutates neither swap files nor proposal statuses ────────
echo "--- Test 9: dry-run-no-mutations ---"
T9="$SANDBOX/t9"
mkdir -p "$T9/laws"
for i in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  echo "Dry run law $i unique content" > "$T9/laws/law-$i.txt"
  touch -t "$OLD_TS" "$T9/laws/law-$i.txt"
done
make_instinct "$T9/instincts/global" "t9-dry-swap" "0.9800" \
  "occurrences_v4: 12
projects_seen:
  - proj-alpha
  - proj-beta
  - proj-gamma"
python3 - <<PYEOF
import json
from pathlib import Path
Path('$T9/proposals.json').write_text(json.dumps([
  {'id': 'old-dry', 'status': 'pending', 'detected': '$OLD_DETECTED'},
], indent=2), encoding='utf-8')
PYEOF

result=$(python3 -c "
$(py_preamble "$T9")
de.PROPOSALS_FILE = de.CORTEX_DIR / 'proposals.json'
de.auto_promote_to_law(dry_run=True)
de.expire_stale_proposals(dry_run=True)
props = de._load_proposals()
print(
  not (de.LAWS_DIR / 't9-dry-swap.txt').exists(),
  (de.LAWS_DIR / 'law-00.txt').exists(),
  not (de.LAWS_DIR / 'archive').exists(),
  props[0].get('status') == 'pending'
)
")
if echo "$result" | grep -q "^True True True True$"; then
  pass "dry-run-no-mutations: no law/archive/proposal mutations"
else
  fail "dry-run-no-mutations: got '$result'"
fi

# ── Test 10: retired law cascades to instinct when a backing YAML exists ────
# v4.3.1 — the victim of an auto-swap must fall back to the instinct pool
# (law_eligible:false) instead of dying in laws/archive/. The backing YAML
# uses the <id>.promoted-to-law-<date>.yaml name every v4 promotion writes.
echo "--- Test 10: retired-law-demotes-to-instinct ---"
T10="$SANDBOX/t10"
mkdir -p "$T10/laws"
VETERAN_TS=$(python3 -c "import datetime; print((datetime.datetime.now() - datetime.timedelta(days=50)).strftime('%Y%m%d%H%M'))")
for i in 00 01 02 03 04 05 06 07 08 09 10 11 12 13; do
  echo "Cascade law $i unique content" > "$T10/laws/law-$i.txt"
  touch -t "$OLD_TS" "$T10/laws/law-$i.txt"
done
echo "Veteran law unique content" > "$T10/laws/law-veteran.txt"
touch -t "$VETERAN_TS" "$T10/laws/law-veteran.txt"
make_instinct "$T10/instincts/global/archive" "law-veteran" "0.9500"
mv "$T10/instincts/global/archive/law-veteran.yaml" \
   "$T10/instincts/global/archive/law-veteran.promoted-to-law-20260101.yaml"
make_instinct "$T10/instincts/global" "t10-cascade" "0.9600" \
  "occurrences_v4: 12
projects_seen:
  - proj-alpha
  - proj-beta
  - proj-gamma"

result=$(python3 -c "
$(py_preamble "$T10")
promoted, candidates = de.auto_promote_to_law()
p = promoted[0] if promoted else {}
victim = p.get('swapped_out')
restored = de.INSTINCTS_DIR / 'law-veteran.yaml'
fields = de._read_instinct(restored)[0] if restored.exists() else {}
promo_consumed = not list((de.INSTINCTS_DIR / 'archive').glob('law-veteran.promoted-to-law-*.yaml'))
print(victim == 'law-veteran', restored.exists(), str(fields.get('law_eligible', '')).strip().lower() == 'false', fields.get('trigger') == 'SomeTool', promo_consumed)
")
if echo "$result" | grep -q "^True True True True True$"; then
  pass "retired-law-demotes-to-instinct: backing YAML restored with law_eligible:false, trigger intact"
else
  fail "retired-law-demotes-to-instinct: got '$result'"
fi

# ── Test 11: victim without backing YAML stays archive-only (no invention) ──
echo "--- Test 11: retired-law-no-backing-archive-only ---"
T11="$SANDBOX/t11"
mkdir -p "$T11/laws"
for i in 00 01 02 03 04 05 06 07 08 09 10 11 12 13; do
  echo "Solo law $i unique content" > "$T11/laws/law-$i.txt"
  touch -t "$OLD_TS" "$T11/laws/law-$i.txt"
done
echo "Solo veteran unique content" > "$T11/laws/law-solo.txt"
touch -t "$VETERAN_TS" "$T11/laws/law-solo.txt"
make_instinct "$T11/instincts/global" "t11-no-backing" "0.9600" \
  "occurrences_v4: 12
projects_seen:
  - proj-alpha
  - proj-beta
  - proj-gamma"

result=$(python3 -c "
$(py_preamble "$T11")
promoted, candidates = de.auto_promote_to_law()
p = promoted[0] if promoted else {}
victim = p.get('swapped_out')
archive_hit = victim and list((de.LAWS_DIR / 'archive').glob(f'{victim}.*.txt'))
no_invented = victim and not (de.INSTINCTS_DIR / f'{victim}.yaml').exists()
print(victim == 'law-solo', bool(archive_hit), bool(no_invented))
")
if echo "$result" | grep -q "^True True True$"; then
  pass "retired-law-no-backing-archive-only: swap succeeded, no instinct invented"
else
  fail "retired-law-no-backing-archive-only: got '$result'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
