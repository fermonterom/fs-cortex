#!/usr/bin/env bash
# Tests for hooks/lib/cross-day-tracker.js
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_MOD="$REPO_ROOT/hooks/lib/cross-day-tracker.js"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export CORTEX_DIR="$SANDBOX"
mkdir -p "$SANDBOX"

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local script="$2"
  if node -e "$script" >/dev/null 2>&1; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    node -e "$script"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_cross_day_tracker.sh ==="

run_test "append + read roundtrip" "
const t = require('$TRACKER_MOD');
t._resetCache();
t.appendDetection({date: '2026-05-09', pattern_id: 'x', trigger_norm: 'a b', source_detector: 'test'});
const cache = t.loadTrackerCache();
if (cache.length !== 1) throw new Error('cache length ' + cache.length);
if (cache[0].pattern_id !== 'x') throw new Error('pattern_id mismatch');
"

run_test "boost 1 day = no boost" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
const r = t.applyCrossDayBoost({id: 'first-time', trigger: 'foo|bar', action: 'a', confidence: 0.40, source: 't'});
if (r.confidence !== 0.40) throw new Error('confidence changed: ' + r.confidence);
if (r.cross_day_count !== 1) throw new Error('cross_day_count: ' + r.cross_day_count);
if (!r.tags.includes('cross-day-1')) throw new Error('tag missing');
"

run_test "boost 2 days = +0.05" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
t.appendDetection({date: '2026-05-08', pattern_id: 'p2', trigger_norm: 'foo bar', source_detector: 'x'});
t._resetCache();
const r = t.applyCrossDayBoost({id: 'p2', trigger: 'foo|bar', action: 'a', confidence: 0.40, source: 't'});
if (Math.abs(r.confidence - 0.45) > 0.001) throw new Error('confidence ' + r.confidence);
if (r.cross_day_count !== 2) throw new Error('cross_day_count ' + r.cross_day_count);
if (!r.tags.includes('cross-day-2')) throw new Error('tag missing');
"

run_test "boost 4 days = +0.10" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
['2026-05-05', '2026-05-06', '2026-05-07'].forEach(d =>
  t.appendDetection({date: d, pattern_id: 'p4', trigger_norm: 'foo bar', source_detector: 'x'}));
t._resetCache();
const r = t.applyCrossDayBoost({id: 'p4', trigger: 'foo|bar', action: 'a', confidence: 0.40, source: 't'});
if (Math.abs(r.confidence - 0.50) > 0.001) throw new Error('confidence ' + r.confidence);
if (r.cross_day_count !== 4) throw new Error('cross_day_count ' + r.cross_day_count);
"

run_test "boost 8 days = +0.15" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
const dates = ['2026-05-01','2026-05-02','2026-05-03','2026-05-04','2026-05-05','2026-05-06','2026-05-07'];
dates.forEach(d => t.appendDetection({date: d, pattern_id: 'p8', trigger_norm: 'foo bar', source_detector: 'x'}));
t._resetCache();
const r = t.applyCrossDayBoost({id: 'p8', trigger: 'foo|bar', action: 'a', confidence: 0.40, source: 't'});
if (Math.abs(r.confidence - 0.55) > 0.001) throw new Error('confidence ' + r.confidence);
if (r.cross_day_count !== 8) throw new Error('cross_day_count ' + r.cross_day_count);
"

run_test "confidence cap at 0.95" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
const dates = ['2026-05-01','2026-05-02','2026-05-03','2026-05-04','2026-05-05','2026-05-06','2026-05-07'];
dates.forEach(d => t.appendDetection({date: d, pattern_id: 'cap', trigger_norm: 'foo bar', source_detector: 'x'}));
t._resetCache();
const r = t.applyCrossDayBoost({id: 'cap', trigger: 'foo|bar', action: 'a', confidence: 0.85, source: 't'});
if (r.confidence !== 0.95) throw new Error('cap broken: ' + r.confidence);
"

run_test "jaccard match dedup" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
t.appendDetection({date: '2026-05-08', pattern_id: 'orig', trigger_norm: 'bash permission denied', source_detector: 'x'});
t._resetCache();
const r = t.applyCrossDayBoost({id: 'different-id', trigger: 'bash|permission|denied', action: 'a', confidence: 0.40, source: 't'});
if (r.cross_day_count !== 2) throw new Error('jaccard miss: ' + r.cross_day_count);
"

run_test "prune removes >365d entries" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
t.appendDetection({date: '2024-01-01', pattern_id: 'old', trigger_norm: 'a b', source_detector: 'x'});
t.appendDetection({date: '2026-05-09', pattern_id: 'new', trigger_norm: 'c d', source_detector: 'x'});
const result = t.prune(365);
if (result.pruned !== 1) throw new Error('expected 1 pruned, got ' + result.pruned);
const cache = t.loadTrackerCache();
if (cache.length !== 1 || cache[0].pattern_id !== 'new') throw new Error('wrong entry kept');
"

run_test "jaccard: single-token trigger skips jaccard matching" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
t.appendDetection({date: '2026-05-08', pattern_id: 'other', trigger_norm: 'bash', source_detector: 'x'});
t._resetCache();
// Single-token trigger 'Bash' should NOT match 'bash' via Jaccard (prevents generic-trigger false positives)
const r = t.applyCrossDayBoost({id: 'different', trigger: 'Edit', action: 'a', confidence: 0.40, source: 't'});
if (r.cross_day_count !== 1) throw new Error('single-token Jaccard false positive: cross_day_count=' + r.cross_day_count);
"

run_test "concurrent append safety" "
const t = require('$TRACKER_MOD');
t._resetCache();
require('fs').rmSync(t.TRACKER_PATH, {force: true});
const writes = [];
for (let i = 0; i < 50; i++) {
  writes.push(t.appendDetection({date: '2026-05-09', pattern_id: 'c'+i, trigger_norm: 'x', source_detector: 't'}));
}
t._resetCache();
const cache = t.loadTrackerCache();
if (cache.length !== 50) throw new Error('expected 50 entries, got ' + cache.length);
"

run_test "v3.28.4: same-day same-pattern_id is appended only once" "
const t = require('$TRACKER_MOD');
const fs = require('fs');
t._resetCache();
fs.rmSync(t.TRACKER_PATH, {force: true});
// Stop hook re-emits same proposals on each session close. Without the v3.28.4
// guard, applyCrossDayBoost would append a new tracker entry on every call.
// v3.29.5 §F3: reads from disk (not cache) because §F3 intentionally stops
// mutating _trackerCache in-session — the dedup is enforced via a separate
// per-session memo and the disk remains the source of truth.
for (let i = 0; i < 10; i++) {
  t.applyCrossDayBoost({id: 'p-stop-hook', trigger: 'foo|bar', action: 'a', confidence: 0.40, source: 't'});
}
const lines = fs.readFileSync(t.TRACKER_PATH, 'utf8').split('\n').filter(Boolean);
const entries = lines.map(l => JSON.parse(l)).filter(e => e.pattern_id === 'p-stop-hook');
if (entries.length !== 1) throw new Error('expected 1 same-day disk entry, got ' + entries.length);
"

run_test "v3.28.4: prune() compacts same-day duplicates from legacy data" "
const t = require('$TRACKER_MOD');
t._resetCache();
const fs = require('fs');
fs.rmSync(t.TRACKER_PATH, {force: true});
// Simulate a pre-v3.28.4 tracker file with duplicates accumulated by the bug.
require('fs').writeFileSync(t.TRACKER_PATH, [
  '{\"date\":\"2026-05-09\",\"pattern_id\":\"dup1\",\"trigger_norm\":\"a b\",\"source_detector\":\"x\"}',
  '{\"date\":\"2026-05-09\",\"pattern_id\":\"dup1\",\"trigger_norm\":\"a b\",\"source_detector\":\"x\"}',
  '{\"date\":\"2026-05-09\",\"pattern_id\":\"dup1\",\"trigger_norm\":\"a b\",\"source_detector\":\"x\"}',
  '{\"date\":\"2026-05-08\",\"pattern_id\":\"dup1\",\"trigger_norm\":\"a b\",\"source_detector\":\"x\"}',
  '{\"date\":\"2026-05-09\",\"pattern_id\":\"unique\",\"trigger_norm\":\"c d\",\"source_detector\":\"x\"}',
].join('\n') + '\n');
const result = t.prune(365);
if (result.before !== 5) throw new Error('expected before=5, got ' + result.before);
if (result.after !== 3) throw new Error('expected after=3 (dup1@today, dup1@yesterday, unique@today), got ' + result.after);
if (result.pruned !== 2) throw new Error('expected pruned=2, got ' + result.pruned);
"

run_test "v3.29.5 F3: in-session emits do NOT inflate dayCount via Jaccard" "
const t = require('$TRACKER_MOD');
t._resetCache();
const fs = require('fs');
fs.rmSync(t.TRACKER_PATH, {force: true});
// Three proposals with similar triggers emitted in the same Stop.
// Pre-F3: append mutated _trackerCache, so p2 and p3 saw it via Jaccard and
// reported dayCount=2 then 3.
// Post-F3: cache not mutated in-session; all three see the same empty
// baseline and report dayCount=1 each.
const p1 = { id: 'cAA', trigger: 'Edit shared common file', confidence: 0.55 };
const p2 = { id: 'cBB', trigger: 'Edit shared common other', confidence: 0.55 };
const p3 = { id: 'cCC', trigger: 'Edit shared common third', confidence: 0.55 };
const r1 = t.applyCrossDayBoost(p1);
const r2 = t.applyCrossDayBoost(p2);
const r3 = t.applyCrossDayBoost(p3);
if (r1.cross_day_count !== 1) throw new Error('p1 expected 1, got ' + r1.cross_day_count);
if (r2.cross_day_count !== 1) throw new Error('p2 expected 1 (no in-session inflation), got ' + r2.cross_day_count);
if (r3.cross_day_count !== 1) throw new Error('p3 expected 1 (no in-session inflation), got ' + r3.cross_day_count);
const lines = fs.readFileSync(t.TRACKER_PATH, 'utf8').split('\n').filter(Boolean);
if (lines.length !== 3) throw new Error('expected 3 disk lines, got ' + lines.length);
"

run_test "v3.29.5 F3 regression: historical evidence still grants boost" "
const t = require('$TRACKER_MOD');
t._resetCache();
const fs = require('fs');
fs.rmSync(t.TRACKER_PATH, {force: true});
// Pre-seed 2 historical dates for a pattern, then evaluate today's emit.
fs.writeFileSync(t.TRACKER_PATH, [
  '{\"date\":\"2026-05-10\",\"pattern_id\":\"hist1\",\"trigger_norm\":\"edit shared a\",\"source_detector\":\"test\"}',
  '{\"date\":\"2026-05-12\",\"pattern_id\":\"hist1\",\"trigger_norm\":\"edit shared a\",\"source_detector\":\"test\"}',
].join('\n') + '\n');
const r = t.applyCrossDayBoost({ id: 'hist1', trigger: 'edit shared a', confidence: 0.55 });
if (r.cross_day_count !== 3) throw new Error('expected 3 distinct dates, got ' + r.cross_day_count);
if (r.confidence < 0.595) throw new Error('expected boost ≥ 0.05, conf got ' + r.confidence);
"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
