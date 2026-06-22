#!/bin/bash
# cx-eod Gather — Multi-project activity collector
# fs-cortex
# Scans cortex/projects/<hash>/observations.jsonl AND the root
# cortex/observations.jsonl (where non-git "global" projects land) for the last
# 24 hours of activity across ALL registered projects.
# Cross-OS safe: handles a shared observations file (mixed \ and / paths,
# foreign roots absent locally). Groups by project name so the same project
# merges across machines even when the cwd differs.
# Outputs JSON with project names, observation counts, tools used, files touched,
# and git data. Called by /cx-eod. NO LLM. Pure deterministic Node.js.
#
# Cortex observation schema (NOT Sinapsis): each JSONL line is
#   { ts, ev, tool, err, sid, pid, pname, input(JSON string), output? }
#   - ts     ISO-8601 timestamp ("2026-06-19T08:34:29Z")
#   - tool   tool name (Bash/Read/Edit/Write/...)
#   - err    boolean error flag
#   - pid    project hash (matches projects/<hash>/ and registry key)
#   - pname  project name ("global" for non-git projects in the root file)
#   - input  verbatim tool input, JSON-encoded as a string
#
# Window: last 24 hours (rolling), matching the /cx-eod contract and timezone
# safety (a session that runs at 02:00 still sees the evening's work). The
# `date` field uses the LOCAL day to match hooks/session-start.py reinjection.
#
# Test override (default unchanged): CORTEX_DIR points the data dir elsewhere.
# Used by tests/test_cx_eod_gather.sh.

CORTEX_DIR="${CORTEX_DIR:-$HOME/.claude/cortex}"

# Mode: default "json" (print gather JSON for a caller to compose from).
# "--write"/"--auto" → "write" (compose + write the daily summary deterministically,
# no LLM — this is what a cron invokes directly, bypassing `claude -p`).
MODE="json"
case "${1:-}" in
  --write|--auto) MODE="write" ;;
esac

if [ "${CORTEX_EOD_DEBUG:-}" = "1" ]; then
  exec 2>>"$HOME/.claude/cortex/log/cx-eod-gather-debug.log"
fi

# Fast path only in json mode: nothing to gather → emit zero JSON without Node.
# In write mode we still run Node so it writes a "no activity" summary + trace.
if [ "$MODE" = "json" ] && [ ! -d "$CORTEX_DIR/projects" ] && [ ! -f "$CORTEX_DIR/observations.jsonl" ]; then
  echo '{"date":"'"$(date +%Y-%m-%d)"'","project_count":0,"total_observations":0,"projects":[]}'
  exit 0
fi

# shellcheck disable=SC2016  # the single-quoted body is JavaScript for `node -e`, not shell
GATHER_OUT=$(CX_EOD_MODE="$MODE" CORTEX_DIR="$CORTEX_DIR" node -e '
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const HOME = process.env.HOME || process.env.USERPROFILE || "";
const cortexDir = process.env.CORTEX_DIR || path.join(HOME, ".claude", "cortex");
const projectsDir = path.join(cortexDir, "projects");
const rootObsFile = path.join(cortexDir, "observations.jsonl");
const registryFile = path.join(projectsDir, "registry.json");

// LOCAL day (matches hooks/session-start.py datetime.now()).
const now = new Date();
const pad = n => String(n).padStart(2, "0");
const today = now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate());

// 24h rolling window cutoff.
const cutoffMs = now.getTime() - 24 * 60 * 60 * 1000;
function withinWindow(ts) {
  if (!ts) return false;
  const t = Date.parse(ts);
  return !isNaN(t) && t >= cutoffMs;
}

// Cross-OS basename: split on BOTH / and \ regardless of host platform.
// Node path.basename is platform-specific (posix ignores \), which corrupts
// Windows paths read on Mac/Linux and vice-versa when the file is shared.
function baseName(p) {
  if (!p) return null;
  const parts = String(p).split(/[\\/]/).filter(Boolean);
  return parts.length ? parts[parts.length - 1] : null;
}

// Load project registry: map schema { hash: { name, root, remote, last_seen } }.
let registry = {};
try {
  const raw = JSON.parse(fs.readFileSync(registryFile, "utf8"));
  for (const [k, v] of Object.entries(raw || {})) {
    if (v && (v.name || v.root)) registry[k] = { name: v.name, root: v.root };
  }
} catch (e) {}

// name -> root index (first wins). Recovers a LOCAL root for a project even when
// its observations were written on another machine with a different cwd.
const rootByName = {};
for (const k of Object.keys(registry)) {
  const info = registry[k] || {};
  if (info.name && info.root && !rootByName[info.name]) rootByName[info.name] = info.root;
}

// First candidate that exists on THIS machine, else "".
function resolveRoot(candidates) {
  for (const c of candidates) { if (c && fs.existsSync(c)) return c; }
  return "";
}

function parseRecent(obsFile) {
  let lines;
  try { lines = fs.readFileSync(obsFile, "utf8").trim().split("\n"); }
  catch (e) { return []; }
  const out = [];
  for (const line of lines) {
    if (!line) continue;
    try {
      const obj = JSON.parse(line);
      if (withinWindow(obj.ts)) out.push(obj);
    } catch (e) {}
  }
  return out;
}

// Git data for a root, only when it exists locally (foreign roots -> null).
function gitFor(projectRoot) {
  if (!projectRoot || !fs.existsSync(projectRoot)) return null;
  try {
    const branch = execFileSync("git", ["-C", projectRoot, "branch", "--show-current"],
      { stdio: ["pipe", "pipe", "pipe"], timeout: 3000 }).toString().trim();
    let commits = "";
    try {
      const author = execFileSync("git", ["-C", projectRoot, "config", "user.email"],
        { stdio: ["pipe", "pipe", "pipe"], timeout: 2000 }).toString().trim();
      if (author) {
        commits = execFileSync("git", ["-C", projectRoot, "log", "--oneline", "--since=24 hours ago", "--author=" + author],
          { stdio: ["pipe", "pipe", "pipe"], timeout: 5000 }).toString().trim();
      }
    } catch (e) {
      try {
        commits = execFileSync("git", ["-C", projectRoot, "log", "--oneline", "--since=24 hours ago"],
          { stdio: ["pipe", "pipe", "pipe"], timeout: 5000 }).toString().trim();
      } catch (e2) {}
    }
    let status = "";
    try {
      status = execFileSync("git", ["-C", projectRoot, "status", "-s"],
        { stdio: ["pipe", "pipe", "pipe"], timeout: 3000 }).toString().trim();
    } catch (e) {}
    return {
      branch: branch,
      commits_today: commits ? commits.split("\n").length : 0,
      commits_log: commits || "(no commits in last 24h)",
      uncommitted_files: status ? status.split("\n").length : 0,
      status: status || "(clean)"
    };
  } catch (e) {
    return null; // not a git repo or git error
  }
}

// Aggregate recent observations into a project record.
function summarize(recentLines, name, root, hash) {
  const tools = [...new Set(recentLines.filter(l => l.tool).map(l => l.tool))];
  const errorCount = recentLines.filter(l => l.err === true).length;
  const filesTouched = [...new Set(
    recentLines
      .filter(l => l.tool === "Edit" || l.tool === "Write" || l.tool === "MultiEdit" || l.tool === "NotebookEdit")
      .map(l => {
        try {
          const inp = typeof l.input === "string" ? JSON.parse(l.input || "{}") : (l.input || {});
          return baseName(inp.file_path || inp.notebook_path);
        } catch (e) { return null; }
      })
      .filter(Boolean)
  )].slice(0, 15);
  return {
    hash: hash || null,
    name: name,
    root: root || "",
    observations_today: recentLines.length,
    tools_used: tools,
    files_touched: filesTouched,
    errors_today: errorCount,
    git: gitFor(root)
  };
}

// Collect keyed by NAME so the same project from different machines / cwd /
// storage location merges into one entry (cross-OS stable).
const byName = {};
function add(rec) {
  if (!byName[rec.name]) { byName[rec.name] = rec; return; }
  const e = byName[rec.name];
  e.observations_today += rec.observations_today;
  e.errors_today += rec.errors_today;
  e.tools_used = [...new Set([...e.tools_used, ...rec.tools_used])];
  e.files_touched = [...new Set([...e.files_touched, ...rec.files_touched])].slice(0, 15);
  if (!e.git && rec.git) e.git = rec.git;
  if (!e.root && rec.root) e.root = rec.root;
  if (!e.hash && rec.hash) e.hash = rec.hash;
}

// 1) Per-project subdirs (git-tracked projects). Skips _archive and any dir
//    without its own observations.jsonl.
let entries = [];
try { entries = fs.readdirSync(projectsDir); } catch (e) {}
for (const hash of entries) {
  if (hash === "_archive") continue;            // archived projects are not live activity
  const obsFile = path.join(projectsDir, hash, "observations.jsonl");
  if (!fs.existsSync(obsFile)) continue;
  const recentLines = parseRecent(obsFile);
  if (recentLines.length === 0) continue;
  const info = registry[hash] || {};
  const seen = recentLines.find(l => l.pname && l.pname !== "global");
  const name = info.name || (seen ? seen.pname : hash);
  const root = resolveRoot([info.root, rootByName[name]]);
  add(summarize(recentLines, name, root, hash));
}

// 2) Root observations.jsonl — non-git projects land here with pname "global".
//    Group by pname (stable across OS even if cwd differs).
if (fs.existsSync(rootObsFile)) {
  const groups = {};
  for (const l of parseRecent(rootObsFile)) {
    const nm = l.pname || "global";
    (groups[nm] = groups[nm] || []).push(l);
  }
  for (const nm of Object.keys(groups)) {
    add(summarize(groups[nm], nm, resolveRoot([rootByName[nm]]), null));
  }
}

const projects = Object.values(byName).sort((a, b) => b.observations_today - a.observations_today);

const result = {
  date: today,
  project_count: projects.length,
  total_observations: projects.reduce((s, p) => s + p.observations_today, 0),
  projects
};

// Default mode: emit JSON for a caller to compose from.
if (process.env.CX_EOD_MODE !== "write") {
  console.log(JSON.stringify(result, null, 2));
  process.exit(0);
}

// --write mode: compose the daily summary markdown DETERMINISTICALLY (no LLM)
// and write it, so a cron can call this script directly without spending model
// quota. The interactive /cx-eod still lets Claude compose with judgment.
const summDir = path.join(cortexDir, "daily-summaries");
const summFile = path.join(summDir, result.date + ".md");
const runTime = pad(now.getHours()) + ":" + pad(now.getMinutes());

// safe(): project names, branches and file names come from local dirs / the
// registry, i.e. attacker-influenceable, and this markdown is reinjected into
// the next session. Strip CR/LF + control chars (no smuggled instruction lines),
// collapse whitespace, cap length. Defense at the source.
function safe(s) {
  return String(s == null ? "" : s)
    .replace(/[\x00-\x1F\x7F]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
}

const runLine = "- " + runTime + " — " + result.project_count + " proyectos, " +
  result.total_observations + " observaciones";

function composeBody(r) {
  let out = "## Projects Worked Today: " + r.project_count + "\n\n";
  if (r.project_count === 0) {
    out += "No activity detected in any project in the last 24h.\n\n";
    return out;
  }
  for (const p of r.projects) {
    const g = p.git || {};
    out += "### " + safe(p.name) + "\n";
    out += "Branch: " + safe(g.branch || "(no git)") + "\n";
    out += "Observations: " + p.observations_today + " | Errors: " + p.errors_today + "\n\n";
    out += "**What was done**\n";
    out += "- Commits (24h): " + (g.commits_today != null ? g.commits_today : 0) + "\n";
    if (g.commits_log && g.commits_today) {
      for (const c of g.commits_log.split("\n").slice(0, 10)) out += "  - " + safe(c) + "\n";
    }
    if (p.files_touched && p.files_touched.length) out += "- Files: " + p.files_touched.map(safe).join(", ") + "\n";
    out += "\n**Pending**\n- Uncommitted: " + (g.uncommitted_files != null ? g.uncommitted_files : 0) + "\n\n---\n\n";
  }
  return out;
}

// Deterministic "For tomorrow" + "Quick Resume" so hooks/session-start.py can
// reinject context next session (it parses exactly these two section headers).
function composeTomorrow(r) {
  const bullets = [];
  for (const p of r.projects) {
    const g = p.git || {};
    if (g.uncommitted_files) bullets.push("- " + safe(p.name) + ": " + g.uncommitted_files + " uncommitted file(s) to review/commit");
  }
  if (!bullets.length) bullets.push("- No pending changes detected across active projects");
  return bullets.slice(0, 5).join("\n");
}
function composeResume(r) {
  if (!r.project_count) return "> No activity in the last 24h.";
  const top = r.projects[0];
  const g = top.git || {};
  const names = r.projects.slice(0, 4).map(p => safe(p.name)).join(", ");
  let s = "> Worked across " + r.project_count + " project(s) in the last 24h (" + names + ").";
  s += " Most active: " + safe(top.name) + (g.branch ? " (branch " + safe(g.branch) + ")" : "") +
    " — " + (g.commits_today || 0) + " commit(s), " + (g.uncommitted_files || 0) + " uncommitted.";
  return s;
}

// Serialize the read-merge-write with an O_EXCL lockfile so two overlapping runs
// (cron + manual) cannot clobber each other'"'"'s "## Ejecuciones hoy" trace. Steal
// a stale lock left by a crashed run. Contention is rare (cron is hourly).
fs.mkdirSync(summDir, { recursive: true });
const lockFile = summFile + ".lock";
function sleepMs(ms) { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch (e) {} }
let lockFd = null;
for (let i = 0; i < 40 && lockFd === null; i++) {
  try { lockFd = fs.openSync(lockFile, "wx"); }
  catch (e) {
    if (e.code !== "EEXIST") throw e;
    try { if (Date.now() - fs.statSync(lockFile).mtimeMs > 30000) { fs.unlinkSync(lockFile); continue; } } catch (e2) {}
    sleepMs(50);
  }
}

const tmp = summFile + ".tmp." + process.pid;
try {
  // Read the prior "## Ejecuciones hoy" trace INSIDE the lock so the merge is
  // consistent. Regenerating the body from the 24h window means no duplicated
  // content — only the run trace grows. Dedup exact-identical lines (Set keeps
  // insertion order) so two same-minute runs do not double a line.
  let priorRuns = [];
  try {
    const old = fs.readFileSync(summFile, "utf8");
    const m = old.match(/^## Ejecuciones hoy\s*\n([\s\S]*?)(?=^## |$(?![\s\S]))/m);
    if (m) priorRuns = m[1].split("\n").filter(l => /^- /.test(l));
  } catch (e) {}
  const runs = [...new Set([...priorRuns, runLine])];

  let md = "# EOD — " + result.date + "\n\n";
  md += "## Ejecuciones hoy\n" + runs.join("\n") + "\n\n";
  md += composeBody(result);
  md += "## Cross-Project Summary\n\n### For tomorrow\n" + composeTomorrow(result) + "\n\n";
  md += "### Cortex Learning\n- Observations (24h): " + result.total_observations + "\n\n";
  md += "## Quick Resume\n" + composeResume(result) + "\n";

  fs.writeFileSync(tmp, md, { mode: 0o600 });
  fs.renameSync(tmp, summFile);
  console.log("cx-eod: wrote " + summFile + " (run #" + runs.length + " today at " + runTime +
    ", " + result.project_count + " projects, " + result.total_observations + " observations)");
} finally {
  try { fs.unlinkSync(tmp); } catch (e) {}   // remove orphan tmp if rename failed
  if (lockFd !== null) {
    try { fs.closeSync(lockFd); } catch (e) {}
    try { fs.unlinkSync(lockFile); } catch (e) {}
  }
}
process.exit(0);
' 2>/dev/null)
NODE_RC=$?

# Write mode: surface real failures so cron logs them. Do NOT fake success.
if [ "$MODE" = "write" ]; then
  if [ "$NODE_RC" -ne 0 ] || [ -z "$GATHER_OUT" ]; then
    echo "cx-eod: gather/write failed (node rc=$NODE_RC). Is node installed and CORTEX_DIR writable?" >&2
    exit 1
  fi
  printf '%s\n' "$GATHER_OUT"
  exit 0
fi

# JSON mode: if Node is missing or errored (non-zero rc or empty output), emit a
# valid zero-projects JSON so the caller's fallback path triggers cleanly instead
# of choking on empty/invalid output. Never mask a real crash as silent success.
if [ "$NODE_RC" -ne 0 ] || [ -z "$GATHER_OUT" ]; then
  echo '{"date":"'"$(date +%Y-%m-%d)"'","project_count":0,"total_observations":0,"projects":[]}'
  exit 0
fi

printf '%s\n' "$GATHER_OUT"
exit 0
