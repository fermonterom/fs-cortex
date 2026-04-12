#!/usr/bin/env node
// CORTEX-MANAGED — do not edit manually, updated by install.sh
// Cortex Session Learner — Stop hook (runs when session ends)
// Analyzes observations, detects patterns, updates instincts/reflexes, writes proposals + context.
// Pure Node.js, zero dependencies, no LLM calls.

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { parseYamlFrontmatter, updateYamlField, listYamlFiles: findYamlFiles } = require(
  path.join(__dirname, 'lib', 'yaml-utils')
);

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';
const CORTEX_DIR = path.join(HOME, '.claude', 'cortex');
const PROJECTS_DIR = path.join(CORTEX_DIR, 'projects');
const REGISTRY_PATH = path.join(PROJECTS_DIR, 'registry.json');
const REFLEXES_PATH = path.join(CORTEX_DIR, 'reflexes.json');
const PROPOSALS_PATH = path.join(CORTEX_DIR, 'proposals.json');
const GLOBAL_INSTINCTS_DIR = path.join(CORTEX_DIR, 'instincts', 'global');
const LOG_DIR = path.join(CORTEX_DIR, 'log');
const LOG_PATH = path.join(LOG_DIR, 'session-learner.log');
const TIMELINE_PATH = path.join(LOG_DIR, 'timeline.jsonl');

const TODAY = new Date().toISOString().slice(0, 10);
function now() { return new Date().toISOString(); }

// -- Timeout: hard cap at 15 seconds --
const TIMEOUT = setTimeout(() => {
  log('Timeout reached (15s), exiting gracefully');
  process.exit(0);
}, 15000);

// -------------------------------------------------------------------
// Utilities
// -------------------------------------------------------------------

const MAX_LOG_BYTES = 512 * 1024; // 512KB

function log(msg) {
  try {
    ensureDir(LOG_DIR);
    // Rotate if oversized
    try {
      if (fs.existsSync(LOG_PATH) && fs.statSync(LOG_PATH).size > MAX_LOG_BYTES) {
        fs.renameSync(LOG_PATH, LOG_PATH + '.1');
      }
    } catch (_) {}
    const line = `[${now()}] ${msg}\n`;
    fs.appendFileSync(LOG_PATH, line);
  } catch (_) {
    // Never crash on log failure
  }
}

function ensureDir(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  } catch (e) {
    if (process.env.CORTEX_DEBUG) process.stderr.write('[cortex:learner] ensureDir: ' + e.message + '\n');
  }
}

function readJsonFile(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (e) {
    if (process.env.CORTEX_DEBUG) process.stderr.write('[cortex:learner] readJson ' + filePath + ': ' + e.message + '\n');
    return null;
  }
}

function writeJsonFile(filePath, data) {
  try {
    ensureDir(path.dirname(filePath));
    const tmp = filePath + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, filePath);
    return true;
  } catch (e) {
    log(`Failed to write ${filePath}: ${e.message}`);
    return false;
  }
}

function readJsonlFile(filePath) {
  const lines = [];
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        lines.push(JSON.parse(trimmed));
      } catch (e) {
        if (process.env.CORTEX_DEBUG) process.stderr.write('[cortex:learner] bad jsonl line: ' + e.message + '\n');
      }
    }
  } catch (_) {}
  return lines;
}

function shortHash(str) {
  return crypto.createHash('md5').update(str).digest('hex').slice(0, 8);
}

function readStdin() {
  return new Promise((resolve) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    const timer = setTimeout(() => resolve({}), 2000);
    process.stdin.on('end', () => {
      clearTimeout(timer);
      try { resolve(JSON.parse(data)); } catch (_) { resolve({}); }
    });
  });
}

// YAML helpers imported from hooks/lib/yaml-utils.js (shared with injector.sh)

// -------------------------------------------------------------------
// Step 1: Resolve session ID and filter observations
// -------------------------------------------------------------------

function resolveProjectAndObservations(stdinData) {
  // Discover all project directories
  const allProjects = [];
  try {
    const entries = fs.readdirSync(PROJECTS_DIR);
    for (const entry of entries) {
      const obsPath = path.join(PROJECTS_DIR, entry, 'observations.jsonl');
      if (fs.existsSync(obsPath)) {
        allProjects.push({ id: entry, obsPath });
      }
    }
  } catch (e) {
    if (process.env.CORTEX_DEBUG) process.stderr.write('[cortex:learner] readdir projects: ' + e.message + '\n');
  }

  if (allProjects.length === 0) {
    log('No project observation files found');
    return [];
  }

  // Read all observations
  let allObs = [];
  for (const proj of allProjects) {
    const lines = readJsonlFile(proj.obsPath);
    for (const line of lines) {
      line._projectId = proj.id;
      line._obsPath = proj.obsPath;
      allObs.push(line);
    }
  }

  // Resolve session ID
  let sessionId = process.env.CORTEX_SESSION_ID || '';

  if (!sessionId && stdinData && stdinData.session_id) {
    sessionId = stdinData.session_id;
  }

  // Filter by session
  let sessionObs;
  if (sessionId) {
    sessionObs = allObs.filter((o) => o.sid === sessionId);
    if (sessionObs.length === 0) {
      log(`Session ${sessionId} not found, falling back to last 200 lines`);
      sessionObs = allObs.slice(-200);
    }
  } else {
    // Find the most recent session
    const sessions = {};
    for (const o of allObs) {
      if (!o.sid || o.sid === 'unknown') continue;
      if (!sessions[o.sid]) sessions[o.sid] = [];
      sessions[o.sid].push(o);
    }
    const sessionIds = Object.keys(sessions);
    if (sessionIds.length > 0) {
      // Pick the one with the most recent timestamp
      let latest = sessionIds[0];
      for (const sid of sessionIds) {
        const lastTs = sessions[sid][sessions[sid].length - 1].ts || '';
        const bestTs = sessions[latest][sessions[latest].length - 1].ts || '';
        if (lastTs > bestTs) latest = sid;
      }
      sessionId = latest;
      sessionObs = sessions[latest];
    } else {
      sessionObs = allObs.slice(-200);
    }
  }

  // Tag with resolved session_id
  for (const o of sessionObs) {
    o._resolvedSession = sessionId;
  }

  return sessionObs;
}

// -------------------------------------------------------------------
// Sanitize text used in proposal actions against prompt injection
function sanitizeProposalAction(text) {
  const BLOCKED = /\b(ignore|forget|override|disregard|bypass|system\s*:|you\s+are|all\s+previous|new\s+instructions|do\s+not\s+follow)\b/gi;
  return String(text)
    .replace(/[\x00-\x1f\x7f]/g, '')
    .replace(BLOCKED, '[BLOCKED]')
    .slice(0, 300);
}

// -------------------------------------------------------------------
// Step 2: Detect error-resolution pairs
// -------------------------------------------------------------------

function detectErrorResolutions(observations) {
  const proposals = [];
  const WINDOW = 10;

  for (let i = 0; i < observations.length; i++) {
    const obs = observations[i];
    // Use is_error flag from observe.py OR fallback to output pattern matching
    if (!isError(obs)) continue;

    const errorTool = obs.tool;
    const errorSummary = String(obs.err_msg || obs.output || obs.input || '').slice(0, 200);

    // Look ahead for the fix: Edit/Write after error, or same tool succeeding
    for (let j = i + 1; j < Math.min(i + WINDOW + 1, observations.length); j++) {
      const candidate = observations[j];
      const isFix = (candidate.tool === 'Edit' || candidate.tool === 'Write' || candidate.tool === errorTool)
        && !isError(candidate);

      if (isFix) {
        const fixSummary = String(candidate.input || '').slice(0, 200);
        const hash = shortHash(`${errorTool}-${obs.ts || i}`);
        proposals.push({
          id: `gotcha-${errorTool}-${hash}`,
          trigger: errorTool,
          action: `When ${sanitizeProposalAction(errorTool)} fails with similar pattern, try: ${sanitizeProposalAction(fixSummary)}`,
          confidence: 0.40,
          domain: 'error-recovery',
          source: 'session-learner:error-fix',
          status: 'pending',
          detected: TODAY,
          session: obs._resolvedSession || obs.sid || 'unknown',
        });
        break;
      }
    }
  }

  return proposals;
}

function isError(obs) {
  // Check explicit err field (set by observe.py)
  if (obs.err === true) return true;
  // Check output — patterns aligned with observe.py ERROR_PATTERNS
  const output = String(obs.output || '');
  if (!output) return false;
  return /(?:^|\s)error[:\s]|(?:^|\s)failed(?!\s*:\s*0)|\bexception\b|\btraceback\b|\bfatal\b|(?:^|\s)panic[:(]|\bsegfault\b|\bOOM\b|\bcommand not found\b|\bENOENT\b|\bEACCES\b|\bEPERM\b/im.test(output);
}

// -------------------------------------------------------------------
// Step 3: Detect repetitions
// -------------------------------------------------------------------

function detectRepetitions(observations) {
  const proposals = [];
  const toolInputCounts = {};

  for (const obs of observations) {
    const tool = obs.tool;
    if (!tool) continue;
    const inputPrefix = String(obs.input || '').slice(0, 100);
    const key = `${tool}::${inputPrefix}`;
    if (!toolInputCounts[key]) {
      toolInputCounts[key] = { tool, count: 0, inputPrefix };
    }
    toolInputCounts[key].count++;
  }

  for (const [key, data] of Object.entries(toolInputCounts)) {
    if (data.count >= 5) {
      const hash = shortHash(key);
      proposals.push({
        id: `repeat-${data.tool}-${hash}`,
        trigger: data.tool,
        action: `Repetition detected: ${sanitizeProposalAction(data.tool)} called ${data.count}x with similar input`,
        confidence: 0.3,
        domain: 'workflow',
        source: 'session-learner',
        status: 'pending',
        detected: TODAY,
        session: observations[0]?._resolvedSession || 'unknown',
      });
    }
  }

  return proposals;
}

// -------------------------------------------------------------------
// Step 3b: Detect user corrections (same file edited 3+ times with overlapping regions)
// -------------------------------------------------------------------

function extractFilePath(input) {
  if (!input) return null;
  const s = String(input);
  const m = s.match(/"file_path"\s*:\s*"([^"]+)"/);
  return m ? m[1] : null;
}

function hasOverlappingEdits(edits) {
  // Check if any edits target overlapping old_string regions (true corrections)
  const oldStrings = edits.map(e => {
    const m = String(e.input || '').match(/"old_string"\s*:\s*"([^"]{0,200})"/);
    return m ? m[1] : null;
  }).filter(Boolean);
  for (let i = 0; i < oldStrings.length; i++) {
    for (let j = i + 1; j < oldStrings.length; j++) {
      if (oldStrings[i].includes(oldStrings[j]) || oldStrings[j].includes(oldStrings[i])) return true;
    }
  }
  return false;
}

function detectUserCorrections(observations) {
  const corrections = [];
  const fileEdits = {};

  for (const obs of observations) {
    if (obs.tool !== 'Edit' && obs.tool !== 'Write') continue;
    const file = extractFilePath(obs.input);
    if (!file) continue;

    if (!fileEdits[file]) fileEdits[file] = [];
    fileEdits[file].push(obs);
  }

  for (const [file, edits] of Object.entries(fileEdits)) {
    // Require 3+ edits AND overlapping regions to reduce false positives
    if (edits.length >= 3 && hasOverlappingEdits(edits)) {
      const hash = shortHash(file);
      corrections.push({
        id: `correction-${hash}`,
        trigger: `Edit.*${path.basename(file).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`,
        action: `User corrected edits to ${sanitizeProposalAction(path.basename(file))} (${edits.length} times). Review pattern.`,
        confidence: 0.40,
        domain: 'user-preference',
        source: 'session-learner:correction',
        status: 'pending',
        detected: TODAY,
        session: edits[0]._resolvedSession || edits[0].sid || 'unknown',
      });
    }
  }
  return corrections;
}

// -------------------------------------------------------------------
// Step 3c: Detect workflow chain trigrams (3-tool sequences)
// -------------------------------------------------------------------

function detectWorkflowChains(observations, minCount) {
  minCount = minCount || 5;
  const trigrams = {};

  for (let i = 0; i < observations.length - 2; i++) {
    const a = observations[i].tool;
    const b = observations[i + 1].tool;
    const c = observations[i + 2].tool;
    if (!a || !b || !c) continue;
    // Skip trivial same-tool chains (Bash->Bash->Bash is not a workflow)
    if (a === b && b === c) continue;
    const key = a + '->' + b + '->' + c;
    if (!trigrams[key]) trigrams[key] = 0;
    trigrams[key]++;
  }

  return Object.entries(trigrams)
    .filter(([_, count]) => count >= minCount)
    .map(([chain, count]) => {
      const hash = shortHash(chain);
      return {
        id: `workflow-${hash}`,
        trigger: chain.split('->')[0],
        action: `Common workflow detected: ${sanitizeProposalAction(chain)} (${count} times)`,
        confidence: Math.min(0.60, 0.30 + count * 0.05),
        domain: 'workflow',
        source: 'session-learner:workflow',
        status: 'pending',
        detected: TODAY,
        session: observations[0]._resolvedSession || observations[0].sid || 'unknown',
      };
    })
    .sort((a, b) => b.confidence - a.confidence);
}

// -------------------------------------------------------------------
// Step 3d: Detect recurring Agent tool patterns (same purpose across sessions)
// -------------------------------------------------------------------

function detectAgentPatterns(observations) {
  const agentObs = observations.filter(o => o.tool === 'Agent');
  if (agentObs.length < 2) return [];

  // Extract description from each Agent observation
  const descriptions = [];
  for (const obs of agentObs) {
    try {
      const input = typeof obs.input === 'string' ? JSON.parse(obs.input) : obs.input;
      if (input && input.description) {
        descriptions.push({ desc: String(input.description).toLowerCase().trim(), obs });
      }
    } catch (_) {}
  }

  // Group by similar descriptions (Jaccard on words)
  const groups = {};
  for (const d of descriptions) {
    const words = new Set(d.desc.split(/\s+/).filter(w => w.length > 2));
    let matched = false;
    for (const key of Object.keys(groups)) {
      const keyWords = new Set(key.split(/\s+/).filter(w => w.length > 2));
      const inter = [...words].filter(w => keyWords.has(w)).length;
      const union = new Set([...words, ...keyWords]).size;
      if (union > 0 && inter / union >= 0.40) {
        groups[key].push(d);
        matched = true;
        break;
      }
    }
    if (!matched) groups[d.desc] = [d];
  }

  // Propose agent evolution for groups with 3+ similar uses
  return Object.entries(groups)
    .filter(([_, items]) => items.length >= 3)
    .map(([desc, items]) => {
      const hash = shortHash('agent-' + desc);
      return {
        id: `agent-pattern-${hash}`,
        trigger: 'Agent',
        action: sanitizeProposalAction(`Recurring agent pattern: "${desc}" (${items.length} uses). Consider evolving into a dedicated agent with /cx-evolve.`),
        confidence: Math.min(0.70, 0.40 + items.length * 0.05),
        domain: 'agent-evolution',
        source: 'session-learner:agent-pattern',
        status: 'pending',
        detected: TODAY,
        session: items[0].obs._resolvedSession || items[0].obs.sid || 'unknown',
      };
    });
}

// -------------------------------------------------------------------
// Step 3e: Detect Cortex command usage and write timeline
// -------------------------------------------------------------------

function detectCommandUsage(observations) {
  // Find Skill tool uses that match cx-* patterns
  const cxPattern = /\bcx-\w+/;
  const commands = [];

  for (const obs of observations) {
    if (obs.tool !== 'Skill') continue;
    const input = typeof obs.input === 'string' ? obs.input : JSON.stringify(obs.input || '');
    const match = input.match(cxPattern);
    if (match) {
      commands.push({
        ts: obs.ts,
        cmd: match[0],
        pid: obs.pid || 'global',
      });
    }
  }

  if (commands.length === 0) return;

  // Append to timeline.jsonl
  try {
    fs.mkdirSync(LOG_DIR, { recursive: true });
    const lines = commands.map((c) => JSON.stringify(c)).join('\n') + '\n';
    fs.appendFileSync(TIMELINE_PATH, lines);
    log(`Wrote ${commands.length} command(s) to timeline`);
  } catch (e) {
    log(`Timeline write failed: ${e.message}`);
  }
}

// -------------------------------------------------------------------
// Step 4: Update existing instinct YAML files
// -------------------------------------------------------------------

function updateInstincts(observations) {
  const toolNames = new Set(observations.map((o) => o.tool).filter(Boolean));
  if (toolNames.size === 0) return;

  // Collect all instinct YAML paths (global + per-project)
  const yamlPaths = [];

  // Global instincts
  yamlPaths.push(...findYamlFiles(GLOBAL_INSTINCTS_DIR));

  // Project-scoped instincts
  try {
    const projectDirs = fs.readdirSync(PROJECTS_DIR);
    for (const dir of projectDirs) {
      const instDir = path.join(PROJECTS_DIR, dir, 'instincts');
      yamlPaths.push(...findYamlFiles(instDir));
    }
  } catch (e) {
    if (process.env.CORTEX_DEBUG) process.stderr.write('[cortex:learner] readdir instincts: ' + e.message + '\n');
  }

  let updated = 0;
  for (const yamlPath of yamlPaths) {
    try {
      const content = fs.readFileSync(yamlPath, 'utf8');
      const parsed = parseYamlFrontmatter(content);
      if (!parsed || !parsed.fields.trigger) continue;

      // ReDoS guard (matching injector.sh's isSafeRegex pattern)
      const trigger = parsed.fields.trigger;
      if (typeof trigger !== 'string' || trigger.length > 100) continue;
      if (/\([^)]*[+*]\)[+*?]/.test(trigger)) continue;
      let triggerRegex;
      try {
        triggerRegex = new RegExp(trigger);
        const start = Date.now();
        triggerRegex.test('a'.repeat(100));
        if (Date.now() - start > 50) continue;
      } catch { continue; }

      let matched = false;
      for (const toolName of toolNames) {
        if (triggerRegex.test(toolName)) {
          matched = true;
          break;
        }
      }

      if (matched) {
        let newContent = updateYamlField(content, 'last_seen', TODAY);
        const currentOccurrences = parseInt(parsed.fields.occurrences, 10) || 0;
        newContent = updateYamlField(newContent, 'occurrences', currentOccurrences + 1);
        const tmp = yamlPath + '.tmp.' + process.pid;
        fs.writeFileSync(tmp, newContent, { mode: 0o600 });
        fs.renameSync(tmp, yamlPath);
        updated++;
      }
    } catch (e) {
      log(`Failed to update instinct ${yamlPath}: ${e.message}`);
    }
  }

  if (updated > 0) {
    log(`Updated ${updated} instinct(s)`);
  }
}

// -------------------------------------------------------------------
// Step 5: Update reflex fire counts
// -------------------------------------------------------------------

function updateReflexes(observations) {
  const reflexData = readJsonFile(REFLEXES_PATH);
  if (!reflexData || !Array.isArray(reflexData.reflexes)) return;

  const toolNames = observations.map((o) => o.tool).filter(Boolean);
  const toolInputs = observations.map((o) => String(o.input || '')).filter(Boolean);
  let changed = false;

  for (const reflex of reflexData.reflexes) {
    if (!reflex.matcher) continue;
    try {
      // ReDoS guard
      if (reflex.matcher.length > 100 || /\([^)]*[+*]\)[+*?]/.test(reflex.matcher)) continue;
      const matcherRe = new RegExp(reflex.matcher);
      let matched = false;

      for (let i = 0; i < toolNames.length; i++) {
        if (!matcherRe.test(toolNames[i])) continue;

        // Check condition if present
        if (reflex.condition) {
          if (reflex.condition.length > 100 || /\([^)]*[+*]\)[+*?]/.test(reflex.condition)) continue;
          const condRe = new RegExp(reflex.condition, 'i');
          if (!condRe.test(toolInputs[i] || '')) continue;
        }

        matched = true;
        break;
      }

      if (matched) {
        reflex.fireCount = (reflex.fireCount || 0) + 1;
        reflex.lastFired = now();
        changed = true;
      }
    } catch (e) {
      log(`Invalid regex in reflex ${reflex.id}: ${e.message}`);
    }
  }

  if (changed) {
    writeJsonFile(REFLEXES_PATH, reflexData);
    log('Updated reflex fire counts');
  }
}

// -------------------------------------------------------------------
// Step 6: Write proposals.json
// -------------------------------------------------------------------

function writeProposals(newProposals) {
  if (newProposals.length === 0) return;

  let existing = readJsonFile(PROPOSALS_PATH);
  if (!Array.isArray(existing)) existing = [];

  // Append new proposals
  const all = [...existing, ...newProposals];

  // Deduplicate by id, preserving user validation decisions
  const byId = new Map();
  for (const p of all) {
    const existing = byId.get(p.id);
    if (existing && existing.status !== 'pending') {
      continue; // Preserve approved/rejected status
    }
    byId.set(p.id, p);
  }
  const deduped = Array.from(byId.values());

  writeJsonFile(PROPOSALS_PATH, deduped);
  log(`Wrote ${newProposals.length} new proposal(s), ${deduped.length} total`);
}

// -------------------------------------------------------------------
// Step 7b: Update memory.json stats (observation/instinct/law counts)
// -------------------------------------------------------------------

function updateMemoryStats() {
  try {
    const memPath = path.join(CORTEX_DIR, 'memory.json');
    const mem = readJsonFile(memPath);
    if (!mem || !mem.stats) return;

    // Count observations across all projects
    let obsCount = 0;
    const projDir = PROJECTS_DIR;
    try {
      for (const pid of fs.readdirSync(projDir)) {
        const obsFile = path.join(projDir, pid, 'observations.jsonl');
        if (fs.existsSync(obsFile)) {
          const content = fs.readFileSync(obsFile, 'utf8');
          obsCount += content.split('\n').filter(l => l.trim()).length;
        }
      }
    } catch (_) {}

    // Count instincts
    let globalInst = 0;
    let projInst = 0;
    try {
      const globalDir = path.join(CORTEX_DIR, 'instincts', 'global');
      if (fs.existsSync(globalDir)) {
        globalInst = fs.readdirSync(globalDir).filter(f => f.endsWith('.yaml')).length;
      }
      for (const pid of fs.readdirSync(projDir)) {
        const instDir = path.join(projDir, pid, 'instincts');
        if (fs.existsSync(instDir)) {
          projInst += fs.readdirSync(instDir).filter(f => f.endsWith('.yaml')).length;
        }
      }
    } catch (_) {}

    // Count laws
    let lawCount = 0;
    try {
      const lawsDir = path.join(CORTEX_DIR, 'laws');
      if (fs.existsSync(lawsDir)) {
        lawCount = fs.readdirSync(lawsDir).filter(f => f.endsWith('.txt')).length;
      }
    } catch (_) {}

    mem.stats.total_observations = obsCount;
    mem.stats.total_instincts = globalInst + projInst;
    mem.stats.total_laws = lawCount;
    mem.stats.last_updated = TODAY;

    const tmp = memPath + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(mem, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, memPath);
    log(`Stats updated: ${obsCount} obs, ${globalInst + projInst} instincts, ${lawCount} laws`);
  } catch (e) {
    log(`Stats update failed: ${e.message}`);
  }
}

// -------------------------------------------------------------------
// Step 7: Write context.md
// -------------------------------------------------------------------

function writeContextFile(observations) {
  if (observations.length === 0) return;

  // Determine project from observations
  const projectId = observations[0]._projectId || 'global';
  const projectDir = path.join(PROJECTS_DIR, projectId);

  // Look up project name from registry
  let projectName = projectId;
  const registry = readJsonFile(REGISTRY_PATH);
  if (registry && registry[projectId]) {
    projectName = registry[projectId].name || projectId;
  }

  // Tool usage counts
  const toolCounts = {};
  for (const obs of observations) {
    if (obs.tool) {
      toolCounts[obs.tool] = (toolCounts[obs.tool] || 0) + 1;
    }
  }
  const toolsSummary = Object.entries(toolCounts)
    .sort((a, b) => b[1] - a[1])
    .map(([tool, count]) => `${tool} (${count})`)
    .join(', ');

  // Files touched (from Edit/Write tool inputs)
  const filesTouched = new Set();
  for (const obs of observations) {
    if (obs.tool === 'Edit' || obs.tool === 'Write') {
      const input = String(obs.input || '');
      // Try to extract file_path from JSON input
      const fileMatch = input.match(/"file_path"\s*:\s*"([^"]+)"/);
      if (fileMatch) {
        filesTouched.add(fileMatch[1]);
      }
    }
  }
  const filesStr = filesTouched.size > 0
    ? Array.from(filesTouched).join(', ')
    : 'none';

  // Error count
  const errorCount = observations.filter((o) => isError(o)).length;

  const content = `## Project: ${projectName}
Last session: ${TODAY}
Tools used: ${toolsSummary || 'none'}
Files touched: ${filesStr}
Errors: ${errorCount} errors detected
Session observations: ${observations.length}
`;

  ensureDir(projectDir);
  const contextPath = path.join(projectDir, 'context.md');
  try {
    const tmp = contextPath + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, content, { mode: 0o600 });
    fs.renameSync(tmp, contextPath);
    log(`Wrote context.md for project ${projectName}`);
  } catch (e) {
    log(`Failed to write context.md: ${e.message}`);
  }
}

// -------------------------------------------------------------------
// Main
// -------------------------------------------------------------------

async function main() {
  try {
    log('Session learner started');

    // Read stdin (Claude Code passes session info)
    const stdinData = await readStdin();

    // Step 1: Filter observations by session
    const observations = resolveProjectAndObservations(stdinData);
    log(`Found ${observations.length} observations for session`);

    if (observations.length === 0) {
      log('No observations to process, exiting');
      return;
    }

    // Resolve project for all proposals
    const projectId = observations[0]._projectId || 'global';
    let projectName = projectId;
    const registry = readJsonFile(REGISTRY_PATH);
    if (registry && registry[projectId]) {
      projectName = registry[projectId].name || projectId;
    }

    // Step 2: Detect error-fix pairs
    const errorProposals = detectErrorResolutions(observations);
    log(`Detected ${errorProposals.length} error-fix pair(s)`);

    // Step 3: Detect repetitions
    const repetitionProposals = detectRepetitions(observations);
    log(`Detected ${repetitionProposals.length} repetition pattern(s)`);

    // Step 3b: Detect user corrections
    const correctionProposals = detectUserCorrections(observations);
    log(`Detected ${correctionProposals.length} user correction(s)`);

    // Step 3c: Detect workflow chains
    const workflowProposals = detectWorkflowChains(observations);
    log(`Detected ${workflowProposals.length} workflow chain(s)`);

    // Step 3d: Detect agent patterns
    const agentProposals = detectAgentPatterns(observations);
    log(`Detected ${agentProposals.length} agent pattern(s)`);

    // Step 4: Update instinct YAML files
    updateInstincts(observations);

    // Step 5: Update reflex fire counts
    updateReflexes(observations);

    // Step 5b: Detect and log Cortex command usage
    detectCommandUsage(observations);

    // Step 6: Combine all proposals with session_date for cross-day tracking
    const allProposals = [
      ...errorProposals,
      ...repetitionProposals,
      ...correctionProposals,
      ...workflowProposals,
      ...agentProposals,
    ].map((p) => ({
      ...p,
      session_date: TODAY,
      project_id: p.project_id || projectId,
      project_name: p.project_name || projectName,
    }));
    writeProposals(allProposals);

    // Step 7: Write context.md
    writeContextFile(observations);

    // Step 8: Update memory.json stats
    updateMemoryStats();

    log('Session learner completed successfully');
  } catch (e) {
    log(`Unexpected error: ${e.message}`);
  }
}

// Export functions for testing when loaded as module
if (require.main === module) {
  main().then(() => {
    clearTimeout(TIMEOUT);
    process.exit(0);
  }).catch((e) => {
    log(`Fatal: ${e.message}`);
    clearTimeout(TIMEOUT);
    process.exit(0);
  });
} else {
  module.exports = {
    isError, extractFilePath, sanitizeProposalAction,
    detectErrorResolutions, detectRepetitions,
    detectUserCorrections, detectWorkflowChains, detectAgentPatterns,
    detectCommandUsage,
  };
}
