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

# Export config paths and stdin data as env vars (read once, used by node)
export _CX_INPUT="$INPUT_JSON"
export _CX_CORTEX_DIR="$CORTEX_DIR"
export _CX_REFLEXES_FILE="$REFLEXES_FILE"
export _CX_GLOBAL_INSTINCTS_DIR="$GLOBAL_INSTINCTS_DIR"

# Run the unified matching engine in Node.js (zero npm dependencies)
node -e '
"use strict";

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const crypto = require("crypto");

// ── Helpers ──────────────────────────────────────────────────────────────

/** Safe regex test — returns false on invalid pattern */
function safeRegexTest(pattern, text) {
  try {
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
  try {
    const url = execSync("git -C " + JSON.stringify(cwd) + " remote get-url origin 2>/dev/null", {
      encoding: "utf8",
      timeout: 2000,
    }).trim();
    if (!url) return null;
    return crypto.createHash("sha256").update(url).digest("hex").slice(0, 12);
  } catch {
    return null;
  }
}

// ── Main ─────────────────────────────────────────────────────────────────

try {
  const hookData = JSON.parse(process.env._CX_INPUT);
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
    } catch {
      // Invalid reflexes.json — skip
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

  // ── 3. Parse, filter, match instincts ────────────────────────────────

  const candidates = [];
  for (const file of instinctFiles) {
    try {
      const content = fs.readFileSync(file, "utf8");
      const inst = parseInstinctYaml(content);
      if (!inst) continue;
      if (inst.confidence < 0.30) continue;
      // Project-scoped instincts must match this project
      if (inst.scope === "project" && inst.project_id && projectId && inst.project_id !== projectId) continue;
      if (!safeRegexTest(inst.trigger, matchTarget)) continue;
      candidates.push(inst);
    } catch {
      // Invalid file — skip
    }
  }

  // Sort by confidence descending
  candidates.sort((a, b) => b.confidence - a.confidence);

  // Domain dedup: max 1 per domain, max 2 total
  const seenDomains = new Set();
  for (const inst of candidates) {
    if (seenDomains.has(inst.domain)) continue;
    seenDomains.add(inst.domain);
    matchedInstincts.push(inst);
    if (matchedInstincts.length >= 2) break;
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

  // Then instincts sorted by confidence (already sorted)
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

} catch {
  // Graceful failure — never block Claude
  process.exit(0);
}
' 2>/dev/null

exit 0
