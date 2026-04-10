#!/bin/bash
# CORTEX-MANAGED — do not edit manually, updated by install.sh
# Cortex Injector v2.0 — Unified PreToolUse hook
# Merges reflex-engine, instinct-activator, and git-guard into a single hook.
# Reads stdin ONCE, loads all config ONCE, outputs combined context.
#
# Pipeline: stdin JSON -> node inline script -> matched reflexes + instincts -> JSON output
# Limits: max 2 reflexes + max 3 instincts per injection, domain dedup on instincts
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
trap 'rm -f "'"$_CX_INPUT_FILE"'"' EXIT

export _CX_INPUT_FILE
# Validate CORTEX_DIR is under real home directory
_REAL_HOME=$(eval echo ~"$(whoami)" 2>/dev/null || echo "$HOME")
if [[ "$CORTEX_DIR" != "$_REAL_HOME/.claude/cortex" ]]; then
  exit 0  # Refuse to run with non-standard CORTEX_DIR
fi
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

// Import shared YAML utilities (used by session-learner.js too)
const yamlUtils = require(path.join(__dirname, 'lib', 'yaml-utils'));

/** Parse instinct YAML using shared yaml-utils module */
function parseInstinctYaml(content) {
  const r = yamlUtils.parseYamlFrontmatter(content);
  if (!r || !r.fields.id || !r.fields.trigger || !r.fields.action) return null;
  const conf = typeof r.fields.confidence === 'number' ? r.fields.confidence : parseFloat(r.fields.confidence || '0');
  return {
    id: r.fields.id,
    trigger: String(r.fields.trigger),
    action: String(r.fields.action),
    confidence: isNaN(conf) ? 0 : conf,
    domain: r.fields.domain || 'general',
    scope: r.fields.scope || 'global',
    project_id: r.fields.project_id || null,
  };
}

/** Collect .yaml files from a directory (non-recursive) */
const listYamlFiles = yamlUtils.listYamlFiles;

/** Derive project_id + root from git remote URL: sha256(url)[0:12] */
function detectProject(cwd) {
  let url = "";
  let root = "";
  try {
    root = execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], {
      encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"]
    }).trim();
  } catch {}
  try {
    url = execFileSync("git", ["-C", cwd, "remote", "get-url", "origin"], {
      encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"]
    }).trim();
  } catch {}
  const hashInput = url || root;
  if (!hashInput) return { id: null, root: cwd };
  return { id: crypto.createHash("sha256").update(hashInput).digest("hex").slice(0, 12), root: root || cwd };
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
  const { id: projectId, root: projectRoot } = detectProject(cwd);
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

  const projectDomains = detectProjectDomains(projectRoot);

  // ── 3. Parse, filter, match instincts ────────────────────────────────

  const candidates = [];    // confidence >= 0.30 — will be injected
  const draftMatches = [];  // confidence < 0.30 — tracked but not injected
  for (const file of instinctFiles) {
    try {
      const content = fs.readFileSync(file, "utf8");
      const inst = parseInstinctYaml(content);
      if (!inst) continue;
      // Domain pre-filter: skip instincts for unrelated domains
      if (inst.domain && inst.domain !== "general" && !projectDomains.has(inst.domain)) continue;
      // Project-scoped instincts must match this project
      if (inst.scope === "project" && inst.project_id && projectId && inst.project_id !== projectId) continue;
      if (!safeRegexTest(inst.trigger, matchTarget)) continue;
      if (inst.confidence < 0.30) {
        draftMatches.push({ ...inst, _file: file });
      } else {
        candidates.push({ ...inst, _file: file });
      }
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

  // ── 3b. Occurrence tracking (ALL matches including drafts) ──────────

  const allMatched = [...matchedInstincts, ...draftMatches];
  if (allMatched.length > 0) {
    try {
      const TRACKING_FILE = path.join(process.env._CX_CORTEX_DIR, "instinct-tracking.json");
      let tracking = {};
      try { tracking = JSON.parse(fs.readFileSync(TRACKING_FILE, "utf8")); } catch {}

      for (const inst of allMatched) {
        const key = inst.id;
        if (!tracking[key]) tracking[key] = { count: 0, sessions: [], projects_seen: [], first_seen: new Date().toISOString() };
        tracking[key].count++;
        if (!tracking[key].sessions.includes(hookData.session_id || "")) {
          tracking[key].sessions.push(hookData.session_id || "");
          if (tracking[key].sessions.length > 20) tracking[key].sessions = tracking[key].sessions.slice(-20);
        }
        // Track which projects this instinct has been activated in
        if (!tracking[key].projects_seen) tracking[key].projects_seen = [];
        if (projectId && !tracking[key].projects_seen.includes(projectId)) {
          tracking[key].projects_seen.push(projectId);
        }
        tracking[key].last_seen = new Date().toISOString();

        // Auto-promote drafts: 5+ activations across 3+ sessions → confidence 0.35
        if (inst.confidence < 0.30 && inst._file &&
            tracking[key].count >= 5 && tracking[key].sessions.length >= 3) {
          try {
            let content = fs.readFileSync(inst._file, "utf8");
            const confMatch = content.match(/^confidence:\s*["']?([^"'\n]+)/m);
            if (confMatch && parseFloat(confMatch[1]) < 0.30) {
              content = content.replace(/^(confidence:\s*).*$/m, "$10.35");
              const tmp2 = inst._file + ".tmp." + process.pid;
              fs.writeFileSync(tmp2, content, { mode: 0o600 });
              fs.renameSync(tmp2, inst._file);
            }
          } catch {}
        }
      }

      const tmp = TRACKING_FILE + ".tmp." + process.pid;
      fs.writeFileSync(tmp, JSON.stringify(tracking, null, 2), { mode: 0o600 });
      fs.renameSync(tmp, TRACKING_FILE);
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] tracking: " + e.message + "\n");
    }
  }

  // ── 4. Token budget cap ──────────────────────────────────────────────

  const SESSION_BUDGET_FILE = path.join(process.env._CX_CORTEX_DIR, ".session-token-budget");
  const MAX_SESSION_TOKENS = 8000;  // configurable via memory.json in future
  let sessionTokens = 0;
  try { sessionTokens = parseInt(fs.readFileSync(SESSION_BUDGET_FILE, "utf8").trim(), 10) || 0; } catch {}

  // Estimate tokens for this injection (~4 chars per token)
  const instinctTokens = matchedInstincts.reduce((sum, i) => sum + Math.ceil(i.action.length / 4) + 20, 0);
  const reflexTokens = matchedReflexes.reduce((sum, r) => sum + Math.ceil(r.action.length / 4) + 15, 0);
  const totalNewTokens = instinctTokens + reflexTokens;

  // If budget exceeded, skip instincts (reflexes always pass — safety)
  if (sessionTokens + totalNewTokens > MAX_SESSION_TOKENS && matchedInstincts.length > 0) {
    matchedInstincts.length = 0;  // Clear instincts, keep reflexes
    if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] token budget exceeded (" + sessionTokens + "/" + MAX_SESSION_TOKENS + "), skipping instincts\n");
  }

  // Update budget counter
  const budgetNew = sessionTokens + reflexTokens + (matchedInstincts.length > 0 ? instinctTokens : 0);
  try {
    const tmp3 = SESSION_BUDGET_FILE + ".tmp." + process.pid;
    fs.writeFileSync(tmp3, String(budgetNew), { mode: 0o600 });
    fs.renameSync(tmp3, SESSION_BUDGET_FILE);
  } catch {}

  // ── 5. Build output ──────────────────────────────────────────────────

  if (matchedReflexes.length === 0 && matchedInstincts.length === 0) {
    process.exit(0); // No matches — silent exit
  }

  const lines = [];

  // Reflexes first (safety — always injected regardless of budget)
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
