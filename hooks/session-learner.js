#!/usr/bin/env node
// Cortex Session Learner — Stop hook (runs when session ends)
// Analyzes observations, detects patterns, updates instincts/reflexes, writes proposals + context.
// Pure Node.js, zero dependencies, no LLM calls.

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';
const CORTEX_DIR = path.join(HOME, '.claude', 'cortex');
const PROJECTS_DIR = path.join(CORTEX_DIR, 'projects');
const REGISTRY_PATH = path.join(PROJECTS_DIR, 'registry.json');
const REFLEXES_PATH = path.join(CORTEX_DIR, 'reflexes.json');
const PROPOSALS_PATH = path.join(CORTEX_DIR, 'proposals.json');
const GLOBAL_INSTINCTS_DIR = path.join(CORTEX_DIR, 'instincts', 'global');
const LOG_DIR = path.join(CORTEX_DIR, 'log');
const LOG_PATH = path.join(LOG_DIR, 'session-learner.log');

const TODAY = new Date().toISOString().slice(0, 10);
const NOW = new Date().toISOString();

// -- Timeout: hard cap at 15 seconds --
const TIMEOUT = setTimeout(() => {
  log('Timeout reached (15s), exiting gracefully');
  process.exit(0);
}, 15000);

// -------------------------------------------------------------------
// Utilities
// -------------------------------------------------------------------

function log(msg) {
  try {
    ensureDir(LOG_DIR);
    const line = `[${NOW}] ${msg}\n`;
    fs.appendFileSync(LOG_PATH, line);
  } catch (_) {
    // Never crash on log failure
  }
}

function ensureDir(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  } catch (_) {}
}

function readJsonFile(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (_) {
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
      } catch (_) {}
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
    process.stdin.on('end', () => {
      try { resolve(JSON.parse(data)); } catch (_) { resolve({}); }
    });
    // If stdin doesn't close within 2 seconds, continue without it
    setTimeout(() => resolve({}), 2000);
  });
}

// -------------------------------------------------------------------
// YAML helpers (simple frontmatter between --- markers)
// -------------------------------------------------------------------

function parseYamlFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return null;
  const fields = {};
  const body = content.slice(match[0].length);
  for (const line of match[1].split('\n')) {
    const m = line.match(/^(\w[\w_-]*)\s*:\s*(.*)/);
    if (m) {
      let val = m[2].trim();
      // Strip surrounding quotes
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      // Parse numbers
      if (/^\d+$/.test(val)) val = parseInt(val, 10);
      fields[m[1]] = val;
    }
  }
  return { fields, raw: match[1], body, fullMatch: match[0] };
}

function updateYamlField(content, fieldName, newValue) {
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return content;
  const frontmatter = match[1];
  const valueStr = typeof newValue === 'number' ? String(newValue) : `"${newValue}"`;
  const fieldRegex = new RegExp(`^(${fieldName}\\s*:\\s*)(.*)$`, 'm');
  let updated;
  if (fieldRegex.test(frontmatter)) {
    updated = frontmatter.replace(fieldRegex, `$1${valueStr}`);
  } else {
    updated = frontmatter + `\n${fieldName}: ${valueStr}`;
  }
  return content.replace(match[0], `---\n${updated}\n---`);
}

function findYamlFiles(dir) {
  const files = [];
  try {
    const entries = fs.readdirSync(dir);
    for (const entry of entries) {
      if (entry.endsWith('.yaml') || entry.endsWith('.yml')) {
        files.push(path.join(dir, entry));
      }
    }
  } catch (_) {}
  return files;
}

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
  } catch (_) {}

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
    sessionObs = allObs.filter((o) => o.session === sessionId);
    if (sessionObs.length === 0) {
      log(`Session ${sessionId} not found, falling back to last 200 lines`);
      sessionObs = allObs.slice(-200);
    }
  } else {
    // Find the most recent session
    const sessions = {};
    for (const o of allObs) {
      if (!o.session || o.session === 'unknown') continue;
      if (!sessions[o.session]) sessions[o.session] = [];
      sessions[o.session].push(o);
    }
    const sessionIds = Object.keys(sessions);
    if (sessionIds.length > 0) {
      // Pick the one with the most recent timestamp
      let latest = sessionIds[0];
      for (const sid of sessionIds) {
        const lastTs = sessions[sid][sessions[sid].length - 1].timestamp || '';
        const bestTs = sessions[latest][sessions[latest].length - 1].timestamp || '';
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
// Step 2: Detect error-resolution pairs
// -------------------------------------------------------------------

function detectErrorResolutions(observations) {
  const proposals = [];
  const WINDOW = 10;

  for (let i = 0; i < observations.length; i++) {
    const obs = observations[i];
    // Check if this is an error event (output contains error indicators)
    if (!isError(obs)) continue;

    const errorTool = obs.tool;
    // Look ahead in the window for the same tool succeeding
    for (let j = i + 1; j < Math.min(i + WINDOW + 1, observations.length); j++) {
      const candidate = observations[j];
      if (candidate.tool === errorTool && !isError(candidate)) {
        const hash = shortHash(`${errorTool}-${obs.timestamp || i}`);
        proposals.push({
          id: `fix-${errorTool}-${hash}`,
          trigger: errorTool,
          action: `Error pattern detected: ${errorTool} failed then succeeded`,
          confidence: 0.35,
          domain: 'tooling',
          source: 'session-learner',
          detected: TODAY,
          session: obs._resolvedSession || obs.session || 'unknown',
        });
        break; // Only one proposal per error
      }
    }
  }

  return proposals;
}

function isError(obs) {
  // Check explicit err field
  if (obs.err === true) return true;
  // Check output for common error patterns
  const output = String(obs.output || '');
  if (!output) return false;
  return /\b(error|Error|ERROR|ENOENT|EACCES|EPERM|failed|Failed|FAILED|exception|Exception|denied|not found|No such file)\b/.test(output);
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
        action: `Repetition detected: ${data.tool} called ${data.count}x with similar input`,
        confidence: 0.3,
        domain: 'workflow',
        source: 'session-learner',
        detected: TODAY,
        session: observations[0]?._resolvedSession || 'unknown',
      });
    }
  }

  return proposals;
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
  } catch (_) {}

  let updated = 0;
  for (const yamlPath of yamlPaths) {
    try {
      const content = fs.readFileSync(yamlPath, 'utf8');
      const parsed = parseYamlFrontmatter(content);
      if (!parsed || !parsed.fields.trigger) continue;

      const triggerRegex = new RegExp(parsed.fields.trigger);
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
        fs.writeFileSync(yamlPath, newContent, { mode: 0o600 });
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
      const matcherRe = new RegExp(reflex.matcher);
      let matched = false;

      for (let i = 0; i < toolNames.length; i++) {
        if (!matcherRe.test(toolNames[i])) continue;

        // Check condition if present
        if (reflex.condition) {
          const condRe = new RegExp(reflex.condition, 'i');
          if (!condRe.test(toolInputs[i] || '')) continue;
        }

        matched = true;
        break;
      }

      if (matched) {
        reflex.fireCount = (reflex.fireCount || 0) + 1;
        reflex.lastFired = NOW;
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

  // Deduplicate by id, keeping the most recent (last occurrence)
  const byId = new Map();
  for (const p of all) {
    byId.set(p.id, p);
  }
  const deduped = Array.from(byId.values());

  writeJsonFile(PROPOSALS_PATH, deduped);
  log(`Wrote ${newProposals.length} new proposal(s), ${deduped.length} total`);
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
    fs.writeFileSync(contextPath, content, { mode: 0o600 });
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

    // Step 2: Detect error-resolution pairs
    const errorProposals = detectErrorResolutions(observations);
    log(`Detected ${errorProposals.length} error-resolution pair(s)`);

    // Step 3: Detect repetitions
    const repetitionProposals = detectRepetitions(observations);
    log(`Detected ${repetitionProposals.length} repetition pattern(s)`);

    // Step 4: Update instinct YAML files
    updateInstincts(observations);

    // Step 5: Update reflex fire counts
    updateReflexes(observations);

    // Step 6: Write proposals
    const allProposals = [...errorProposals, ...repetitionProposals];
    writeProposals(allProposals);

    // Step 7: Write context.md
    writeContextFile(observations);

    log('Session learner completed successfully');
  } catch (e) {
    log(`Unexpected error: ${e.message}`);
  }
}

main().then(() => {
  clearTimeout(TIMEOUT);
  process.exit(0);
}).catch((e) => {
  log(`Fatal: ${e.message}`);
  clearTimeout(TIMEOUT);
  process.exit(0);
});
