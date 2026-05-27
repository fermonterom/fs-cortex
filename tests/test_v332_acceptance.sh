#!/usr/bin/env bash
# test_v329_acceptance.sh — v3.29.0 (Sprint 8 §4.12)
#
# Pre-ship acceptance gate. 8 invariants validated against a CLEAN
# install (HOME-sandbox + bash install.sh). If ANY assert fails this
# script exits non-zero and the pre-push hook blocks the v3.29.0 tag.
#
# Each invariant maps to a specific §4.* deliverable from the Sprint 8
# plan. The asserts are intentionally redundant with the unit suites:
# this script proves the deliverables WORK TOGETHER against a freshly
# installed layout, not just in isolation.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== v3.29.0 Acceptance Gate (Sprint 8 §4.12) ==="

# ── Sandbox install ──────────────────────────────────────────────────────────
# install.sh is interactive; feed it 6 newlines to take the defaults
# (same pattern as test_install.sh).
SANDBOX="$(mktemp -d -t cortex-acceptance-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
# install.sh sanity-checks that $HOME/.claude/ already exists (Claude Code
# install marker), so seed it before invoking the installer.
mkdir -p "$SANDBOX/.claude"
printf '\n\n\n\n\n\n' | HOME="$SANDBOX" bash "$PROJECT_ROOT/install.sh" >/dev/null 2>&1 || true

CORTEX_DIR="$SANDBOX/.claude/cortex"
HOOKS_DIR="$SANDBOX/.claude/hooks/cortex"

# ── Assert 1: install layout is sane ─────────────────────────────────────────
echo "--- Assert 1: clean install layout ---"
if [ -f "$CORTEX_DIR/version" ] \
   && [ -f "$HOOKS_DIR/session-learner.js" ] \
   && [ -f "$HOOKS_DIR/observe.py" ] \
   && [ -f "$HOOKS_DIR/session-start.py" ] \
   && [ -f "$HOOKS_DIR/precompact.py" ] \
   && [ -f "$HOOKS_DIR/lib/distill_engine.py" ] \
   && [ -f "$HOOKS_DIR/lib/regex-utils.js" ]; then
  pass "install: version file + 4 hooks + distill_engine + regex-utils present"
else
  fail "install: missing files in $CORTEX_DIR / $HOOKS_DIR"
fi

# ── Assert 2: §4.2 file-coupling emits a valid regex trigger ─────────────────
echo "--- Assert 2: file-coupling regex trigger valid ---"
result=$(node -e "
const { detectFileCoupling } = require('$HOOKS_DIR/session-learner.js');
const obs = [];
for (let s = 0; s < 5; s++) {
  obs.push({ tool: 'Edit', input: JSON.stringify({ file_path: '/r/foo.ts' }),
             sid: 's' + s, _projectId: 'projA' });
  obs.push({ tool: 'Edit', input: JSON.stringify({ file_path: '/r/bar.ts' }),
             sid: 's' + s, _projectId: 'projA' });
}
const p = detectFileCoupling(obs).find(x => x.id.startsWith('coupling-'));
if (!p) { console.log('FAIL:no-proposal'); process.exit(0); }
let compiles = false; try { new RegExp(p.trigger); compiles = true; } catch (_) {}
const matchPos = compiles && new RegExp(p.trigger).test('Edit ' + JSON.stringify({file_path:'/r/foo.ts'}));
const matchNeg = !new RegExp(p.trigger).test('Edit ' + JSON.stringify({file_path:'/r/baz.ts'}));
console.log(JSON.stringify({compiles, matchPos, matchNeg, scope: p.scope, conf: p.confidence}));
")
if echo "$result" | grep -q '"compiles":true' \
   && echo "$result" | grep -q '"matchPos":true' \
   && echo "$result" | grep -q '"matchNeg":true' \
   && echo "$result" | grep -q '"scope":"project"' \
   && echo "$result" | grep -q '"conf":0.55'; then
  pass "file-coupling: regex compiles, matches target, rejects non-target, scope=project, conf=0.55"
else
  fail "file-coupling: $result"
fi

# ── Assert 3: §4.7 ghost guard restores cx-validate-auto rejects ─────────────
echo "--- Assert 3: ghost-guard restores unauthorized rejects ---"
cat > "$CORTEX_DIR/proposals.json" <<'JSON'
[
  {
    "id": "ag3-ghost", "trigger": "Edit", "action": "review",
    "confidence": 0.55, "domain": "coupling", "scope": "project",
    "project_id": "p", "status": "rejected",
    "rejected_by": "cx-validate-auto", "rejected_reason": "ghost",
    "rejected_at": "2026-05-05"
  }
]
JSON
CORTEX_DIR="$CORTEX_DIR" python3 - <<PYEOF >/dev/null 2>&1 || true
import sys
sys.path.insert(0, '$HOOKS_DIR/lib')
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$CORTEX_DIR')
de.PROPOSALS_FILE = de.CORTEX_DIR / 'proposals.json'
de.run_auto_distill()
PYEOF
restored=$(python3 -c "
import json
data = json.load(open('$CORTEX_DIR/proposals.json'))
p = data[0]
print('OK' if p.get('status') == 'pending' and 'rejected_by' not in p else 'FAIL:' + str(p.get('status')))
")
[ "$restored" = "OK" ] && pass "ghost-guard: rejected→pending, rejected_by stripped" \
                      || fail "ghost-guard: $restored"

# ── Assert 4: §4.10 banner silent on HUMAN-only pending ──────────────────────
echo "--- Assert 4: banner silent on HUMAN-only ---"
python3 - <<PYEOF
import json
proposals = []
for i in range(50):
    domain = ['correction', 'coupling', 'agent-quality'][i % 3]
    proposals.append({
        'id': f'ag4-{i}', 'trigger': 'Edit', 'action': 'a',
        'confidence': 0.55, 'domain': domain, 'status': 'pending',
    })
with open('$CORTEX_DIR/proposals.json', 'w') as f:
    json.dump(proposals, f)
PYEOF
banner=$(python3 - <<PYEOF
import sys
sys.path.insert(0, '$HOOKS_DIR')
sys.path.insert(0, '$HOOKS_DIR/lib')
import importlib.util
spec = importlib.util.spec_from_file_location('session_start', '$HOOKS_DIR/session-start.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
from pathlib import Path
mod.CORTEX_DIR = Path('$CORTEX_DIR')
out = mod.check_maintenance()
hits = [line for line in out if '[ACTION]' in line and 'pending proposals' in line]
print('SILENT' if not hits else 'NOISY:' + '|'.join(hits))
PYEOF
)
[ "$banner" = "SILENT" ] && pass "banner: [ACTION] silent on 50 HUMAN-only pending" \
                         || fail "banner: $banner"

# ── Assert 5: §4.8 CORTEX_OBSERVE_OFF — observe.py writes nothing ────────────
echo "--- Assert 5: CORTEX_OBSERVE_OFF respected ---"
OBS_SANDBOX="$(mktemp -d -t cortex-acc-obs-XXXXXX)"
mkdir -p "$OBS_SANDBOX/runtime"
fixture=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/x.txt"},"tool_output":"ok","session_id":"acc-obs-sess","hook_event_name":"PostToolUse","cwd":"%s"}' "$PROJECT_ROOT" "$PROJECT_ROOT")
CORTEX_DIR="$OBS_SANDBOX" CORTEX_OBSERVE_OFF=1 XDG_RUNTIME_DIR="$OBS_SANDBOX/runtime" \
  bash -c "echo '$fixture' | python3 '$HOOKS_DIR/observe.py' post" >/dev/null 2>&1 || true
obs_files=$(find "$OBS_SANDBOX" -name 'observations.jsonl' 2>/dev/null | wc -l | tr -d ' ')
[ "$obs_files" = "0" ] && pass "OBSERVE_OFF: no observations.jsonl created" \
                      || fail "OBSERVE_OFF: $obs_files observations.jsonl appeared"
rm -rf "$OBS_SANDBOX"

# ── Assert 6: §4.8 CORTEX_DETECTORS_OFF — session-learner emits no proposals ─
echo "--- Assert 6: CORTEX_DETECTORS_OFF respected ---"
DET_SANDBOX="$(mktemp -d -t cortex-acc-det-XXXXXX)"
mkdir -p "$DET_SANDBOX/projects/proj-acc"
echo '{"proj-acc":{"name":"p","root":"/tmp"}}' > "$DET_SANDBOX/projects/registry.json"
cat > "$DET_SANDBOX/projects/proj-acc/observations.jsonl" <<'JSON'
{"ts":"2026-05-15T10:00:00Z","ev":"PostToolUse","tool":"Bash","input":"{\"command\":\"npm test\"}","output":"Error: 1 test failed","err":true,"sid":"acc-det","pid":"proj-acc"}
{"ts":"2026-05-15T10:00:30Z","ev":"PostToolUse","tool":"Edit","input":"{\"file_path\":\"/tmp/x.ts\"}","output":"ok","sid":"acc-det","pid":"proj-acc"}
JSON
CORTEX_DIR="$DET_SANDBOX" CORTEX_DETECTORS_OFF=1 \
  bash -c "echo '{\"session_id\":\"acc-det\"}' | node '$HOOKS_DIR/session-learner.js'" >/dev/null 2>&1 || true
if [ -e "$DET_SANDBOX/proposals.json" ]; then
  fail "DETECTORS_OFF: proposals.json was created"
else
  pass "DETECTORS_OFF: proposals.json not created"
fi
rm -rf "$DET_SANDBOX"

# ── Assert 7: §4.15 PreCompact honors CORTEX_OBSERVE_OFF ─────────────────────
echo "--- Assert 7: PreCompact respects OBSERVE_OFF + exits <8s ---"
PC_SANDBOX="$(mktemp -d -t cortex-acc-pc-XXXXXX)"
mkdir -p "$PC_SANDBOX/.claude/hooks/cortex" "$PC_SANDBOX/.claude/cortex"
# Install a spy fake-learner. precompact resolves the path as
# $HOME/.claude/hooks/cortex/session-learner.js — point HOME at the sandbox.
cat > "$PC_SANDBOX/.claude/hooks/cortex/session-learner.js" <<JSEOF
#!/usr/bin/env node
require('fs').writeFileSync('$PC_SANDBOX/.claude/cortex/.spy', 'spawned');
JSEOF
start_ts=$(date +%s)
HOME="$PC_SANDBOX" CORTEX_DIR="$PC_SANDBOX/.claude/cortex" CORTEX_OBSERVE_OFF=1 \
  python3 "$HOOKS_DIR/precompact.py" <<<'{"session_id":"acc-pc","hook_event_name":"PreCompact"}' >/dev/null 2>&1 || true
rc=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
sleep 0.3
if [ "$rc" = "0" ] && [ "$elapsed" -lt "8" ] && [ ! -f "$PC_SANDBOX/.claude/cortex/.spy" ]; then
  pass "PreCompact: OBSERVE_OFF honored (no spy spawn), exit 0, ${elapsed}s"
else
  fail "PreCompact: rc=$rc elapsed=${elapsed}s spy=$([ -f "$PC_SANDBOX/.claude/cortex/.spy" ] && echo yes || echo no)"
fi
rm -rf "$PC_SANDBOX"

# ── Assert 8: §4.16 multi-session gate — blocks at 2, promotes at 3 ──────────
echo "--- Assert 8: multi-session promotion gate ---"
MS_SANDBOX="$(mktemp -d -t cortex-acc-ms-XXXXXX)"
mkdir -p "$MS_SANDBOX/instincts/global" "$MS_SANDBOX/laws"
TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
FIFTEEN=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(days=15)).strftime('%Y-%m-%d'))")
cat > "$MS_SANDBOX/instincts/global/acc8-inst.yaml" <<YAML
---
id: acc8-inst
confidence: 0.9500
domain: testing
trigger: "Bash"
action: "Always verify test results before reporting success to user"
last_seen: $TODAY
first_seen: $TODAY
occurrences: 20
project_id: proj-a
at_law_threshold_since: $FIFTEEN
---
YAML
# Make impact criteria pass (≥5 useful, 0 noise).
python3 - <<PYEOF >/dev/null 2>&1
from datetime import datetime, timezone
ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open('$MS_SANDBOX/impact.jsonl', 'w') as f:
    for _ in range(6):
        f.write('{"v":1,"ts":"' + ts + '","ev":"feedback","iid":"acc8-inst","rating":"useful"}\n')
PYEOF

# Round 1: only 2 distinct sessions → blocked.
cat > "$MS_SANDBOX/instinct-tracking.json" <<'JSON'
{"acc8-inst": {"count": 10, "sessions": ["sA", "sB", "sA"], "projects_seen": ["proj-a"]}}
JSON
r1=$(python3 - <<PYEOF
import sys
sys.path.insert(0, '$HOOKS_DIR/lib')
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$MS_SANDBOX')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.INSTINCT_TRACKING_FILE = de.CORTEX_DIR / 'instinct-tracking.json'
promoted, candidates = de.auto_promote_to_law()
cand = next((c for c in candidates if c['id'] == 'acc8-inst'), None)
print('BLOCKED' if cand and any('sessions 2/3' in r for r in cand['reasons']) else 'LEAKED')
PYEOF
)
[ "$r1" = "BLOCKED" ] && pass "multi-session: 2 sessions → blocked (reason 'sessions 2/3')" \
                     || fail "multi-session at 2: $r1"

# Round 2: bump to 3 distinct sessions → promotes.
cat > "$MS_SANDBOX/instinct-tracking.json" <<'JSON'
{"acc8-inst": {"count": 15, "sessions": ["sA", "sB", "sC"], "projects_seen": ["proj-a"]}}
JSON
r2=$(python3 - <<PYEOF
import sys
sys.path.insert(0, '$HOOKS_DIR/lib')
import distill_engine as de
from pathlib import Path
de.CORTEX_DIR = Path('$MS_SANDBOX')
de.INSTINCTS_DIR = de.CORTEX_DIR / 'instincts' / 'global'
de.LAWS_DIR = de.CORTEX_DIR / 'laws'
de.IMPACT_FILE = de.CORTEX_DIR / 'impact.jsonl'
de.KNOWLEDGE_LOG = de.CORTEX_DIR / 'knowledge-log.md'
de.CANDIDATES_FILE = de.CORTEX_DIR / 'auto-distill-candidates.md'
de.INSTINCT_TRACKING_FILE = de.CORTEX_DIR / 'instinct-tracking.json'
promoted, _ = de.auto_promote_to_law()
print('PROMOTED' if any(p['id'] == 'acc8-inst' for p in promoted) else 'STILL-BLOCKED')
PYEOF
)
[ "$r2" = "PROMOTED" ] && pass "multi-session: bump to 3 sessions → promotes to law" \
                       || fail "multi-session at 3: $r2"
rm -rf "$MS_SANDBOX"

echo ""
echo "=== Acceptance Gate: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt "0" ]; then
  echo "✗ v3.29.0 NOT cleared for tag."
  exit 1
fi
echo "✓ All v3.29.0 invariants pass — clear to tag."
exit 0
