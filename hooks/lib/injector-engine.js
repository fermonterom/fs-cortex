#!/usr/bin/env node
// CORTEX-MANAGED — do not edit manually, updated by install.sh
// Cortex Injector Engine — PreToolUse matching logic
// Extracted from injector.sh for testability and maintainability.
// Reads hook payload from stdin, outputs matched reflexes + instincts as JSON.

'use strict';

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const crypto = require("crypto");

// Optional impact funnel writer — never blocks injection if require fails.
let impactLog = null;
try {
  impactLog = require("./impact_log.js");
} catch {}

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

// Regex safety helpers — centralized in lib/regex-guard.js (v3.23.4+).
const { isSafeRegex, safeRegexTest, unsafeReason } = require('./regex-guard');

// Import shared YAML utilities
const yamlUtils = require(path.join(__dirname, 'yaml-utils'));

/** Parse instinct YAML using shared yaml-utils module */
function parseInstinctYaml(content) {
  const r = yamlUtils.parseYamlFrontmatter(content);
  if (!r || !r.fields.id || !r.fields.trigger || !r.fields.action) return null;
  // v3.36.1 (audit TRUNC001): hollow/truncated actions — produced by the
  // learner's old raw-input slice when the fix observation had no input —
  // parse fine but inject garbage ("When Bash fails with similar pattern,
  // try: "). Treat them as unparseable so the instinct is skipped.
  const actionStr = String(r.fields.action).trim();
  if (actionStr.length < 30 || /try:\s*$/.test(actionStr)) return null;
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

function main() {
  const CORTEX_DIR = process.env._CX_CORTEX_DIR || process.env.CORTEX_DIR;
  if (!CORTEX_DIR) {
    if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] CORTEX_DIR not set\n");
    process.exit(0);
  }

  const hookData = JSON.parse(fs.readFileSync(process.env._CX_INPUT_FILE || '/dev/stdin', "utf8"));
  const toolName = hookData.tool_name || "";
  const toolInput = hookData.tool_input || {};
  const toolInputStr = typeof toolInput === "object" ? JSON.stringify(toolInput) : String(toolInput);
  const matchTarget = toolName + " " + toolInputStr;

  const cwd = (typeof toolInput === "object" && toolInput.cwd)
    ? toolInput.cwd
    : (hookData.cwd || process.cwd());

  const matchedReflexes = [];
  const matchedInstincts = [];

  // ── 0. Load memory.json config ──────────────────────────────────────
  let memoryConfig = {};
  try {
    const mem = JSON.parse(fs.readFileSync(path.join(CORTEX_DIR, "memory.json"), "utf8"));
    memoryConfig = mem.config || {};
  } catch {}

  // v3.37.0 — per-session repeat cooldown. The same instinct/reflex used to
  // inject on every matching tool call (8x in one session was measured),
  // drowning the context and writing an impact event each time. Cap at 2
  // injections per id per session; suppressed repeats emit a 'suppress'
  // impact event so the funnel keeps its samples (AD finding: silently
  // skipping them would break inject→follow/reject correlation rates).
  // File reset at SessionStart alongside .session-token-budget.
  const INJECTED_COUNTS_FILE = path.join(CORTEX_DIR, ".session-injected.json");
  const MAX_REPEAT_INJECTIONS = memoryConfig.max_repeat_injections_per_session || 2;
  let injectedCounts = {};
  try { injectedCounts = JSON.parse(fs.readFileSync(INJECTED_COUNTS_FILE, "utf8")) || {}; } catch {}
  const suppressed = []; // {id} — repeats + budget drops, logged as suppress events

  // ── 1. Load and match reflexes ───────────────────────────────────────

  const reflexesFile = process.env._CX_REFLEXES_FILE;
  if (reflexesFile && fs.existsSync(reflexesFile)) {
    try {
      const reflexData = JSON.parse(fs.readFileSync(reflexesFile, "utf8"));
      const reflexes = reflexData.reflexes || [];
      const MAX_REFLEXES = memoryConfig.max_reflexes_per_injection || 2;
      for (const r of reflexes) {
        if (!r.enabled) continue;
        if (!r.matcher || !safeRegexTest(r.matcher, toolName, { tag: `reflex:${r.id}:matcher` })) continue;
        if (r.condition && !safeRegexTest(r.condition, toolInputStr, { tag: `reflex:${r.id}:condition` })) continue;
        if ((injectedCounts["reflex:" + r.id] || 0) >= MAX_REPEAT_INJECTIONS) {
          suppressed.push({ id: "reflex:" + r.id });
          continue;
        }
        matchedReflexes.push({ id: r.id, action: r.action, severity: r.severity || "medium" });
        if (matchedReflexes.length >= MAX_REFLEXES) break;
      }
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] reflexes: " + e.message + "\n");
    }
  }

  // ── 2. Collect instinct files (global + project-scoped) ──────────────

  const instinctFiles = [];

  const globalDir = process.env._CX_GLOBAL_INSTINCTS_DIR;
  if (globalDir) {
    instinctFiles.push(...listYamlFiles(globalDir));
  }

  const { id: projectId, root: projectRoot } = detectProject(cwd);
  if (projectId) {
    const projectDir = path.join(CORTEX_DIR, "projects", projectId, "instincts");
    instinctFiles.push(...listYamlFiles(projectDir));
  }

  // ── 2b. Domain pre-filter: detect project stack (v3.15.0 — monorepo-aware) ──
  //
  // v3.13.x only read manifests at depth-0 → Turborepo / pnpm-workspace lost
  // ALL instincts because detectProjectDomains returned {"general"}. Fix:
  //   1. Read workspace configs (pnpm-workspace.yaml, turbo.json, nx.json,
  //      lerna.json, rush.json) at project root.
  //   2. Recurse into apps/**, packages/**, libs/**, services/** up to depth 3.
  //   3. Inspect each package.json / pyproject.toml / Cargo.toml / go.mod.
  //   4. Cached 5 min in ~/.claude/cortex/.project-domains-cache (JSON).
  //
  // Always short-circuits at depth 3 to avoid scanning node_modules / .venv.

  const DOMAIN_CACHE_FILE = path.join(CORTEX_DIR, ".project-domains-cache");
  const DOMAIN_CACHE_TTL_MS = 5 * 60 * 1000;
  const WORKSPACE_MARKERS = ["pnpm-workspace.yaml", "turbo.json", "nx.json", "lerna.json", "rush.json", "workspace.json"];
  const SKIP_DIRS = new Set(["node_modules", ".git", ".venv", "venv", "target", "dist", "build", ".next", ".nuxt", ".turbo", ".cache", "__pycache__"]);

  function _inspectPackageJson(file, domains) {
    try {
      const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
      const deps = Object.assign({}, pkg.dependencies, pkg.devDependencies, pkg.peerDependencies);
      if (deps.react || deps.next || deps.preact || deps.remix || deps.gatsby) domains.add("react");
      if (deps.express || deps.fastify || deps.koa || deps.hapi || deps.hono || deps.elysia || deps.nestjs) domains.add("node");
      if (deps["@supabase/supabase-js"] || deps["@supabase/ssr"]) domains.add("supabase");
      if (deps.stripe || deps["@stripe/stripe-js"]) domains.add("stripe");
      if (deps.playwright || deps["@playwright/test"]) domains.add("e2e");
      if (deps.typescript) domains.add("typescript");
      if (deps.tailwindcss) domains.add("tailwind");
    } catch {
      // malformed package.json — ignore
    }
  }

  function _inspectPyProject(file, domains) {
    try {
      const content = fs.readFileSync(file, "utf8");
      domains.add("python");
      if (/fastapi/i.test(content)) domains.add("fastapi");
      if (/django/i.test(content)) domains.add("django");
      if (/flask/i.test(content)) domains.add("flask");
    } catch {}
  }

  function _scanDir(dir, depth, domains) {
    if (depth > 3) return;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }

    // Top-level workspace markers → flag and keep scanning
    if (depth === 0) {
      for (const marker of WORKSPACE_MARKERS) {
        if (entries.some(e => e.isFile() && e.name === marker)) {
          domains.add("monorepo");
          break;
        }
      }
    }

    for (const entry of entries) {
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name) || entry.name.startsWith(".")) continue;
        // Only recurse into typical monorepo layout folders at depth 0
        if (depth === 0 && !["apps", "packages", "libs", "services", "api", "web", "client", "server"].includes(entry.name)) {
          continue;
        }
        _scanDir(path.join(dir, entry.name), depth + 1, domains);
        continue;
      }
      if (!entry.isFile()) continue;
      const full = path.join(dir, entry.name);
      if (entry.name === "package.json") _inspectPackageJson(full, domains);
      else if (entry.name === "requirements.txt" || entry.name === "pyproject.toml") _inspectPyProject(full, domains);
      else if (entry.name === "Cargo.toml") domains.add("rust");
      else if (entry.name === "go.mod") domains.add("go");
    }
  }

  function detectProjectDomains(dir) {
    const domains = new Set(["general"]);
    if (!dir) return domains;

    // Cache check
    try {
      const cache = JSON.parse(fs.readFileSync(DOMAIN_CACHE_FILE, "utf8"));
      if (cache && cache[dir] && (Date.now() - cache[dir].ts) < DOMAIN_CACHE_TTL_MS) {
        return new Set(cache[dir].domains);
      }
    } catch {}

    _scanDir(dir, 0, domains);

    // Cache write (best-effort)
    try {
      let cache = {};
      try { cache = JSON.parse(fs.readFileSync(DOMAIN_CACHE_FILE, "utf8")) || {}; } catch {}
      cache[dir] = { ts: Date.now(), domains: Array.from(domains) };
      // Prune cache if larger than 20 entries — keep newest 20.
      const keys = Object.keys(cache);
      if (keys.length > 20) {
        const sorted = keys.sort((a, b) => cache[b].ts - cache[a].ts).slice(0, 20);
        const pruned = {};
        for (const k of sorted) pruned[k] = cache[k];
        cache = pruned;
      }
      const tmp = DOMAIN_CACHE_FILE + ".tmp." + process.pid;
      fs.writeFileSync(tmp, JSON.stringify(cache), { mode: 0o600 });
      fs.renameSync(tmp, DOMAIN_CACHE_FILE);
    } catch {}

    return domains;
  }

  const projectDomains = detectProjectDomains(projectRoot);

  // ── 3. Parse, filter, match instincts ────────────────────────────────

  // Load tracking data early for inline staleness check (read-only, no writes here)
  const TRACKING_FILE = path.join(CORTEX_DIR, "instinct-tracking.json");
  let tracking = {};
  try { tracking = JSON.parse(fs.readFileSync(TRACKING_FILE, "utf8")); } catch {}

  const STALE_DAYS = 60; // Skip instincts not seen in 60+ days (read-only decay)
  const NOW_MS = Date.now();

  const candidates = [];
  const draftMatches = [];
  // v3.24.0: domain filter taxonomy fix.
  //
  // Pre-v3.24.0 the filter `inst.domain !== "general" && !projectDomains.has(...)`
  // dropped 121/122 instincts in fs-cortex. Root cause: cx-analyze writes the
  // YAML `domain` field with category labels (gotcha, pattern, tool-pref, ...)
  // while detectProjectDomains returns tech-stack labels (react, node, python,
  // ...). The two vocabularies never overlap, so the filter rejected every
  // instinct unless `domain: general`.
  //
  // Fix: split the comparison into two lanes.
  //   • Category domains (gotcha, pattern, workflow, tooling, tool-pref,
  //     testing, reliability, release, security, etc.) ALWAYS pass — they
  //     describe the kind of knowledge, not where it applies.
  //   • Tech-stack domains (react, node, python, supabase, ...) ONLY pass
  //     when the project actually uses that stack — but only filter when we
  //     actually detected a stack beyond the default "general" sentinel.
  // v3.36.1 (audit domain-taxonomy-mismatch): the live install carries
  // category domains added AFTER the v3.24.0 fix that were never appended
  // here — error-recovery (emitted by the learner's error-fix detector
  // itself), agent-evolution, correction, coupling, agent-quality (all
  // emitted by hooks/), plus meta / tool-preference / release-engineering /
  // claude-code-tooling / claude-behavior found in live YAMLs. They are
  // knowledge-type labels, not tech stacks — in any project with a detected
  // stack they were silently filtered out (23 error-recovery instincts
  // alone).
  const CATEGORY_DOMAINS = new Set([
    "general", "gotcha", "pattern", "workflow", "workflow-general",
    "tooling", "tool-pref", "tool-preference", "testing", "reliability",
    "release", "release-engineering", "security", "saas-development",
    "development", "claude-code-skills", "claude-code-tooling",
    "claude-behavior", "documentation", "performance", "observability",
    "cli-tool", "error-recovery", "agent-evolution", "agent-quality",
    "correction", "coupling", "meta", "reflex",
  ]);

  for (const file of instinctFiles) {
    try {
      const content = fs.readFileSync(file, "utf8");
      const inst = parseInstinctYaml(content);
      if (!inst) continue;
      // Category domains always pass. Tech-stack domains only filter when
      // the project actually has detected stacks beyond "general".
      if (inst.domain && !CATEGORY_DOMAINS.has(inst.domain)) {
        const detectedStack = projectDomains.size > 1 || (projectDomains.size === 1 && !projectDomains.has("general"));
        if (detectedStack && !projectDomains.has(inst.domain)) continue;
      }
      if (inst.scope === "project" && inst.project_id && projectId && inst.project_id !== projectId) continue;
      // Inline staleness: skip instincts not seen in 60+ days (read-only decay)
      const lastSeen = tracking[inst.id]?.last_seen;
      if (lastSeen) {
        const daysSince = (NOW_MS - new Date(lastSeen).getTime()) / 86400000;
        if (daysSince > STALE_DAYS) {
          // v3.24.0: log silent staleness skips so dormant high-conf instincts
          // are visible in the learner log instead of disappearing without trace.
          if (process.env.CORTEX_DEBUG) {
            try { process.stderr.write(`[cortex:injector] skip stale instinct ${inst.id} (${daysSince.toFixed(0)}d > ${STALE_DAYS}d)\n`); } catch {}
          }
          continue;
        }
      }
      if (!safeRegexTest(inst.trigger, matchTarget, { tag: `instinct:${inst.id}:trigger` })) continue;
      if (inst.confidence < 0.30) {
        draftMatches.push({ ...inst, _file: file });
      } else {
        candidates.push({ ...inst, _file: file });
      }
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] instinct " + file + ": " + e.message + "\n");
    }
  }

  // v3.37.0 — id tiebreaker keeps equal-confidence ordering byte-stable
  // across calls (prompt-cache friendliness, ported from Sinapsis v4.5).
  candidates.sort((a, b) => b.confidence - a.confidence
    || String(a.id).localeCompare(String(b.id)));

  const MAX_INSTINCTS = memoryConfig.max_instincts_per_injection || 3;
  const MAX_TOTAL_CHARS = 1500;
  let totalChars = 0;
  const seenDomains = new Set();
  for (const inst of candidates) {
    if (matchedInstincts.length >= MAX_INSTINCTS) break;
    if ((injectedCounts[inst.id] || 0) >= MAX_REPEAT_INJECTIONS) {
      suppressed.push({ id: inst.id });
      continue;
    }
    if (seenDomains.has(inst.domain)) {
      // v3.36.1: make per-domain dedup visible — a high-confidence instinct
      // dropped here used to disappear without trace.
      if (process.env.CORTEX_DEBUG) {
        try { process.stderr.write(`[cortex:injector] skip ${inst.id} — duplicate domain ${inst.domain}\n`); } catch {}
      }
      continue;
    }
    const safeAction = sanitizeInjection(inst.action, 500);
    if (totalChars + safeAction.length > MAX_TOTAL_CHARS) continue;
    seenDomains.add(inst.domain);
    matchedInstincts.push({ ...inst, action: safeAction });
    totalChars += safeAction.length;
  }

  // ── 3b. Occurrence tracking (ALL matches including drafts) ──────────
  // tracking + TRACKING_FILE already loaded in section 3 (inline staleness)

  const allMatched = [...matchedInstincts, ...draftMatches];
  if (allMatched.length > 0) {
    try {

      for (const inst of allMatched) {
        const key = inst.id;
        if (!tracking[key]) tracking[key] = { count: 0, sessions: [], projects_seen: [], first_seen: new Date().toISOString() };
        tracking[key].count++;
        if (!tracking[key].sessions.includes(hookData.session_id || "")) {
          tracking[key].sessions.push(hookData.session_id || "");
          if (tracking[key].sessions.length > 20) tracking[key].sessions = tracking[key].sessions.slice(-20);
        }
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
              // Log auto-promote to knowledge timeline
              try {
                const logPath = path.join(CORTEX_DIR, "knowledge-log.md");
                const logLine = `${new Date().toISOString().slice(0,10)} | auto-promote | ${inst.id} | ${confMatch[1]}→0.35 | injector-engine\n`;
                fs.appendFileSync(logPath, logLine);
              } catch {}
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

  // ── 3c. Write last injected instinct IDs for /cx-downvote ────────────

  if (matchedInstincts.length > 0) {
    try {
      const ids = matchedInstincts.map(i => i.id);
      const lastInstFile = path.join(CORTEX_DIR, ".last-instinct");
      fs.writeFileSync(lastInstFile, JSON.stringify({ ids, ts: new Date().toISOString() }));
    } catch {}
  }

  // ── 4. Token budget cap ──────────────────────────────────────────────

  const SESSION_BUDGET_FILE = path.join(CORTEX_DIR, ".session-token-budget");
  const MAX_SESSION_TOKENS = 8000;
  let sessionTokens = 0;
  try { sessionTokens = parseInt(fs.readFileSync(SESSION_BUDGET_FILE, "utf8").trim(), 10) || 0; } catch {}

  let instinctTokens = matchedInstincts.reduce((sum, i) => sum + Math.ceil(i.action.length / 4) + 20, 0);
  const reflexTokens = matchedReflexes.reduce((sum, r) => sum + Math.ceil(r.action.length / 4) + 15, 0);

  // v3.37.0 — degrade instead of flush. The old killswitch zeroed the whole
  // instinct batch silently once the session crossed 8000 tokens, which is
  // one of the reasons "Cortex stopped learning": late-session matches never
  // reached the context. matchedInstincts is confidence-desc, so pop()
  // drops the weakest first.
  while (matchedInstincts.length > 0 &&
         sessionTokens + reflexTokens + instinctTokens > MAX_SESSION_TOKENS) {
    const droppedInst = matchedInstincts.pop();
    suppressed.push({ id: droppedInst.id });
    instinctTokens -= Math.ceil(droppedInst.action.length / 4) + 20;
    if (process.env.CORTEX_DEBUG) {
      process.stderr.write("[cortex:injector] token budget (" + sessionTokens + "/" + MAX_SESSION_TOKENS + "): dropped " + droppedInst.id + "\n");
    }
  }

  const budgetNew = sessionTokens + reflexTokens + instinctTokens;
  try {
    const tmp3 = SESSION_BUDGET_FILE + ".tmp." + process.pid;
    fs.writeFileSync(tmp3, String(budgetNew), { mode: 0o600 });
    fs.renameSync(tmp3, SESSION_BUDGET_FILE);
  } catch {}

  // ── 4b. Impact funnel — emit inject/suppress events ─────────────────
  // v3.37.0: moved BELOW the budget cap. Inject events used to be logged
  // before the killswitch/char cap acted, inflating funnel metrics with
  // instincts that never reached the context (AD finding 2026-06-12).
  // session-learner.js correlates inject→follow/reject; suppress events are
  // ignored by the correlator but keep the funnel sample count honest.
  if (impactLog && matchedInstincts.length > 0) {
    try {
      impactLog.logInjectBatch(matchedInstincts, {
        tool: hookData.tool_name,
        pid: projectId,
        sid: hookData.session_id,
      });
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] impact: " + e.message + "\n");
    }
  }
  if (impactLog && matchedReflexes.length > 0) {
    try {
      impactLog.logInjectBatch(
        matchedReflexes.map(r => ({
          id: `reflex:${r.id}`,
          confidence: 0,
          domain: 'reflex'
        })),
        {
          tool: hookData.tool_name,
          pid: projectId,
          sid: hookData.session_id,
        }
      );
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] reflex impact: " + e.message + "\n");
    }
  }
  if (impactLog && suppressed.length > 0) {
    try {
      for (const s of suppressed) {
        impactLog.logEvent("suppress", {
          iid: s.id,
          tool: hookData.tool_name,
          pid: projectId,
          sid: hookData.session_id,
        });
      }
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] suppress impact: " + e.message + "\n");
    }
  }

  // ── 4c. Persist per-session repeat counts (v3.37.0 cooldown) ────────
  // AD-final fix (P1): concurrent PreToolUse injectors raced on a plain
  // read-modify-write — the last rename clobbered the other's increment, so
  // the cooldown could never fire under parallel tool calls. Now: re-read
  // the file under .session-injected.lock and merge only THIS call's
  // increments on top of the freshest counts. The match-time check stays
  // lock-free (worst case one extra injection in a concurrent pair; the
  // merged counter catches up immediately), but increments are never lost.
  if (matchedInstincts.length > 0 || matchedReflexes.length > 0) {
    const increments = {};
    for (const inst of matchedInstincts) {
      increments[inst.id] = (increments[inst.id] || 0) + 1;
    }
    for (const r of matchedReflexes) {
      increments["reflex:" + r.id] = (increments["reflex:" + r.id] || 0) + 1;
    }
    let fileLock = null;
    let lockToken = null;
    try {
      fileLock = require('./file-lock');
      try {
        lockToken = fileLock.acquire(INJECTED_COUNTS_FILE + ".lock", { timeoutMs: 500, staleMs: 5000 });
      } catch {
        lockToken = null; // lock contention — proceed best-effort
      }
      let fresh = {};
      try { fresh = JSON.parse(fs.readFileSync(INJECTED_COUNTS_FILE, "utf8")) || {}; } catch {}
      for (const id of Object.keys(increments)) {
        fresh[id] = (fresh[id] || 0) + increments[id];
      }
      const tmpI = INJECTED_COUNTS_FILE + ".tmp." + process.pid;
      fs.writeFileSync(tmpI, JSON.stringify(fresh), { mode: 0o600 });
      fs.renameSync(tmpI, INJECTED_COUNTS_FILE);
    } catch (e) {
      if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] cooldown persist: " + e.message + "\n");
    } finally {
      if (fileLock && lockToken) {
        try { fileLock.release(lockToken); } catch {}
      }
    }
  }

  // ── 5. Build output ──────────────────────────────────────────────────

  if (matchedReflexes.length === 0 && matchedInstincts.length === 0) {
    process.exit(0);
  }

  const lines = [];

  for (const r of matchedReflexes) {
    lines.push("[reflex:" + r.id + "] " + r.action);
  }

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
}

// Run
try {
  main();
} catch (e) {
  if (process.env.CORTEX_DEBUG) process.stderr.write("[cortex:injector] fatal: " + e.message + "\n");
  process.exit(0);
}
