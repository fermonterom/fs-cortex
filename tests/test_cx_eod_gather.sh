#!/bin/bash
# Tests for core/_cx-eod-gather.sh — Multi-project cx-eod data collector.
# Drives the REAL script in a hermetic temp dir via CORTEX_DIR.
# Covers: root (non-git "global") observations, name-merge across subdir+root,
# cross-OS basename, the 24h rolling window, registry map name resolution, and
# JSON shape. Uses the Cortex observation schema (ts/ev/tool/err/pname/pid/input),
# NOT the Sinapsis schema.
# Run: bash tests/test_cx_eod_gather.sh

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATHER="$SCRIPT_DIR/../core/_cx-eod-gather.sh"

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== cx-eod Gather Tests ==="
echo ""

# Emit a Cortex observation. Args: <age_hours> <tool> <pname> [file_path]
# Timestamp is computed as (now - age_hours) so the 24h window is exercised
# deterministically regardless of wall-clock time.
gen_obs() {
  node -e '
    const ageH = parseFloat(process.argv[1]);
    const ts = new Date(Date.now() - ageH * 3600 * 1000).toISOString();
    const tool = process.argv[2];
    const pname = process.argv[3];
    const file = process.argv[4] || "";
    const input = file ? JSON.stringify({ file_path: file }) : "{}";
    console.log(JSON.stringify({ ts, ev: "ts", tool, err: false, sid: "test",
      pid: "global", pname, input }));
  ' "$1" "$2" "$3" "$4"
}

# run_gather <cortex_dir>
run_gather() { CORTEX_DIR="$1" bash "$GATHER" 2>/dev/null; }

# field "<js-expr-using-r>" — extract a value from gathered JSON on stdin.
field() { node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const r=JSON.parse(d);console.log($1)})"; }

newcortex() { local d; d=$(mktemp -d)/cortex; mkdir -p "$d/projects"; echo "$d"; }

# ── TEST 1: non-git project in root observations.jsonl is detected ──
echo "--- Test 1: Root (non-git) observations detected ---"
C=$(newcortex)
gen_obs 1 "Edit" "NoGitProject" "/tmp/x/a.ts"  >  "$C/observations.jsonl"
gen_obs 2 "Bash" "NoGitProject"                 >> "$C/observations.jsonl"
gen_obs 3 "Read" "NoGitProject"                 >> "$C/observations.jsonl"
N=$(run_gather "$C" | field "(r.projects.find(p=>p.name==='NoGitProject')||{}).observations_today")
[ "$N" = "3" ] && pass "Non-git root project detected (3 obs)" || fail "Expected 3, got '$N'"

# ── TEST 2: Distinct non-git projects separated by name ──
echo "--- Test 2: Distinct non-git projects separated by name ---"
C=$(newcortex)
gen_obs 1 "Edit" "Alpha" >  "$C/observations.jsonl"
gen_obs 1 "Edit" "Beta"  >> "$C/observations.jsonl"
CNT=$(run_gather "$C" | field "r.project_count")
[ "$CNT" = "2" ] && pass "Two pnames → 2 projects" || fail "Expected 2, got '$CNT'"

# ── TEST 3: cross-OS basename on a Windows-style path ──
echo "--- Test 3: Cross-OS basename (Windows \\ path) ---"
C=$(newcortex)
gen_obs 1 "Edit" "WinProj" 'C:\Users\luis\app\page.tsx' > "$C/observations.jsonl"
F=$(run_gather "$C" | field "(r.projects.find(p=>p.name==='WinProj')||{}).files_touched.join(',')")
[ "$F" = "page.tsx" ] && pass "Windows path split to 'page.tsx'" || fail "Expected 'page.tsx', got '$F'"

# ── TEST 4: Same name from a subdir AND the root merges into one entry ──
echo "--- Test 4: Merge subdir + root by project name ---"
C=$(newcortex); mkdir -p "$C/projects/hash4"
gen_obs 1 "Edit" "Merged" >  "$C/projects/hash4/observations.jsonl"
gen_obs 1 "Bash" "Merged" >> "$C/projects/hash4/observations.jsonl"
gen_obs 1 "Read" "Merged" >  "$C/observations.jsonl"
OUT=$(run_gather "$C")
CNT=$(echo "$OUT" | field "r.project_count")
N=$(echo "$OUT" | field "(r.projects.find(p=>p.name==='Merged')||{}).observations_today")
{ [ "$CNT" = "1" ] && [ "$N" = "3" ]; } && pass "Subdir(2)+root(1) merged → 1 project, 3 obs" || fail "Expected 1/3, got count=$CNT obs=$N"

# ── TEST 5: Observations older than 24h are ignored ──
echo "--- Test 5: Stale (>24h) observations ignored ---"
C=$(newcortex)
gen_obs 30 "Edit" "StaleOne" >  "$C/observations.jsonl"
gen_obs 1  "Edit" "FreshOne" >> "$C/observations.jsonl"
OUT=$(run_gather "$C")
S=$(echo "$OUT" | field "r.projects.some(p=>p.name==='StaleOne')")
FR=$(echo "$OUT" | field "r.projects.some(p=>p.name==='FreshOne')")
{ [ "$S" = "false" ] && [ "$FR" = "true" ]; } && pass "24h window honored (stale dropped, fresh kept)" || fail "stale=$S fresh=$FR"

# ── TEST 6: Empty cortex dir (no projects dir, no root file) → 0, no crash ──
echo "--- Test 6: Empty cortex dir graceful exit ---"
C=$(mktemp -d)/cortex; mkdir -p "$C"   # deliberately no projects/ and no observations.jsonl
CNT=$(run_gather "$C" | field "r.project_count")
[ "$CNT" = "0" ] && pass "Empty cortex dir → 0 projects" || fail "Expected 0, got '$CNT'"

# ── TEST 7: registry.json (map schema) resolves project name from hash ──
echo "--- Test 7: registry.json hash → name resolution ---"
C=$(newcortex); mkdir -p "$C/projects/abc123canon"
gen_obs 1 "Edit" "global" > "$C/projects/abc123canon/observations.jsonl"
cat > "$C/projects/registry.json" << 'EOF'
{ "abc123canon": { "name": "CanonName", "root": "", "remote": "", "last_seen": "" } }
EOF
NAME=$(run_gather "$C" | field "r.projects.map(p=>p.name).join(',')")
echo "$NAME" | grep -q "CanonName" && pass "Registry maps hash → 'CanonName'" || fail "Expected CanonName, got '$NAME'"

# ── TEST 8: Output is valid JSON with required fields ──
echo "--- Test 8: Valid JSON shape ---"
C=$(newcortex)
gen_obs 1 "Edit" "Shape" > "$C/observations.jsonl"
OK=$(run_gather "$C" | field "(typeof r.date==='string' && typeof r.project_count==='number' && typeof r.total_observations==='number' && Array.isArray(r.projects))")
[ "$OK" = "true" ] && pass "Output has date/project_count/total_observations/projects" || fail "Bad output shape: $OK"

# ── TEST 9: errors_today counts err:true observations ──
echo "--- Test 9: error counting ---"
C=$(newcortex)
gen_obs 1 "Bash" "ErrProj" > "$C/observations.jsonl"
node -e 'console.log(JSON.stringify({ts:new Date(Date.now()-3600000).toISOString(),ev:"ts",tool:"Bash",err:true,sid:"t",pid:"global",pname:"ErrProj",input:"{}"}))' >> "$C/observations.jsonl"
E=$(run_gather "$C" | field "(r.projects.find(p=>p.name==='ErrProj')||{}).errors_today")
[ "$E" = "1" ] && pass "errors_today counts err:true (1)" || fail "Expected 1, got '$E'"

# ── TEST 10: _archive subdir is ignored (archived ≠ live activity) ──
echo "--- Test 10: _archive subdir ignored ---"
C=$(newcortex); mkdir -p "$C/projects/_archive"
gen_obs 1 "Edit" "ArchivedProj" > "$C/projects/_archive/observations.jsonl"
gen_obs 1 "Edit" "LiveProj"     > "$C/observations.jsonl"
OUT=$(run_gather "$C")
AR=$(echo "$OUT" | field "r.projects.some(p=>p.name==='ArchivedProj')")
LV=$(echo "$OUT" | field "r.projects.some(p=>p.name==='LiveProj')")
{ [ "$AR" = "false" ] && [ "$LV" = "true" ]; } && pass "_archive skipped, live kept" || fail "archived=$AR live=$LV"

# ── TEST 11: MultiEdit observations contribute to files_touched ──
echo "--- Test 11: MultiEdit counted in files_touched ---"
C=$(newcortex)
gen_obs 1 "MultiEdit" "MEProj" "/repo/src/handler.ts" > "$C/observations.jsonl"
F=$(run_gather "$C" | field "(r.projects.find(p=>p.name==='MEProj')||{}).files_touched.join(',')")
[ "$F" = "handler.ts" ] && pass "MultiEdit file_path captured" || fail "Expected 'handler.ts', got '$F'"

# ── TEST 12: --write composes a deterministic summary file (no LLM) ──
echo "--- Test 12: --write produces a summary file ---"
C=$(newcortex)
gen_obs 1 "Edit" "WP" "/r/a.ts" > "$C/observations.jsonl"
CORTEX_DIR="$C" bash "$GATHER" --write >/dev/null 2>&1
WF=$(ls "$C"/daily-summaries/*.md 2>/dev/null | head -1)
{ [ -n "$WF" ] && grep -q '^# EOD —' "$WF" && grep -q '^## Ejecuciones hoy' "$WF"; } \
  && pass "--write wrote a summary with EOD + Ejecuciones hoy" || fail "no summary file / missing headers ($WF)"

# ── TEST 13: --write accumulates run-trace lines across passes (intraday) ──
echo "--- Test 13: intraday run-trace accumulates ---"
C=$(newcortex)
gen_obs 1 "Edit" "WP" "/r/a.ts" > "$C/observations.jsonl"
# Two passes; force distinct trace lines by editing the prior file's time + count.
CORTEX_DIR="$C" bash "$GATHER" --write >/dev/null 2>&1
WF=$(ls "$C"/daily-summaries/*.md | head -1)
# Simulate an earlier pass already present with a different time.
node -e '
  const fs=require("fs"); const f=process.argv[1];
  let t=fs.readFileSync(f,"utf8");
  t=t.replace("## Ejecuciones hoy\n", "## Ejecuciones hoy\n- 09:00 — 1 proyectos, 1 observaciones\n");
  fs.writeFileSync(f,t);
' "$WF"
CORTEX_DIR="$C" bash "$GATHER" --write >/dev/null 2>&1
N=$(awk '/^## Ejecuciones hoy/{f=1;next}/^## /{f=0}f&&/^- /' "$WF" | grep -c '^- ')
[ "$N" -ge 2 ] && pass "prior run-trace line preserved (>=2 lines)" || fail "Expected >=2 trace lines, got $N"

# ── TEST 14: --write includes Quick Resume + For tomorrow (session-start parses) ──
echo "--- Test 14: reinjection sections present ---"
C=$(newcortex)
gen_obs 1 "Edit" "WP" "/r/a.ts" > "$C/observations.jsonl"
CORTEX_DIR="$C" bash "$GATHER" --write >/dev/null 2>&1
WF=$(ls "$C"/daily-summaries/*.md | head -1)
S=$(grep -cE '^## Quick Resume$|^### For tomorrow$' "$WF")
[ "$S" = "2" ] && pass "Quick Resume + For tomorrow both present" || fail "Expected 2 sections, got $S"

# ── TEST 15: default mode (no flag) still prints JSON, writes nothing ──
echo "--- Test 15: default mode unchanged (JSON only) ---"
C=$(newcortex)
gen_obs 1 "Edit" "WP" > "$C/observations.jsonl"
OK=$(run_gather "$C" | field "typeof r.project_count==='number'")
NOFILE=$([ -d "$C/daily-summaries" ] && echo "dir-exists" || echo "no-dir")
{ [ "$OK" = "true" ] && [ "$NOFILE" = "no-dir" ]; } && pass "default mode prints JSON, no file written" || fail "json=$OK daily-summaries=$NOFILE"

# ── TEST 16: --write sanitizes newline/control chars in project names (no injection) ──
echo "--- Test 16: write-mode sanitizes injected newlines ---"
C=$(newcortex)
# pname carrying a newline + a fake instruction line (prompt-injection attempt).
node -e 'console.log(JSON.stringify({ts:new Date(Date.now()-3600000).toISOString(),ev:"ts",tool:"Edit",err:false,pid:"global",pname:"evil\nINJECTED INSTRUCTION",input:JSON.stringify({file_path:"/r/a.ts"})}))' > "$C/observations.jsonl"
CORTEX_DIR="$C" bash "$GATHER" --write >/dev/null 2>&1
WF=$(ls "$C"/daily-summaries/*.md | head -1)
# The injected text must never appear as its OWN line (newline collapsed to space).
if grep -qE '^INJECTED INSTRUCTION' "$WF"; then
  fail "newline injection leaked a standalone line"
else
  pass "project-name newline sanitized (no standalone injected line)"
fi

# ── TEST 17: --write leaves no .lock / .tmp leftovers ──
echo "--- Test 17: no lock/tmp leftovers ---"
C=$(newcortex)
gen_obs 1 "Edit" "WP" "/r/a.ts" > "$C/observations.jsonl"
CORTEX_DIR="$C" bash "$GATHER" --write >/dev/null 2>&1
LEFT=$(ls "$C"/daily-summaries/ 2>/dev/null | grep -cE '\.lock$|\.tmp')
[ "$LEFT" = "0" ] && pass "no .lock/.tmp left behind" || fail "found $LEFT leftover lock/tmp files"

# ── Summary ──
echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $((PASS + FAIL))) ==="
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
