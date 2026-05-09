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
const { isSafeRegex, unsafeReason } = require(path.join(__dirname, 'lib', 'regex-guard'));

// Optional impact funnel writer — never blocks learner if require fails.
let impactLog = null;
try {
  impactLog = require(path.join(__dirname, 'lib', 'impact_log.js'));
} catch {}

const { applyCrossDayBoost } = require(path.join(__dirname, 'lib', 'cross-day-tracker'));

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';
const CORTEX_DIR = process.env.CORTEX_DIR || path.join(HOME, '.claude', 'cortex');
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
    // v3.24.0: tolerate truncated sids via sidMatches (parity with the
    // correlation paths). Pre-v3.19.3 observations carried sid[:24] while
    // the harness Stop event sends the full 36-char UUID. Exact-match
    // filter silently fell back to the last 200 cross-project lines —
    // wrong proposals, wrong instinct updates, wrong reflex attribution.
    const candidateSids = buildCandidateSids(sessionId, allObs);
    sessionObs = allObs.filter((o) => sidMatches(o.sid, candidateSids));
    if (sessionObs.length === 0) {
      log(`Session ${sessionId} not found (after sid normalization), falling back to last 200 lines`);
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
  const MAX_WINDOW_SECONDS = 300; // v3.15.0 · 1.7 — also break if >5 min elapsed

  for (let i = 0; i < observations.length; i++) {
    const obs = observations[i];
    // Use is_error flag from observe.py OR fallback to output pattern matching
    if (!isError(obs)) continue;

    const errorTool = obs.tool;
    const errorSummary = String(obs.err_msg || obs.output || obs.input || '').slice(0, 200);
    const errorTimeMs = obs.ts ? Date.parse(obs.ts) : NaN;

    // Look ahead for the fix: Edit/Write after error, or same tool succeeding.
    // Break on either index-window OR time-window — whichever triggers first.
    for (let j = i + 1; j < Math.min(i + WINDOW + 1, observations.length); j++) {
      const candidate = observations[j];
      if (!Number.isNaN(errorTimeMs) && candidate.ts) {
        const candidateTimeMs = Date.parse(candidate.ts);
        if (!Number.isNaN(candidateTimeMs) && (candidateTimeMs - errorTimeMs) / 1000 > MAX_WINDOW_SECONDS) break;
      }
      const isFix = (candidate.tool === 'Edit' || candidate.tool === 'Write' || candidate.tool === errorTool)
        && !isError(candidate);

      if (isFix) {
        const fixSummary = String(candidate.input || '').slice(0, 200);
        const hash = shortHash(`${errorTool}-${obs.ts || i}`);
        const fileMatch = extractFilePath(candidate);
        proposals.push({
          id: `gotcha-${errorTool}-${hash}`,
          trigger: errorTool,
          action: `When ${sanitizeProposalAction(errorTool)} fails with similar pattern, try: ${sanitizeProposalAction(fixSummary)}`,
          // v3.25.0 — raised 0.40 -> 0.50. The error-fix detector is the
          // highest-signal heuristic in the pipeline (an explicit error
          // followed by an explicit fix is very specific evidence). The
          // previous 0.40 value sat just under VALIDATE_MIN_CONF=0.50, so
          // every gotcha sat in proposals.json forever waiting for manual
          // /cx-validate. Domain `error-recovery` is already in
          // VALIDATE_AUTO_DOMAINS, so 0.50 unblocks the autonomous path:
          // observation -> error-fix detector -> auto-validate -> instinct
          // -> distill -> law. Decay (-0.05/cycle) and noise tracking still
          // self-correct false positives.
          confidence: 0.50,
          domain: 'error-recovery',
          source: 'session-learner:error-fix',
          status: 'pending',
          detected: TODAY,
          session: obs._resolvedSession || obs.sid || 'unknown',
          _incident: {
            sid: obs._resolvedSession || obs.sid || null,
            ts: obs.ts || null,
            file: fileMatch || null,
            detector: 'error-fix',
          },
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

  // v3.16.0 — raised threshold 5 → 8. Audit retrospective showed the learner
  // emitted 51 repeat-* / workflow-* proposals for the same patterns over and
  // over (Bash exploration, not real workflows). 8 is the empirical sweet spot:
  // catches actual repetition without flagging normal exploration.
  for (const [key, data] of Object.entries(toolInputCounts)) {
    if (data.count >= 8) {
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
        _incident: {
          sid: edits[0]._resolvedSession || edits[0].sid || null,
          ts: edits[0].ts || null,
          file: file,
          detector: 'correction',
        },
      });
    }
  }
  return corrections;
}

// -------------------------------------------------------------------
// Step 3c: Detect workflow chain trigrams (3-tool sequences)
// -------------------------------------------------------------------

function detectWorkflowChains(observations, minCount) {
  // v3.16.0 — raised default 5 → 8 (see detectRepetitions comment above).
  // Tests still pass minCount explicitly so they are unaffected.
  minCount = minCount || 8;
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

      // ReDoS guard — centralized in lib/regex-guard.js (v3.23.4+).
      const trigger = parsed.fields.trigger;
      const triggerReason = unsafeReason(trigger);
      if (triggerReason) {
        log(`Skipping unsafe trigger in ${parsed.fields.id || yamlPath}: ${triggerReason}`);
        continue;
      }
      let triggerRegex;
      try {
        triggerRegex = new RegExp(trigger);
      } catch { continue; }

      // v3.24.0: match trigger against `tool + " " + input` (parity with the
      // injector's matchTarget at injector-engine.js:110). Pre-v3.24.0 this
      // tested only against the bare tool name, so:
      //   - composite triggers like 'Bash.*\.py' never matched (regex requires
      //     content after Bash) → false negatives, occurrences stuck at 0
      //   - alternation triggers like 'Bash|grep' matched every Bash call
      //     (the literal "Bash" alternative matched the tool name) → false
      //     positives ratcheting up by ~200/day
      // The injector and session-learner now share the same match semantics.
      let matched = false;
      for (const o of observations) {
        const toolName = o.tool || '';
        if (!toolName) continue;
        const inputStr = String(o.input || '');
        const matchTarget = toolName + ' ' + inputStr;
        if (triggerRegex.test(matchTarget)) {
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

        // v3.15.0 · 1.3 — also mirror to tracking.json so injector's inline
        // staleness filter sees every instinct, not just the 1 it seeds.
        // (YAML keeps its fields for human readability + backups; the JSON
        // file becomes the operational source of truth for staleness.)
        _mirrorToTracking(parsed.fields.id, TODAY, currentOccurrences + 1);
      }
    } catch (e) {
      log(`Failed to update instinct ${yamlPath}: ${e.message}`);
    }
  }

  if (updated > 0) {
    log(`Updated ${updated} instinct(s)`);
  }
}

const TRACKING_FILE_PATH = path.join(CORTEX_DIR, 'instinct-tracking.json');

function _mirrorToTracking(instinctId, isoDate, count) {
  if (!instinctId) return;
  let tracking = {};
  try { tracking = JSON.parse(fs.readFileSync(TRACKING_FILE_PATH, 'utf8')); } catch {}
  if (!tracking || typeof tracking !== 'object') tracking = {};

  const entry = tracking[instinctId] || {
    count: 0,
    sessions: [],
    projects_seen: [],
    first_seen: isoDate,
  };
  // Never regress the count (injector may have higher value from live PreToolUse)
  if (count > (entry.count || 0)) entry.count = count;
  entry.last_seen = new Date().toISOString();
  if (!entry.first_seen) entry.first_seen = entry.last_seen;
  tracking[instinctId] = entry;

  try {
    const tmp = TRACKING_FILE_PATH + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(tracking, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, TRACKING_FILE_PATH);
  } catch (e) {
    if (process.env.CORTEX_DEBUG) process.stderr.write('[cortex:learner] tracking mirror: ' + e.message + '\n');
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
      // ReDoS guard — centralized in lib/regex-guard.js (v3.23.4+).
      const matcherReason = unsafeReason(reflex.matcher);
      if (matcherReason) {
        log(`Skipping unsafe matcher in reflex ${reflex.id}: ${matcherReason}`);
        continue;
      }
      const matcherRe = new RegExp(reflex.matcher);
      let matched = false;
      let condRe = null;
      if (reflex.condition) {
        const condReason = unsafeReason(reflex.condition);
        if (condReason) {
          log(`Skipping unsafe condition in reflex ${reflex.id}: ${condReason}`);
          continue;
        }
        condRe = new RegExp(reflex.condition, 'i');
      }

      for (let i = 0; i < toolNames.length; i++) {
        if (!matcherRe.test(toolNames[i])) continue;
        if (condRe && !condRe.test(toolInputs[i] || '')) continue;
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

// -------------------------------------------------------------------
// Cross-detector dedup by incident (Sprint 1.4, v3.15.0)
// -------------------------------------------------------------------
//
// Previously an error → 3 edits on the same file generated 3-4 separate
// proposals (one per detector). User saw noise. Now we cluster by
// (session, file, ±5 min) and keep only the highest-confidence survivor,
// attaching the displaced detector names as `merged_from`.
//
// Proposals without `_incident` metadata (repetitions, agent-patterns,
// workflow chains) pass through unchanged — they describe session-wide
// patterns, not file-bound incidents.

function dedupProposalsByIncident(proposals) {
  const INCIDENT_WINDOW_SECONDS = 300;
  const grouped = new Map();
  const passthrough = [];

  for (const p of proposals) {
    const inc = p._incident;
    if (!inc || !inc.sid || !inc.file) {
      passthrough.push(p);
      continue;
    }
    const ts = inc.ts ? Date.parse(inc.ts) : 0;
    const bucket = Math.floor((ts || 0) / (INCIDENT_WINDOW_SECONDS * 1000));
    const key = `${inc.sid}|${inc.file}|${bucket}`;
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(p);
  }

  const kept = [];
  for (const [, bucket] of grouped) {
    if (bucket.length === 1) {
      const p = bucket[0];
      delete p._incident;
      kept.push(p);
      continue;
    }
    // Pick highest-confidence, then longest action as tiebreaker.
    bucket.sort((a, b) => {
      if (b.confidence !== a.confidence) return b.confidence - a.confidence;
      return (b.action || '').length - (a.action || '').length;
    });
    const primary = bucket[0];
    const mergedFrom = bucket.slice(1).map(p => p.source || p.id);
    primary.merged_from = mergedFrom;
    primary.sub_detectors = Array.from(new Set(bucket.map(p => p._incident?.detector).filter(Boolean)));
    delete primary._incident;
    kept.push(primary);
  }

  return [...passthrough.map(p => { delete p._incident; return p; }), ...kept];
}

// -------------------------------------------------------------------
// Step 5c: Correlate impact funnel — emit follow/reject events
// -------------------------------------------------------------------
//
// For each `inject` event in impact.jsonl that matches this session and
// has no correlating `follow` yet, scan observations to emit one follow
// event. Heuristic v1 (conservative):
//   - followed=true  if next observation in same sid is NOT an error
//   - followed=false if no observation after the inject timestamp
//   - err_after=true if is_error=true within 10 events post-inject
// A marker `impact-correlated-<sid>` lives in tmp to avoid double-write.

// v3.19.3: observe.py truncated session_id to [:24] before this release, so
// observations carry the prefix while impact.jsonl carries the full 36-char
// UUID. Match either form so retroactive correlation works on legacy data.
function sidMatches(eventSid, candidateSids) {
  if (!eventSid) return false;
  if (candidateSids.has(eventSid)) return true;
  if (typeof eventSid === 'string' && eventSid.length > 24) {
    if (candidateSids.has(eventSid.slice(0, 24))) return true;
  }
  return false;
}

function buildCandidateSids(sidOrSids, observations) {
  const set = new Set();
  const addBoth = (s) => {
    if (!s) return;
    set.add(s);
    if (typeof s === 'string' && s.length > 24) set.add(s.slice(0, 24));
  };
  if (typeof sidOrSids === 'string') addBoth(sidOrSids);
  else if (sidOrSids && typeof sidOrSids[Symbol.iterator] === 'function') {
    for (const s of sidOrSids) addBoth(s);
  }
  for (const o of observations) if (o && o.sid) addBoth(o.sid);
  return set;
}

function correlateImpactEvents(observations, sidOrSids) {
  if (!impactLog || observations.length === 0) return 0;

  // Same orphan-sid rescue as correlateReflexFeedback (v3.19.1).
  const candidateSids = buildCandidateSids(sidOrSids, observations);
  if (candidateSids.size === 0) return 0;

  const impactFile = impactLog.IMPACT_FILE;
  let raw;
  try {
    raw = fs.readFileSync(impactFile, 'utf8');
  } catch {
    return 0;
  }

  // Parse jsonl, collect inject events for any candidate sid and existing follow ids
  const injects = [];
  const correlatedIids = new Set();
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    try {
      const ev = JSON.parse(line);
      if (!sidMatches(ev.sid, candidateSids)) continue;
      if (ev.ev === 'inject' && ev.iid) injects.push(ev);
      else if (ev.ev === 'follow' && ev.iid) correlatedIids.add(ev.iid + '|' + (ev.inject_ts || ''));
    } catch {
      // skip malformed
    }
  }
  if (injects.length === 0) return 0;

  // Sort observations chronologically (they already are, but belt+braces)
  const sortedObs = [...observations].sort((a, b) => (a.ts || '').localeCompare(b.ts || ''));

  let emitted = 0;
  for (const inj of injects) {
    const key = inj.iid + '|' + inj.ts;
    if (correlatedIids.has(key)) continue;

    // Find first observation strictly after the inject timestamp
    const idx = sortedObs.findIndex((o) => (o.ts || '') > inj.ts);
    if (idx < 0) {
      // No later obs yet — cannot correlate in this session
      continue;
    }

    const next = sortedObs[idx];
    const window = sortedObs.slice(idx, idx + 10);
    const errAfter = window.some((o) => o.err === true || o.err === 'true');
    const followed = next.err !== true && next.err !== 'true';

    // Embed inject_ts in the emitted event so future runs dedupe correctly.
    impactLog.logEvent('follow', {
      iid: inj.iid,
      sid: inj.sid,
      followed,
      err_after: errAfter,
      win: window.length,
      inject_ts: inj.ts,
    });
    emitted += 1;

    // v3.19.4: emit `outcome` event so the impact funnel closes the loop.
    // Pre-v3.19.4 the schema accepted outcome events but no code path
    // produced them, so /cx-status --impact always reported "outcome: 0".
    // The funnel definition treats `error_within_10` as the diagnostic
    // signal (was the inject followed by a downstream error?). Same
    // 10-event window already used for follow.
    impactLog.logEvent('outcome', {
      iid: inj.iid,
      sid: inj.sid,
      error_within_10: errAfter,
      inject_ts: inj.ts,
    });
  }
  return emitted;
}

// -------------------------------------------------------------------
// Step 5d: Reflex auto-evaluation (v3.18.0)
// -------------------------------------------------------------------
//
// For each `inject` event with iid prefixed `reflex:` in this session,
// run the reflex's evaluator against observations.jsonl and emit a
// feedback event with source: agent. Updates usefulCount/noiseCount
// on the reflex and applies opt-in auto-disable threshold.
// See docs/AUTO-EVALUATION.md.

function evalToolSubstitution(ev, sortedObs, currentIdx) {
  // v3.23.7: parity with evalErrorMonitor's "aligned-or-ignored" semantics.
  // Pre-v3.23.7 this only emitted 'useful' on an immediate pivot to
  // expected_tool — but agents rarely re-execute a Bash with the recommended
  // alternative once the original cat/find/grep already returned the data
  // they needed. Real-world audit on fs-cortex showed bash-grep-use-grep-tool
  // at 0% pivot rate and bash-find-use-glob at 9% despite the warning being
  // pedagogically useful. Same structural bias toward 'ignore' that
  // evalErrorMonitor had before v3.19.4. New shape:
  //   1. Immediate pivot to expected_tool → useful (strong positive signal)
  //   2. Reincidence with anti_pattern in window → noise (warning ignored)
  //   3. Window has follow-up observations and no reincidence → useful
  //      (the warning either prevented the anti-behavior or was absorbed
  //      without harm — at minimum the session continued normally)
  //   4. Empty window (no follow-up) → ignore (cannot judge)
  //
  // Bias remains conservative: noise only fires on an actual reincidence,
  // never on absence of pivot.
  const window = ev.window || 3;
  const slice = sortedObs.slice(currentIdx + 1, currentIdx + 1 + window);
  let antiPattern = null;
  if (ev.anti_pattern) {
    try { antiPattern = new RegExp(ev.anti_pattern, 'i'); } catch {}
  }
  // Pass 1: scan for pivot AND reincidence in the window. Reincidence wins
  // over pivot if both happen (the model partially listened but kept the bug).
  let sawPivot = false;
  for (const o of slice) {
    if (o.tool === ev.expected_tool) sawPivot = true;
    if (o.tool === ev.anti_tool && antiPattern && antiPattern.test(String(o.input || ''))) {
      return 'noise';
    }
  }
  if (sawPivot) return 'useful';
  // No reincidence, no pivot — judge by whether the agent kept working.
  if (slice.length === 0) return 'ignore';
  return 'useful';
}

function evalPreconditionCheck(ev, sortedObs, currentIdx) {
  const matchedCall = sortedObs[currentIdx];
  if (!matchedCall) return 'ignore';
  const fieldName = ev.match_field || 'file_path';

  let matchValue = null;
  try {
    const input = typeof matchedCall.input === 'string'
      ? JSON.parse(matchedCall.input)
      : (matchedCall.input || {});
    matchValue = input[fieldName];
  } catch {}
  if (!matchValue) return 'ignore';

  const lookback = ev.lookback || 10;
  const start = Math.max(0, currentIdx - lookback);
  for (let i = start; i < currentIdx; i++) {
    const o = sortedObs[i];
    if (o.tool !== ev.precondition_tool) continue;
    try {
      const input = typeof o.input === 'string'
        ? JSON.parse(o.input)
        : (o.input || {});
      if (input[fieldName] === matchValue) return 'useful';
    } catch {}
  }
  // Precondition NOT satisfied — only call it noise if an error followed.
  if (matchedCall.err === true || matchedCall.err === 'true') return 'noise';
  return 'ignore';
}

function evalErrorMonitor(ev, sortedObs, currentIdx) {
  // v3.19.4: pre-release this only emitted 'noise' or 'ignore' (never 'useful'),
  // condemning the 16/21 reflexes with this evaluator type to a structural bias
  // toward noise in the impact funnel (`agent → useful: 0.0000`). The new
  // semantics: if the reminder fired AND the user/agent took a follow-up action
  // AND no matching error occurred in the window, that IS a useful outcome —
  // the reminder either prevented the error or was redundant-but-aligned.
  // Bias remains conservative: an empty window (no follow-up) still emits
  // 'ignore' because we have no evidence either way.
  //
  // v3.24.0: extend the noise-detection slice to ALSO scan the next `window`
  // observations strictly AFTER the inject (not just the inject itself + the
  // first window-sized slot starting at currentIdx). With window=1 reflexes
  // (read-large-md-limit, large-doc-edit-anchor) the old logic checked exactly
  // 1 cell — `obs[currentIdx]` — so errors that happened on the next call were
  // invisible. The new noise slice covers `[currentIdx, currentIdx+1+window)`
  // — the inject itself (when the inject IS the failing call) plus the entire
  // post-inject window. window=1 now scans 2 cells; window=10 scans 11.
  const window = ev.window || 10;
  let pattern;
  try { pattern = new RegExp(ev.error_pattern, 'i'); } catch { return 'ignore'; }
  const noiseSlice = sortedObs.slice(currentIdx, currentIdx + 1 + window);
  for (const o of noiseSlice) {
    if ((o.err === true || o.err === 'true') && pattern.test(String(o.err_msg || ''))) {
      return 'noise';
    }
  }
  // Need at least one follow-up observation strictly after the inject to claim
  // useful; otherwise the reminder went into the void and we can't judge.
  const followUp = sortedObs.slice(currentIdx + 1, currentIdx + 1 + window);
  if (followUp.length === 0) return 'ignore';
  return 'useful';
}

function evaluateReflex(reflex, sortedObs, currentIdx) {
  const evaluator = reflex && reflex.evaluator;
  if (!evaluator || !evaluator.type) return 'ignore';
  try {
    if (evaluator.type === 'tool-substitution') return evalToolSubstitution(evaluator, sortedObs, currentIdx);
    if (evaluator.type === 'precondition-check') return evalPreconditionCheck(evaluator, sortedObs, currentIdx);
    if (evaluator.type === 'error-monitor')      return evalErrorMonitor(evaluator, sortedObs, currentIdx);
  } catch (e) {
    log(`Reflex evaluator threw for ${reflex.id}: ${e.message}`);
  }
  return 'ignore';
}

function correlateReflexFeedback(observations, sidOrSids) {
  if (!impactLog || observations.length === 0) return 0;

  // Accept either a single sid (legacy) or an array/Set of candidate sids.
  // When the harness Stop event carries a sid that produced no observations
  // (transient subagent / slash command sessions), the fallback observation
  // window represents other real sessions whose injects we still want to
  // auto-rate. Build a candidate set from both sources.
  const candidateSids = buildCandidateSids(sidOrSids, observations);
  if (candidateSids.size === 0) return 0;

  const reflexData = readJsonFile(REFLEXES_PATH);
  if (!reflexData || !Array.isArray(reflexData.reflexes)) return 0;

  // v3.22.1: auto-heal — backfill `resetAt` on the three bash-* reflexes
  // that v3.20.0 reset (matchers refined, useful/noise counters zeroed,
  // but no boundary marker was written). Idempotent: only sets the field
  // when missing AND the reflex matches the known-reset shape (fireCount
  // > 0 AND noiseCount === 0 AND usefulCount === 0). Future resets must
  // set `resetAt` directly at the time of reset.
  const V3_20_0_RESET_AT = '2026-04-26T13:31:57+02:00';
  const KNOWN_V3_20_0_RESETS = new Set([
    'bash-cat-use-read',
    'bash-grep-use-grep-tool',
    'bash-find-use-glob',
  ]);
  let autoHealed = false;
  for (const r of reflexData.reflexes) {
    if (!KNOWN_V3_20_0_RESETS.has(r.id)) continue;
    if (r.resetAt) continue;
    const fires = r.fireCount || 0;
    const useful = r.usefulCount || 0;
    const noise = r.noiseCount || 0;
    if (fires > 0 && useful === 0 && noise === 0) {
      r.resetAt = V3_20_0_RESET_AT;
      autoHealed = true;
      log(`Auto-healed reflex ${r.id}: resetAt = ${V3_20_0_RESET_AT}`);
    }
  }
  if (autoHealed) writeJsonFile(REFLEXES_PATH, reflexData);

  const reflexById = Object.create(null);
  for (const r of reflexData.reflexes) reflexById[r.id] = r;

  const impactFile = impactLog.IMPACT_FILE;
  let raw;
  try { raw = fs.readFileSync(impactFile, 'utf8'); } catch { return 0; }

  const reflexInjects = [];
  const alreadyRated = new Set();
  // v3.24.0: rebuild counter from impact.jsonl when resetAt is present.
  // Pre-v3.24.0, when a reflex's counters were reset (manually or via the
  // v3.20.0 auto-heal) but impact.jsonl retained its feedback history, the
  // alreadyRated set blocked re-emission and the counters never recovered.
  // Now we count post-resetAt feedback events directly into rebuild totals,
  // and apply max(current, rebuilt) at the end so the counters self-heal.
  const rebuildUseful = Object.create(null);
  const rebuildNoise = Object.create(null);
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    try {
      const ev = JSON.parse(line);
      if (!sidMatches(ev.sid, candidateSids)) continue;
      if (ev.ev === 'inject' && typeof ev.iid === 'string' && ev.iid.startsWith('reflex:')) {
        reflexInjects.push(ev);
      } else if (ev.ev === 'feedback' && ev.source === 'agent' && ev.inject_ts && typeof ev.iid === 'string' && ev.iid.startsWith('reflex:')) {
        alreadyRated.add(ev.iid + '|' + ev.inject_ts);
      }
    } catch {}
  }
  // Second pass: rebuild totals from ALL feedback events (any sid), bounded
  // by each reflex's own resetAt timestamp. Source-of-truth for counters
  // when impact.jsonl outlives a reset.
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    try {
      const ev = JSON.parse(line);
      if (ev.ev !== 'feedback' || ev.source !== 'agent') continue;
      if (typeof ev.iid !== 'string' || !ev.iid.startsWith('reflex:')) continue;
      const rid = ev.iid.slice('reflex:'.length);
      const r = reflexById[rid];
      if (!r) continue;
      if (r.resetAt && (ev.ts || '') < r.resetAt) continue;
      if (ev.rating === 'useful') rebuildUseful[rid] = (rebuildUseful[rid] || 0) + 1;
      else if (ev.rating === 'noise') rebuildNoise[rid] = (rebuildNoise[rid] || 0) + 1;
    } catch {}
  }
  // Apply rebuild totals where they exceed current counters (self-heal).
  for (const r of reflexData.reflexes) {
    const u = rebuildUseful[r.id] || 0;
    const n = rebuildNoise[r.id] || 0;
    if (u > (r.usefulCount || 0)) {
      log(`Rebuilt usefulCount for ${r.id}: ${r.usefulCount || 0} -> ${u}`);
      r.usefulCount = u;
      autoHealed = true;
    }
    if (n > (r.noiseCount || 0)) {
      log(`Rebuilt noiseCount for ${r.id}: ${r.noiseCount || 0} -> ${n}`);
      r.noiseCount = n;
      autoHealed = true;
    }
  }
  if (autoHealed) writeJsonFile(REFLEXES_PATH, reflexData);
  if (reflexInjects.length === 0) return 0;

  const sortedObs = [...observations].sort((a, b) => (a.ts || '').localeCompare(b.ts || ''));
  let emitted = 0;
  let reflexesChanged = false;
  const autoDisable = process.env.CORTEX_AGENT_DISABLE_REFLEXES === '1';

  for (const inj of reflexInjects) {
    const key = inj.iid + '|' + inj.ts;
    if (alreadyRated.has(key)) continue;

    const reflexId = inj.iid.slice('reflex:'.length);
    const reflex = reflexById[reflexId];
    if (!reflex) continue;

    // The inject is emitted in PreToolUse, so the matched observation is
    // the first one with ts >= inject ts.
    const idx = sortedObs.findIndex(o => (o.ts || '') >= inj.ts);
    if (idx < 0) continue; // Cannot evaluate without follow-up data

    const rating = evaluateReflex(reflex, sortedObs, idx);

    impactLog.logEvent('feedback', {
      iid: inj.iid,
      sid: inj.sid,
      rating,
      source: 'agent',
      inject_ts: inj.ts,
    });
    emitted += 1;

    if (rating === 'useful') {
      reflex.usefulCount = (reflex.usefulCount || 0) + 1;
      reflexesChanged = true;
    } else if (rating === 'noise') {
      reflex.noiseCount = (reflex.noiseCount || 0) + 1;
      reflexesChanged = true;

      if (autoDisable) {
        const fireCount = reflex.fireCount || 0;
        const useful = reflex.usefulCount || 0;
        const noise = reflex.noiseCount || 0;
        // v3.24.1: require useful < noise (ratio < 1.0) in addition to the
        // existing absolute thresholds. Pre-v3.24.1 a reflex that earned
        // 111 useful and only 3 noise (ratio 37x — clearly working) still
        // got auto-disabled because the threshold only looked at the noise
        // counter in isolation. The new gate disables only reflexes whose
        // signal is genuinely noise-dominated.
        if (
          noise >= 3 &&
          fireCount >= 10 &&
          useful < noise &&
          reflex.enabled !== false
        ) {
          reflex.enabled = false;
          log(`Auto-disabled reflex ${reflexId} (noiseCount=${noise} usefulCount=${useful} fireCount=${fireCount} ratio=${(useful / Math.max(noise, 1)).toFixed(2)})`);
          try {
            const today = new Date().toISOString().slice(0, 10);
            const klogLine = `${today} | reflex-auto-disable | ${reflexId} | noiseCount=${noise} usefulCount=${useful} fireCount=${fireCount} | session-learner\n`;
            fs.appendFileSync(path.join(CORTEX_DIR, 'knowledge-log.md'), klogLine);
          } catch {}
        }
      }
    }
  }

  if (reflexesChanged) {
    writeJsonFile(REFLEXES_PATH, reflexData);
  }
  return emitted;
}

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

    // Step 5c: Correlate impact funnel (Sprint 0, v3.14.0; orphan-sid fix v3.19.1)
    try {
      const harnessSid = (stdinData && stdinData.session_id) || observations[0].sid || null;
      const correlated = correlateImpactEvents(observations, harnessSid);
      if (correlated > 0) log(`Correlated ${correlated} impact follow event(s)`);
    } catch (e) {
      log(`Impact correlation failed: ${e.message}`);
    }

    // Step 5d: Reflex auto-evaluation (v3.18.0, fixed v3.19.1)
    try {
      const harnessSid = (stdinData && stdinData.session_id) || observations[0].sid || null;
      const rated = correlateReflexFeedback(observations, harnessSid);
      if (rated > 0) log(`Auto-rated ${rated} reflex inject event(s)`);
    } catch (e) {
      log(`Reflex feedback failed: ${e.message}`);
    }

    // Step 5e: Outcome auto-ranking — nudge instinct confidence based on
    // observed outcome cleanliness. Sprint 5, v3.20.0. Reflexes are skipped
    // by impact_log.apply_outcome_nudges (they have their own accounting).
    try {
      const { spawnSync } = require('child_process');
      const impactPy = path.join(__dirname, 'lib', 'impact_log.py');
      if (fs.existsSync(impactPy)) {
        const r = spawnSync('python3', [impactPy, 'outcome-nudge', '--days', '14', '--apply', '--json'],
          { encoding: 'utf8', timeout: 5000, env: process.env });
        if (r.status === 0 && r.stdout) {
          try {
            const out = JSON.parse(r.stdout);
            const n = (out.applied || []).length;
            if (n > 0) log(`Applied ${n} outcome-nudge(s) to instinct YAMLs`);
          } catch (_) { /* JSON parse error — skip silently */ }
        }
      }
    } catch (e) {
      log(`Outcome nudge failed: ${e.message}`);
    }

    // Step 6: Combine all proposals with session_date for cross-day tracking
    const rawProposals = [
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

    // v3.15.0 · Step 6b — cross-detector dedup by incident
    const dedupedProposals = dedupProposalsByIncident(rawProposals);
    const collapsed = rawProposals.length - dedupedProposals.length;
    if (collapsed > 0) log(`Collapsed ${collapsed} duplicate proposal(s) across detectors`);

    // v3.26.0 · Step 6c — cross-day boost universal (applied AFTER dedup to avoid double-counting)
    const allProposals = dedupedProposals.map(applyCrossDayBoost);
    const boosted = allProposals.filter(p => p.cross_day_count > 1).length;
    if (boosted > 0) log(`Cross-day boost applied to ${boosted} proposal(s)`);

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
    detectCommandUsage, dedupProposalsByIncident,
    // v3.14.0 — impact funnel correlator (orphan-sid fix v3.19.1)
    correlateImpactEvents,
    // v3.18.0 — reflex auto-evaluation
    evalToolSubstitution, evalPreconditionCheck, evalErrorMonitor,
    evaluateReflex, correlateReflexFeedback,
  };
}
