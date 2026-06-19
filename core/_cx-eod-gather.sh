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

if [ "${CORTEX_EOD_DEBUG:-}" = "1" ]; then
  exec 2>>"$HOME/.claude/cortex/log/cx-eod-gather-debug.log"
fi

if [ ! -d "$CORTEX_DIR/projects" ] && [ ! -f "$CORTEX_DIR/observations.jsonl" ]; then
  echo '{"date":"'"$(date +%Y-%m-%d)"'","project_count":0,"total_observations":0,"projects":[]}'
  exit 0
fi

CORTEX_DIR="$CORTEX_DIR" node -e '
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
      .filter(l => l.tool === "Edit" || l.tool === "Write" || l.tool === "NotebookEdit")
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
console.log(JSON.stringify(result, null, 2));
' 2>/dev/null

exit 0
