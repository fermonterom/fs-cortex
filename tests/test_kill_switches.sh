#!/usr/bin/env bash
# test_kill_switches.sh — v3.29.0 (Sprint 8 §4.8)
#
# Isolation tests for the 3 kill switches introduced in v3.29.0:
#   * CORTEX_OBSERVE_OFF=1     — observe.py exits before any write
#   * CORTEX_DETECTORS_OFF=1   — session-learner.js detectors emit []
#   * CORTEX_AUTODISTILL_OFF=1 — distill_engine.run_auto_distill skips
#
# For each switch we set up a sandboxed CORTEX_DIR, drive the relevant hook
# with a deterministic input, and assert that the state files the switch
# claims to leave untouched are in fact untouched. We then re-run WITHOUT
# the switch as a negative control to make sure the same input DOES mutate
# state (catches the bug where the switch hides a separate problem).

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

OBSERVE_PY="$PROJECT_ROOT/hooks/observe.py"
LEARNER_JS="$PROJECT_ROOT/hooks/session-learner.js"
DISTILL_PY="$PROJECT_ROOT/hooks/lib/distill_engine.py"

echo "=== Kill Switches Tests (v3.29.0 §4.8) ==="

# ── Test 1: CORTEX_OBSERVE_OFF — observe.py creates nothing ──────────────────
echo "--- Test 1: CORTEX_OBSERVE_OFF ---"
T1="$(mktemp -d -t cortex-killsw-t1-XXXXXX)"
trap 'rm -rf "$T1"' EXIT

# Fixture: a minimal post-tool hook payload that would normally produce an
# observation. observe.py only writes when (a) hook_event_name is present
# (it's how it distinguishes legitimate hook invocations from raw stdin),
# and (b) cwd is a real git directory (so detect_project returns a
# non-empty project_id rather than 'global' with no anchor). We use this
# repo's root as cwd because we know it exists and is a git checkout.
REPO_CWD="$PROJECT_ROOT"
fixture_event=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/killsw-fixture.txt"},"tool_output":"ok","session_id":"sess-killsw-uuid","hook_event_name":"PostToolUse","cwd":"%s"}' "$REPO_CWD" "$REPO_CWD")

# observe.py's dedup directory defaults to $XDG_RUNTIME_DIR/cortex-<uid>/ or
# $TMPDIR/cortex-<uid>/ — a per-user location SHARED across CORTEX_DIR
# sandboxes. Without isolating it, the first call writes a dedup hash that
# kills every subsequent call from a different sandbox in the same test run
# (silent skip via is_duplicate). Override XDG_RUNTIME_DIR to a sandbox path
# so each test's dedup state is bounded by its own $T1.
mkdir -p "$T1/runtime"
RUNTIME_OVERRIDE="$T1/runtime"

# Run WITH the switch — must NOT create any observations.jsonl anywhere.
CORTEX_DIR="$T1" CORTEX_OBSERVE_OFF=1 XDG_RUNTIME_DIR="$RUNTIME_OVERRIDE" \
  bash -c "echo '$fixture_event' | python3 '$OBSERVE_PY' post" >/dev/null 2>&1 || true

# Count any observations.jsonl files written under the sandbox.
created=$(find "$T1" -name 'observations.jsonl' 2>/dev/null | wc -l | tr -d ' ')
[ "$created" = "0" ] && pass "OBSERVE_OFF=1 → no observations.jsonl written" \
                    || fail "OBSERVE_OFF: observations.jsonl appeared ($created files)"

# Negative control: same input WITHOUT the switch must produce at least one.
CORTEX_DIR="$T1" XDG_RUNTIME_DIR="$RUNTIME_OVERRIDE" \
  bash -c "echo '$fixture_event' | python3 '$OBSERVE_PY' post" >/dev/null 2>&1 || true
created=$(find "$T1" -name 'observations.jsonl' 2>/dev/null | wc -l | tr -d ' ')
[ "$created" -ge "1" ] && pass "OBSERVE_OFF=0 negative control → observations.jsonl created" \
                      || fail "OBSERVE_OFF negative control: nothing written (control broken)"

rm -rf "$T1"
trap - EXIT

# ── Test 2: CORTEX_DETECTORS_OFF — session-learner.js writes no proposals ────
echo "--- Test 2: CORTEX_DETECTORS_OFF ---"
T2="$(mktemp -d -t cortex-killsw-t2-XXXXXX)"
trap 'rm -rf "$T2"' EXIT

# Project sandbox: registry + observations with a clear error→fix pair that
# detectErrorResolutions would otherwise emit.
PROJ_ID="killsw-proj"
mkdir -p "$T2/projects/$PROJ_ID"
cat > "$T2/projects/registry.json" <<JSON
{ "$PROJ_ID": { "name": "killsw-proj", "root": "/tmp/killsw" } }
JSON
cat > "$T2/projects/$PROJ_ID/observations.jsonl" <<'OBS'
{"ts":"2026-05-15T09:59:58Z","ev":"ts","tool":"Bash","err":false,"input":"{\"command\":\"pytest --workspace api\"}","sid":"sess-killsw","pid":"killsw-proj","pname":"killsw-proj"}
{"ts":"2026-05-15T10:00:00Z","ev":"tc","tool":"Bash","err":true,"err_msg":"pytest --workspace api failed with exit code 1","sid":"sess-killsw","pid":"killsw-proj","pname":"killsw-proj","output":"FAILED tests/test_api.py::test_auth"}
{"ts":"2026-05-15T10:00:30Z","ev":"ts","tool":"Edit","err":false,"sid":"sess-killsw","pid":"killsw-proj","pname":"killsw-proj","input":"{\"file_path\":\"/tmp/killsw/auth.py\",\"old_string\":\"return None\",\"new_string\":\"return token\"}"}
{"ts":"2026-05-15T10:00:31Z","ev":"tc","tool":"Edit","err":false,"sid":"sess-killsw","pid":"killsw-proj","pname":"killsw-proj","output":"ok"}
OBS

# Drive with stdin = harness session payload.
stdin_payload='{"session_id":"sess-killsw"}'

CORTEX_DIR="$T2" CORTEX_DETECTORS_OFF=1 \
  bash -c "echo '$stdin_payload' | node '$LEARNER_JS'" >/dev/null 2>&1 || true

# proposals.json should NOT exist (the learner only writes it when at least
# one detector returned a proposal).
if [ -e "$T2/proposals.json" ]; then
  size=$(wc -c < "$T2/proposals.json" | tr -d ' ')
  # Empty file or a literal "[]" would be acceptable too, but the learner
  # currently skips the write entirely when there's nothing — so existence
  # itself is the right signal.
  fail "DETECTORS_OFF=1 → proposals.json was created (size=$size)"
else
  pass "DETECTORS_OFF=1 → proposals.json not created"
fi

# Negative control: same fixture WITHOUT the switch must produce a proposal.
rm -f "$T2/proposals.json"
CORTEX_DIR="$T2" \
  bash -c "echo '$stdin_payload' | node '$LEARNER_JS'" >/dev/null 2>&1 || true
if [ -e "$T2/proposals.json" ] && [ "$(wc -c < "$T2/proposals.json" | tr -d ' ')" -gt "5" ]; then
  pass "DETECTORS_OFF=0 negative control → proposals.json created with content"
else
  fail "DETECTORS_OFF negative control: proposals.json missing or empty"
fi

rm -rf "$T2"
trap - EXIT

# ── Test 3: CORTEX_AUTODISTILL_OFF — distill_engine skips the pipeline ───────
echo "--- Test 3: CORTEX_AUTODISTILL_OFF ---"
T3="$(mktemp -d -t cortex-killsw-t3-XXXXXX)"
trap 'rm -rf "$T3"' EXIT

# Seed: one pending whitelisted proposal that, if auto-validate runs, would
# materialise as an instinct YAML.
cat > "$T3/proposals.json" <<'JSON'
[
  {
    "id": "killsw-gotcha",
    "trigger": "Bash",
    "action": "Always run tests before push",
    "confidence": 0.60,
    "domain": "error-recovery",
    "scope": "global",
    "project_id": "global",
    "project_name": "cross-project",
    "tags": [],
    "detected": "2026-05-15",
    "source": "cx-analyze",
    "status": "pending"
  }
]
JSON

run_distill() {
  # $1 = "on" (kill switch enabled) | "off" (disabled, negative control)
  local mode="$1"
  if [ "$mode" = "on" ]; then
    CORTEX_DIR="$T3" CORTEX_AUTODISTILL_OFF=1 python3 - <<PYEOF
import sys, os
sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T3')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
de.PROPOSALS_FILE = de.CORTEX_DIR / 'proposals.json'
de.EVOLVED_SKILLS_DIR = de.CORTEX_DIR / 'evolved' / 'skills'
de.SKILLS_DIR = de.CORTEX_DIR / 'skills'
r = de.run_auto_distill()
print(r.get('skipped_reason'))
PYEOF
  else
    CORTEX_DIR="$T3" python3 - <<PYEOF
import sys, os
sys.path.insert(0, '$PROJECT_ROOT/hooks/lib')
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$T3')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.MARKER_FILE = de.CORTEX_DIR / '.last-auto-distill'
de.LOCK_FILE = de.CORTEX_DIR / '.distill-engine.lock'
de.PROPOSALS_FILE = de.CORTEX_DIR / 'proposals.json'
de.EVOLVED_SKILLS_DIR = de.CORTEX_DIR / 'evolved' / 'skills'
de.SKILLS_DIR = de.CORTEX_DIR / 'skills'
r = de.run_auto_distill()
print(r.get('skipped_reason'))
PYEOF
  fi
}

skipped=$(run_distill on)
# (1) Return value reports the right reason.
[ "$skipped" = "autodistill-off" ] && pass "AUTODISTILL_OFF=1 → skipped_reason='autodistill-off'" \
                                  || fail "AUTODISTILL_OFF: skipped_reason='$skipped'"
# (2) No instinct YAML created.
if [ -e "$T3/instincts/global/killsw-gotcha.yaml" ]; then
  fail "AUTODISTILL_OFF=1 → instinct YAML was created"
else
  pass "AUTODISTILL_OFF=1 → no instinct YAML created"
fi
# (3) No marker file (so a subsequent un-gated run is not rate-limited).
[ -e "$T3/.last-auto-distill" ] && fail "AUTODISTILL_OFF=1 → .last-auto-distill marker appeared" \
                                || pass "AUTODISTILL_OFF=1 → no .last-auto-distill marker"
# (4) Proposal status untouched.
if grep -q '"status": "pending"' "$T3/proposals.json"; then
  pass "AUTODISTILL_OFF=1 → proposal status still 'pending'"
else
  fail "AUTODISTILL_OFF=1 → proposal status changed"
fi

# Negative control: removing the switch must run the pipeline. The proposal
# is whitelisted (error-recovery, conf 0.60) so it should auto-validate.
skipped=$(run_distill off)
[ "$skipped" = "None" ] && pass "AUTODISTILL_OFF=0 negative control → skipped_reason=None" \
                       || fail "AUTODISTILL_OFF negative control: skipped_reason='$skipped'"
if [ -e "$T3/instincts/global/killsw-gotcha.yaml" ]; then
  pass "AUTODISTILL_OFF=0 negative control → instinct YAML created"
else
  fail "AUTODISTILL_OFF negative control: instinct not created (control broken)"
fi

rm -rf "$T3"
trap - EXIT

# ── Test 4: noisy_detectors_off — correction/coupling gated, error-fix kept ──
echo "--- Test 4: noisy_detectors_off (v3.34.1) ---"
T4="$(mktemp -d -t cortex-killsw-t4-XXXXXX)"
trap 'rm -rf "$T4"' EXIT

PROJ4="nz-proj"
mkdir -p "$T4/projects/$PROJ4"
cat > "$T4/projects/registry.json" <<JSON
{ "$PROJ4": { "name": "nz-proj", "root": "/tmp/nz" } }
JSON
# Same file edited 3x with overlapping regions → fires detectUserCorrections.
cat > "$T4/projects/$PROJ4/observations.jsonl" <<'OBS'
{"ts":"2026-05-15T10:00:00Z","ev":"PostToolUse","tool":"Edit","input":"{\"file_path\":\"/tmp/nz/app.ts\",\"old_string\":\"const x = 1\"}","output":"ok","err":false,"sid":"sess-nz","pid":"nz-proj"}
{"ts":"2026-05-15T10:01:00Z","ev":"PostToolUse","tool":"Edit","input":"{\"file_path\":\"/tmp/nz/app.ts\",\"old_string\":\"const x = 1;\"}","output":"ok","err":false,"sid":"sess-nz","pid":"nz-proj"}
{"ts":"2026-05-15T10:02:00Z","ev":"PostToolUse","tool":"Edit","input":"{\"file_path\":\"/tmp/nz/app.ts\",\"old_string\":\"const x = 1; //\"}","output":"ok","err":false,"sid":"sess-nz","pid":"nz-proj"}
OBS
stdin4='{"session_id":"sess-nz"}'

# WITH the flag (env override) → 0 correction/coupling proposals.
CORTEX_DIR="$T4" CORTEX_NOISY_DETECTORS_OFF=1 \
  bash -c "echo '$stdin4' | node '$LEARNER_JS'" >/dev/null 2>&1 || true
if [ -e "$T4/proposals.json" ]; then
  leaked=$(grep -cE '"session-learner:(correction|file-coupling)"' "$T4/proposals.json" 2>/dev/null || true)
else
  leaked=0
fi
[ "${leaked:-0}" = "0" ] && pass "NOISY_DETECTORS_OFF=1 → 0 correction/coupling proposals" \
                        || fail "NOISY_OFF=1: $leaked correction/coupling leaked"

# Negative control: WITHOUT the flag the same fixture DOES emit a correction.
rm -f "$T4/proposals.json"
CORTEX_DIR="$T4" \
  bash -c "echo '$stdin4' | node '$LEARNER_JS'" >/dev/null 2>&1 || true
if [ -e "$T4/proposals.json" ] && grep -qE '"session-learner:correction"' "$T4/proposals.json"; then
  pass "NOISY_DETECTORS_OFF=0 negative control → correction proposal created"
else
  fail "NOISY negative control: no correction proposal (control broken)"
fi

rm -rf "$T4"
trap - EXIT

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
