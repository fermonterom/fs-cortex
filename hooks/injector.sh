#!/bin/bash
# Cortex Injector v2.0 — Unified PreToolUse hook
# Merges reflex-engine, instinct-activator, and git-guard into a single hook.
# Reads stdin ONCE, loads all config ONCE, outputs combined context.
#
# Pipeline: stdin JSON -> node inline script -> matched reflexes + instincts -> JSON output
# Limits: max 2 reflexes + max 2 instincts per injection, domain dedup on instincts
# Safety: exits 0 silently on any error (never blocks Claude)

set -e

CORTEX_DIR="$HOME/.claude/cortex"
REFLEXES_FILE="$CORTEX_DIR/reflexes.json"
GLOBAL_INSTINCTS_DIR="$CORTEX_DIR/instincts/global"

# Read hook input from stdin (once)
INPUT_JSON=$(cat)
[ -z "$INPUT_JSON" ] && exit 0

# Require node — exit silently if unavailable
command -v node >/dev/null 2>&1 || exit 0

# Write hook payload to temp file (avoids exposing full payload in env/proc)
_CX_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/cx-input-XXXXXX")
chmod 600 "$_CX_INPUT_FILE"
echo "$INPUT_JSON" > "$_CX_INPUT_FILE"
trap "rm -f '$_CX_INPUT_FILE'" EXIT

export _CX_INPUT_FILE
export _CX_CORTEX_DIR="$CORTEX_DIR"
export _CX_REFLEXES_FILE="$REFLEXES_FILE"
export _CX_GLOBAL_INSTINCTS_DIR="$GLOBAL_INSTINCTS_DIR"

# Run the unified matching engine in Node.js (zero npm dependencies)
node -e '
"use strict";

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const crypto = require("crypto");

// ── Helpers ──────────────────────────────────────────────────────────────

/** Sanitize text injected into context — strip instruction overrides, limit length */
function sanitizeInjection(text, maxLen) {
  if (typeof text !== "string") return "";
  const BLOCKED = /\b(ignore|forget|override|disregard|bypass|system\s*:|you\s+are|all\s+previous|new\s+instructions|do\s+not\s+follow)\b/gi;
  let clean = text
    .replace(/[\x00-\x1f\x7f]/g, "")   // strip control chars
    .replace(BLOCKED, "[BLOCKED]")       // neutralize instruction overrides
    .slice(0, maxLen);
  return clean;
}

/** Check if a regex pattern is safe (no ReDoS risk) */
function isSafeRegex(pattern) {
  if (typeof pattern !== "string" || pattern.length > 100) return false;
  // Ban nested quantifiers: (a+)+ , (a*)* , (a+)*
  if (/\([^)]*[+*]\)[+*?]/.test(pattern)) return false;
  // Ban excessive alternations
  if ((pattern.match(/\|/g) || []).length > 5) return false;
  // Test with timeout
  try {
    const re = new RegExp(pattern);
    const start = Date.now();
    re.test("a".repeat(100));
    if (Date.now() - start > 50) return false;
  } catch { return false; }
  return true;
}

/** Safe regex test — returns false on invalid or unsafe pattern */
function safeRegexTest(pattern, text) {
  try {
    if (!isSafeRegex(pattern)) return false;
    return new RegExp(pattern, "i").test(text);
  } catch {
    return false;
  }
}

/** Parse YAML frontmatter from instinct file (no npm deps).
 *  Extracts: id, trigger, action, confidence, domain, scope, project_id */
function parseInstinctYaml(content) {
  const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!match) return null;
  const block = match[1];
  const get = (key) => {
    const m = block.match(new RegExp("^" + key + ":\\s*\"?([^\"\\n]+)\"?", "m"));
    return m ? m[1].trim() : null;
  };
  const id = get("id");
  const trigger = get("trigger");
  const action = get("action");
  if (!id || !trigger || !action) return null;
  const conf = parseFloat(get("confidence") || "0");
  return {
    id,
    trigger,
    action,
    confidence: isNaN(conf) ? 0 : conf,
    domain: get("domain") || "general",
    scope: get("scope") || "global",
    project_id: get("project_id") || null,
  };
}

/** Collect .yaml files from a directory (non-recursive) */
function listYamlFiles(dir) {
  try {
    return fs.readdirSync(dir)
      .filter((f) => f.endsWith(".yaml") || f.endsWith(".yml"))
      .map((f) => path.join(dir, f));
  } catch {
    return [];
  }
}

/** Derive project_id from git remote URL: sha256(url)[0:12] */
function detectProjectId(cwd) {
  let url;
  try {
    url = execFileSync("git", ["-C", cwd, "remote", "get-url", "origin"], {
      encoding: "utf8",
      timeout: 2000,
      stdio: ["pipe", "pipe", "pipe"]
    }).trim();
  } catch { url = ""; }
  if (!url) return null;
  return crypto.createHash("sha256").update(url).digest("hex").slice(0, 12);
}

// ── Main ─────────────────────────────────────────────────────────────────

try {
  const hookData = JSON.parse(fs.readFileSync(process.env._CX_INPUT_FILE, "utf8"));
  const toolName = hookData.tool_name || "";
  const toolInput = hookData.tool_input || {};
  const toolInputStr = typeof toolInput === "object" ? JSON.stringify(toolInput) : String(toolInput);
  const matchTarget = toolName + " " + toolInputStr;

  // Resolve cwd for project detection
  const cwd = (typeof toolInput === "object" && toolInput.cwd)
    ? toolInput.cwd
    : (hookData.cwd || process.cwd());

  const matchedReflexes = []; // { id, action, severity }
  const matchedInstincts = []; // { id, action, confidence, domain }

  // ── 1. Load and match reflexes ───────────────────────────────────────

  const reflexesFile = process.env._CX_REFLEXES_FILE;
  if (reflexesFile && fs.existsSync(reflexesFile)) {
    try {
      const reflexData = JSON.parse(fs.readFileSync(reflexesFile, "utf8"));
      const reflexes = reflexData.reflexes || [];
      for (const r of reflexes) {
        if (!r.enabled) continue;
        if (!r.matcher || !safeRegexTest(r.matcher, toolName)) continue;
        if (r.condition && !safeRegexTest(r.condition, toolInputStr)) continue;
        matchedReflexes.push({ id: r.id, action: r.action, severity: r.severity || "medium" });
        if (matchedReflexes.length >= 2) break; // max 2 reflexes
      }
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] reflexes: " + e.message + "\n");
    }
  }

  // ── 2. Collect instinct files (global + project-scoped) ──────────────

  const instinctFiles = [];

  // Global instincts
  const globalDir = process.env._CX_GLOBAL_INSTINCTS_DIR;
  if (globalDir) {
    instinctFiles.push(...listYamlFiles(globalDir));
  }

  // Project-scoped instincts (detected via git remote hash)
  const projectId = detectProjectId(cwd);
  if (projectId) {
    const projectDir = path.join(process.env._CX_CORTEX_DIR, "projects", projectId, "instincts");
    instinctFiles.push(...listYamlFiles(projectDir));
  }

  // ── 2b. Domain pre-filter: detect project stack ─────────────────────

  function detectProjectDomains(dir) {
    const domains = new Set(["general"]);
    try {
      const files = fs.readdirSync(dir);
      if (files.includes("package.json")) {
        try {
          const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
          const deps = Object.assign({}, pkg.dependencies, pkg.devDependencies);
          if (deps.react || deps.next) domains.add("react");
          if (deps.express || deps.fastify) domains.add("node");
          if (deps["@supabase/supabase-js"]) domains.add("supabase");
        } catch {}
      }
      if (files.includes("requirements.txt") || files.includes("pyproject.toml")) domains.add("python");
      if (files.includes("Cargo.toml")) domains.add("rust");
      if (files.includes("go.mod")) domains.add("go");
    } catch {}
    return domains;
  }

  const projectDomains = detectProjectDomains(cwd);

  // ── 3. Parse, filter, match instincts ────────────────────────────────

  const candidates = [];
  for (const file of instinctFiles) {
    try {
      const content = fs.readFileSync(file, "utf8");
      const inst = parseInstinctYaml(content);
      if (!inst) continue;
      if (inst.confidence < 0.30) continue;
      // Domain pre-filter: skip instincts for unrelated domains
      if (inst.domain && inst.domain !== "general" && !projectDomains.has(inst.domain)) continue;
      // Project-scoped instincts must match this project
      if (inst.scope === "project" && inst.project_id && projectId && inst.project_id !== projectId) continue;
      if (!safeRegexTest(inst.trigger, matchTarget)) continue;
      candidates.push({ ...inst, _file: file });
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] instinct " + file + ": " + e.message + "\n");
    }
  }

  // Sort by confidence descending
  candidates.sort((a, b) => b.confidence - a.confidence);

  // Domain dedup: max 1 per domain, max 3 total, max 1500 chars total
  const MAX_INSTINCTS = 3;
  const MAX_TOTAL_CHARS = 1500;
  let totalChars = 0;
  const seenDomains = new Set();
  for (const inst of candidates) {
    if (matchedInstincts.length >= MAX_INSTINCTS) break;
    if (seenDomains.has(inst.domain)) continue;
    const safeAction = sanitizeInjection(inst.action, 500);
    if (totalChars + safeAction.length > MAX_TOTAL_CHARS) continue;
    seenDomains.add(inst.domain);
    matchedInstincts.push({ ...inst, action: safeAction });
    totalChars += safeAction.length;
  }

  // ── 3b. Occurrence tracking ─────────────────────────────────────────

  if (matchedInstincts.length > 0) {
    try {
      const TRACKING_FILE = path.join(process.env._CX_CORTEX_DIR, "instinct-tracking.json");
      let tracking = {};
      try { tracking = JSON.parse(fs.readFileSync(TRACKING_FILE, "utf8")); } catch {}

      for (const inst of matchedInstincts) {
        const key = inst.id;
        if (!tracking[key]) tracking[key] = { count: 0, sessions: [], first_seen: new Date().toISOString() };
        tracking[key].count++;
        if (!tracking[key].sessions.includes(hookData.session_id || "")) {
          tracking[key].sessions.push(hookData.session_id || "");
          // Keep only last 20 session IDs
          if (tracking[key].sessions.length > 20) tracking[key].sessions = tracking[key].sessions.slice(-20);
        }
        tracking[key].last_seen = new Date().toISOString();
      }

      const tmp = TRACKING_FILE + ".tmp." + process.pid;
      fs.writeFileSync(tmp, JSON.stringify(tracking, null, 2), { mode: 0o600 });
      fs.renameSync(tmp, TRACKING_FILE);
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] tracking: " + e.message + "\n");
    }
  }

  // ── 4. Build output ──────────────────────────────────────────────────

  if (matchedReflexes.length === 0 && matchedInstincts.length === 0) {
    process.exit(0); // No matches — silent exit
  }

  const lines = [];

  // Reflexes first (safety)
  for (const r of matchedReflexes) {
    lines.push("[reflex:" + r.id + "] " + r.action);
  }

  // Then instincts (already sanitized in matching phase)
  for (const inst of matchedInstincts) {
    lines.push("[instinct:" + inst.id + "] " + inst.action + " (conf:" + inst.confidence.toFixed(2) + ")");
  }

  const output = {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: lines.join("\n"),
    },
  };

  process.stdout.write(JSON.stringify(output) + "\n");

} catch (e) {
  if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] fatal: " + e.message + "\n");
  process.exit(0);
}
' 2>/dev/null

exit 0
