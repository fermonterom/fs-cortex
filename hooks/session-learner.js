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
const { escapeRegex } = require(path.join(__dirname, 'lib', 'regex-utils'));

// Optional impact funnel writer — never blocks learner if require fails.
let impactLog = null;
try {
  impactLog = require(path.join(__dirname, 'lib', 'impact_log.js'));
} catch {}

const { applyCrossDayBoost } = require(path.join(__dirname, 'lib', 'cross-day-tracker'));
const {
  migrateAcceptedRejectedToHistory,
  splitForPersist,
  HISTORY_LOCK_PATH,
} = require(path.join(__dirname, 'lib', 'proposals-storage'));
const fileLock = require(path.join(__dirname, 'lib', 'file-lock'));

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

// v3.27.0 detector constants
const AGENT_SUBTYPE_ERROR_THRESHOLD = 0.30;
const AGENT_SUBTYPE_MIN_USES = 3;
const FILE_COUPLING_MIN_COUNT = 5;

// -- Timeout: hard cap at 15 seconds --
// .unref() so requiring this module in tests doesn't keep the process alive 15s.
const TIMEOUT = setTimeout(() => {
  log('Timeout reached (15s), exiting gracefully');
  process.exit(0);
}, 15000).unref();

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
    // v3.35.2 (#47 follow-up): mode applies on create; chmod heals files
    // created 0644 by older versions. Operator-only, like timeline.jsonl.
    fs.appendFileSync(LOG_PATH, line, { mode: 0o600 });
    try { fs.chmodSync(LOG_PATH, 0o600); } catch {}
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
  // v3.29.4: SHA256 instead of MD5. MD5 throws in Node FIPS-enforced runtimes,
  // which aborted the entire Stop hook silently (outer try/catch in main()).
  return crypto.createHash('sha256').update(str).digest('hex').slice(0, 8);
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

// v3.36.1 (audit P2-hollow-gotcha-actions): the fix summary used to be the
// raw observed tool_input sliced to 200 chars — a JSON blob with file_path +
// old_string, cut mid-string. 28 live proposals were single-use patches
// masquerading as patterns and 16 more were empty ("try: " with nothing
// after). Extract a semantic summary instead: the command for Bash, the
// basename for file tools, the description/prompt for Agent. Returns '' when
// there is nothing teachable — caller must skip the pair.
function summarizeFixInput(tool, rawInput) {
  const s = String(rawInput || '');
  let parsed = null;
  try { parsed = JSON.parse(s); } catch (_) { /* not JSON — plain text input */ }
  if (parsed && typeof parsed === 'object') {
    if (typeof parsed.command === 'string' && parsed.command.trim()) {
      return parsed.command.trim().slice(0, 160);
    }
    if (typeof parsed.file_path === 'string' && parsed.file_path.trim()) {
      return `${tool} ${path.basename(parsed.file_path.trim())}`;
    }
    if (typeof parsed.description === 'string' && parsed.description.trim()) {
      return parsed.description.trim().slice(0, 160);
    }
    if (typeof parsed.prompt === 'string' && parsed.prompt.trim()) {
      return parsed.prompt.trim().slice(0, 160);
    }
    // Object input with none of the known fields — nothing teachable.
    return '';
  }
  return s.trim().slice(0, 160);
}

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
        const fixSummary = summarizeFixInput(candidate.tool, candidate.input);
        // No teachable fix content → keep scanning the window for a better
        // candidate instead of emitting a hollow "try: " proposal. Threshold
        // 10 keeps the shortest real summaries ("Edit util.js") while
        // dropping empty/garbage ones.
        if (fixSummary.length < 10) continue;
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
          session_id: obs._resolvedSession || obs.sid || '',
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
// Step 3b: Detect user corrections (same file edited 3+ times with overlapping regions)
// (v3.29.0 §4.6: detectRepetitions removed — descriptive action, sub-floor
// confidence 0.30, generated 210 unactionable proposals in production with
// no rewrite path. Tests and call site retired in the same release.)
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

// v3.29.0 (Sprint 8 §4.3): rewritten emit.
// Pre-v3.29: domain 'user-preference' (HUMAN but semantically wrong — a
// repeat-correct on the same file is a code-quality signal, not a user
// preference), conf 0.40 (below auto-validate floor), action descriptive.
// New emit: domain 'correction' (HUMAN-gated per §4.1's whitelist),
// conf 0.55, imperative action telling Claude to scan recent commits
// BEFORE re-editing the file, scope 'project' so a correction in repo A
// never fires in repo B. The 3-edits-with-overlap heuristic is preserved.
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

  const projectId = (observations[0] && observations[0]._projectId) || 'global';

  for (const [file, edits] of Object.entries(fileEdits)) {
    // Require 3+ edits AND overlapping regions to reduce false positives
    if (edits.length >= 3 && hasOverlappingEdits(edits)) {
      const baseName = path.basename(file);
      const hash = shortHash(file);
      corrections.push({
        id: `correction-${hash}`,
        trigger: `Edit.*${escapeRegex(baseName)}`,
        action: sanitizeProposalAction(
          `Before editing ${baseName}, scan recent commits — corrected ${edits.length}+ times. Pattern likely needs deeper attention.`
        ),
        confidence: 0.55,
        domain: 'correction',
        scope: 'project',          // v3.29.0 §4.3
        project_id: projectId,
        source: 'session-learner:correction',
        status: 'pending',
        detected: TODAY,
        session_id: edits[0]._resolvedSession || edits[0].sid || '',
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
// Step 3d: Detect recurring Agent tool patterns (same purpose across sessions)
// (v3.29.0 §4.6: detectWorkflowChains removed — trigger emitted only the
// first tool of the trigram so sequence context was lost in the resulting
// instinct, action was a descriptive statistic, no viable rewrite path.
// Tests and call site retired in the same release.)
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

  // v3.29.0 (Sprint 8 §4.5): floor raised 3 → 4. At threshold 3 the first
  // emitted confidence was exactly 0.55 (0.40 + 3*0.05), tied with the
  // VALIDATE_MIN_CONF auto-floor — borderline proposals would either just
  // barely auto-validate or just barely be skipped depending on rounding.
  // At threshold 4 the first emitted confidence is 0.60, giving a clear
  // margin above the floor so the operator only ever sees patterns with
  // meaningful repetition.
  return Object.entries(groups)
    .filter(([_, items]) => items.length >= 4)
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
        session_id: items[0].obs._resolvedSession || items[0].obs.sid || '',
      };
    });
}

// -------------------------------------------------------------------
// Step 3e-g: New detectors v3.27.0
// -------------------------------------------------------------------

function detectAgentSubtypes(observations, resolvedSessionId) {
  const agentObs = observations.filter(o => o.tool === 'Agent' && o.input);
  if (agentObs.length < AGENT_SUBTYPE_MIN_USES) return [];

  // v3.28.5 — slugify subagent_type. The raw value comes from
  // JSON.parse(obs.input).subagent_type which is user-controlled and may
  // contain '/', '..', spaces, quotes, or arbitrary length text. Embedding
  // it raw in the proposal id (which becomes a filename when /cx-validate
  // serializes to YAML) opens path-traversal and YAML-injection vectors.
  // Allowlist [a-z0-9_-], cap at 40 chars, hash if anything was stripped.
  function slugifySubtype(raw) {
    const lower = String(raw).toLowerCase();
    const slug = lower.replace(/[^a-z0-9_-]/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');
    if (!slug) return 'unknown';
    // v3.29.4: pre-v3.29.4 the second &&-operand recomputed `slug` so the
    // check was a tautology — sanitized-but-collision-prone inputs (e.g.
    // "foo/bar" and "foo-bar" both → "foo-bar") returned the same slug
    // and the hash-suffix path never ran. Correct check: only skip the
    // hash when the input was already a clean lowercase slug.
    if (slug.length <= 40 && slug === lower) {
      return slug;
    }
    return slug.slice(0, 32) + '-' + shortHash(lower).slice(0, 7);
  }

  const bySubtype = {};
  const subtypeRaw = {};  // remember the original for the action message
  for (const obs of agentObs) {
    let subtype = 'unknown';
    let raw = 'unknown';
    try {
      const inp = JSON.parse(obs.input);
      if (inp.subagent_type) {
        raw = String(inp.subagent_type);
        subtype = slugifySubtype(raw);
      }
    } catch {}
    if (!bySubtype[subtype]) bySubtype[subtype] = { total: 0, errors: 0 };
    if (!subtypeRaw[subtype]) subtypeRaw[subtype] = raw;
    bySubtype[subtype].total++;
    if (isError(obs)) bySubtype[subtype].errors++;
  }

  const proposals = [];
  for (const subtype of Object.keys(bySubtype)) {
    const { total, errors } = bySubtype[subtype];
    if (total < AGENT_SUBTYPE_MIN_USES) continue;
    const rate = errors / total;
    if (rate < AGENT_SUBTYPE_ERROR_THRESHOLD) continue;

    const ratePercent = Math.round(rate * 100);
    const rawDisplay = subtypeRaw[subtype] || subtype;
    // v3.29.0 (Sprint 8 §4.4): imperative action + conf 0.45 → 0.50.
    // Domain 'agent-quality' was already correct; pre-v3.29 it was an orphan
    // (not in any whitelist), now registered HUMAN-gated in §4.1. Confidence
    // lift brings it to the validate floor so the operator sees it in
    // /cx-validate without being auto-accepted.
    proposals.push({
      id: `agent-error-rate-${subtype}`,
      trigger: `Agent`,
      action: sanitizeProposalAction(
        `Before spawning Agent subagent_type="${rawDisplay}" again, switch to general-purpose or refine the prompt — current type errored in ${ratePercent}% of ${total} uses.`
      ),
      confidence: 0.50,
      domain: 'agent-quality',
      source: 'session-learner:agent-error-rate',
      status: 'pending',
      detected: TODAY,
      session_id: resolvedSessionId || agentObs[0]._resolvedSession || agentObs[0].sid || '',
      tags: ['agent-quality', `subtype-${subtype}`],
      occurrences: total,
    });
  }
  return proposals;
}

// v3.29.0 (Sprint 8 §4.2): rewritten emit. Pre-v3.29 this detector produced
// `trigger: 'Edit|baseA|baseB'` — a degenerate alternation that the runtime
// matcher (`toolName + " " + JSON.stringify(input)`) interpreted as "match the
// literal string 'Edit' OR 'baseA' OR 'baseB'" anywhere, losing the coupling
// relationship entirely. The new form `Edit.*(?:${escA}|${escB})` requires the
// matcher to see `Edit` followed by either escaped filename inside the
// stringified tool input — which IS the case because injector-engine.js
// concatenates tool input verbatim into matchTarget. confidence 0.40 → 0.55
// brings it above the auto-validate floor (0.50) so the operator at least
// sees these in /cx-validate; domain stays 'coupling' (HUMAN-gated in §4.1)
// so they will NOT auto-promote without manual review. scope: 'project' is
// critical — a coupling between repo-local files in project A must never
// fire in project B.
function detectFileCoupling(observations, resolvedSessionId) {
  const editObs = observations.filter(o =>
    (o.tool === 'Edit' || o.tool === 'Write') && o.input
  );
  if (editObs.length < FILE_COUPLING_MIN_COUNT * 2) return [];

  const bySession = {};
  for (const obs of editObs) {
    let filePath = '';
    try {
      const inp = JSON.parse(obs.input);
      filePath = inp.file_path || '';
    } catch {}
    if (!filePath) continue;
    const sid = obs.sid || 'unknown';
    if (!bySession[sid]) bySession[sid] = new Set();
    bySession[sid].add(filePath);
  }

  const pairCounts = {};
  for (const sid of Object.keys(bySession)) {
    const files = [...bySession[sid]].sort();
    for (let i = 0; i < files.length; i++) {
      for (let j = i + 1; j < files.length; j++) {
        const key = files[i] + '\x00' + files[j];
        pairCounts[key] = (pairCounts[key] || 0) + 1;
      }
    }
  }

  // Per-detector project pin: the project_id we attach below is what makes
  // scope:'project' meaningful at injection time. Fall back to 'global' only
  // when the observation chain doesn't carry one (legacy data); injector
  // still filters by scope so this is safe.
  const projectId = (observations[0] && observations[0]._projectId) || 'global';

  const proposals = [];
  for (const key of Object.keys(pairCounts)) {
    const sessionCount = pairCounts[key];
    if (sessionCount < FILE_COUPLING_MIN_COUNT) continue;
    const sepIdx = key.indexOf('\x00');
    const a = key.slice(0, sepIdx);
    const b = key.slice(sepIdx + 1);
    const baseA = path.basename(a);
    const baseB = path.basename(b);
    const triggerRegex = `Edit.*(?:${escapeRegex(baseA)}|${escapeRegex(baseB)})`;
    const hash = shortHash(key);
    proposals.push({
      id: `coupling-${hash}`,
      trigger: triggerRegex,
      action: sanitizeProposalAction(
        `When editing ${baseA}, also check ${baseB} — coupled in ${sessionCount}+ sessions in this project.`
      ),
      confidence: 0.55,
      domain: 'coupling',
      scope: 'project',          // v3.29.0 §4.2: must NOT be global
      project_id: projectId,
      source: 'session-learner:file-coupling',
      status: 'pending',
      detected: TODAY,
      session_id: resolvedSessionId || observations[0]._resolvedSession || observations[0].sid || '',
      tags: ['coupling'],
      occurrences: sessionCount,
    });
  }
  return proposals;
}

function detectTimeOfDayPatterns(observations) {
  if (observations.length === 0) return [];
  const PRODUCTIVITY_PATH = path.join(CORTEX_DIR, 'productivity-patterns.json');

  const byHour = {};
  for (const obs of observations) {
    if (!obs.ts) continue;
    const hour = String(obs.ts).slice(11, 13);
    if (!/^\d{2}$/.test(hour)) continue;
    if (!byHour[hour]) byHour[hour] = { tools: {}, errors: 0, total: 0 };
    byHour[hour].total++;
    const tool = obs.tool || 'unknown';
    byHour[hour].tools[tool] = (byHour[hour].tools[tool] || 0) + 1;
    if (isError(obs)) byHour[hour].errors++;
  }

  // Merge + write. Read existing as late as possible to minimize race window.
  // Known race: two concurrent Stop hooks may lose one session's contribution (same
  // limitation as cross-day-tracker.js; full lock deferred).
  try {
    ensureDir(CORTEX_DIR);

    let existingByHour = {};
    if (fs.existsSync(PRODUCTIVITY_PATH)) {
      let raw;
      try {
        raw = fs.readFileSync(PRODUCTIVITY_PATH, 'utf8');
        existingByHour = JSON.parse(raw).by_hour || {};
      } catch (_) {
        return []; // Corrupted file — abort write to preserve existing data
      }
    }

    const merged = { ...existingByHour };
    for (const hour of Object.keys(byHour)) {
      if (!merged[hour]) merged[hour] = { tools: {}, errors: 0, total: 0 };
      merged[hour].total += byHour[hour].total;
      merged[hour].errors += byHour[hour].errors;
      for (const tool of Object.keys(byHour[hour].tools)) {
        merged[hour].tools[tool] = (merged[hour].tools[tool] || 0) + byHour[hour].tools[tool];
      }
    }

    // Compute summary + buckets + insights
    const summary = {};
    for (const hour of Object.keys(merged).sort()) {
      const h = merged[hour];
      const sortedTools = Object.entries(h.tools).sort((a, b) => b[1] - a[1]);
      summary[hour] = {
        total: h.total,
        errors: h.errors,
        error_rate: h.total > 0 ? Math.round((h.errors / h.total) * 100) / 100 : 0,
        top_tools: sortedTools.slice(0, 3).map(([t, c]) => `${t}(${c})`),
      };
    }

    const buckets = {
      morning:   { range: '06-12', total: 0, errors: 0, tools: {} },
      afternoon: { range: '12-18', total: 0, errors: 0, tools: {} },
      evening:   { range: '18-22', total: 0, errors: 0, tools: {} },
      night:     { range: '22-06', total: 0, errors: 0, tools: {} },
    };
    for (const hour of Object.keys(merged)) {
      const h = parseInt(hour, 10);
      let bucket;
      if (h >= 6 && h < 12) bucket = 'morning';
      else if (h >= 12 && h < 18) bucket = 'afternoon';
      else if (h >= 18 && h < 22) bucket = 'evening';
      else bucket = 'night';
      buckets[bucket].total += merged[hour].total;
      buckets[bucket].errors += merged[hour].errors;
      for (const tool of Object.keys(merged[hour].tools)) {
        buckets[bucket].tools[tool] = (buckets[bucket].tools[tool] || 0) + merged[hour].tools[tool];
      }
    }
    for (const b of Object.keys(buckets)) {
      const bucket = buckets[b];
      bucket.error_rate = bucket.total > 0 ? Math.round((bucket.errors / bucket.total) * 100) / 100 : 0;
      const sorted = Object.entries(bucket.tools).sort((a, b) => b[1] - a[1]);
      bucket.top_tools = sorted.slice(0, 3).map(([t]) => t);
    }

    const insights = [];
    const peakErrorBucket = Object.entries(buckets).sort((a, b) => b[1].error_rate - a[1].error_rate)[0];
    if (peakErrorBucket && peakErrorBucket[1].error_rate > 0.10) {
      insights.push(`Pico de errores: ${peakErrorBucket[0]} (${peakErrorBucket[1].range}h, ${Math.round(peakErrorBucket[1].error_rate * 100)}%)`);
    }
    const topMorning = buckets.morning.top_tools.slice(0, 2).join('/');
    const topAfternoon = buckets.afternoon.top_tools.slice(0, 2).join('/');
    if (topMorning) insights.push(`Mañanas (${buckets.morning.range}h): top tools ${topMorning}`);
    if (topAfternoon) insights.push(`Tardes (${buckets.afternoon.range}h): top tools ${topAfternoon}`);

    const output = {
      updated: TODAY,
      by_hour: merged,
      summary,
      buckets,
      insights,
    };

    const tmp = PRODUCTIVITY_PATH + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(output, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, PRODUCTIVITY_PATH);
  } catch (_) {}

  return [];
}

// -------------------------------------------------------------------
// Step 3h: Detect Cortex command usage and write timeline
// -------------------------------------------------------------------

function detectCommandUsage(observations) {
  // Find Skill tool uses that match cx-* patterns
  const cxPattern = /\bcx-\w+/;
  const commands = [];

  const collect = (obs) => {
    if (obs.tool !== 'Skill') return;
    const input = typeof obs.input === 'string' ? obs.input : JSON.stringify(obs.input || '');
    const match = input.match(cxPattern);
    if (match) {
      commands.push({
        ts: obs.ts,
        cmd: match[0],
        pid: obs.pid || 'global',
      });
    }
  };

  for (const obs of observations) collect(obs);

  // v3.35.2 (#56 audit): cx-* commands are usually invoked from a cwd with no
  // resolvable project, so observe.py routes them to the GLOBAL stream
  // (~/.claude/cortex/observations.jsonl, pid=global) — which the learner
  // never loads (it only reads projects/*/observations.jsonl). The timeline
  // silently stopped growing once usage shifted to project-less sessions.
  // Scan the global stream here with a ts cursor so each Stop only processes
  // new lines (idempotent; a concurrent-Stop race can at worst duplicate one
  // informational timeline line).
  const cursorPath = path.join(CORTEX_DIR, '.timeline-cursor');
  let cursor = '';
  try { cursor = fs.readFileSync(cursorPath, 'utf8').trim(); } catch (_) {}
  let maxTs = cursor;
  try {
    const rootObsPath = path.join(CORTEX_DIR, 'observations.jsonl');
    if (fs.existsSync(rootObsPath)) {
      for (const obs of readJsonlFile(rootObsPath)) {
        const ts = obs.ts || '';
        if (!ts || ts <= cursor) continue;
        if (ts > maxTs) maxTs = ts;
        collect(obs);
      }
      if (maxTs !== cursor) {
        try { fs.writeFileSync(cursorPath, maxTs + '\n', { mode: 0o600 }); } catch (_) {}
      }
    }
  } catch (_) { /* global stream scan is best-effort */ }

  if (commands.length === 0) return;

  // Append to timeline.jsonl
  try {
    fs.mkdirSync(LOG_DIR, { recursive: true });
    const lines = commands.map((c) => JSON.stringify(c)).join('\n') + '\n';
    fs.appendFileSync(TIMELINE_PATH, lines);
    try { fs.chmodSync(TIMELINE_PATH, 0o600); } catch {}  // #47 — operator-only log
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
  // v3.29.3: read instinct-tracking.json ONCE before the loop, mutate in
  // memory, write ONCE at the end. Previously each _mirrorToTracking call
  // did a full read-modify-write — N updated instincts = 2N atomic ops,
  // and two concurrent Stop hooks could lose writes (no lock).
  let tracking = null;
  let trackingDirty = false;
  const loadTrackingLazy = () => {
    if (tracking !== null) return tracking;
    try { tracking = JSON.parse(fs.readFileSync(TRACKING_FILE_PATH, 'utf8')); } catch { tracking = {}; }
    if (!tracking || typeof tracking !== 'object') tracking = {};
    return tracking;
  };

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
      let matchedSessionId = '';
      for (const o of observations) {
        const toolName = o.tool || '';
        if (!toolName) continue;
        const inputStr = String(o.input || '');
        const matchTarget = toolName + ' ' + inputStr;
        if (triggerRegex.test(matchTarget)) {
          matched = true;
          matchedSessionId = o._resolvedSession || o.sid || '';
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
        _mirrorToTrackingMem(loadTrackingLazy(), parsed.fields.id, TODAY, currentOccurrences + 1, matchedSessionId);
        trackingDirty = true;
      }
    } catch (e) {
      log(`Failed to update instinct ${yamlPath}: ${e.message}`);
    }
  }

  // v3.29.3: flush tracking once after the loop (was N writes inside).
  if (trackingDirty && tracking) {
    _flushTracking(tracking);
  }

  if (updated > 0) {
    log(`Updated ${updated} instinct(s)`);
  }
}

const TRACKING_FILE_PATH = path.join(CORTEX_DIR, 'instinct-tracking.json');

function _mirrorToTrackingMem(tracking, instinctId, isoDate, count, sessionId) {
  if (!instinctId || !tracking) return;
  const entry = tracking[instinctId] || {
    count: 0,
    sessions: [],
    projects_seen: [],
    first_seen: isoDate,
  };
  // Never regress the count (injector may have higher value from live PreToolUse)
  if (count > (entry.count || 0)) entry.count = count;
  const sid = String(sessionId || '').trim();
  if (sid && sid.toLowerCase() !== 'unknown' && !entry.sessions.includes(sid)) {
    entry.sessions.push(sid);
    if (entry.sessions.length > 20) {
      entry.sessions = entry.sessions.slice(-20);
    }
  }
  entry.last_seen = new Date().toISOString();
  if (!entry.first_seen) entry.first_seen = entry.last_seen;
  tracking[instinctId] = entry;
}

function _flushTracking(tracking) {
  // Issue #49 — take the shared cross-runtime lock so /cx-backfill --apply
  // (which atomically rewrites instinct-tracking.json) cannot overwrite this
  // flush. Same lockfile as proposals-history.jsonl; both files belong to the
  // same Stop-hook critical section.
  // AD P0-2 fix: if we cannot acquire the lock, SKIP the flush (do not
  // write without it). Tracking is a snapshot, so the next Stop hook will
  // simply re-flush; no data is lost.
  const token = fileLock.acquire(HISTORY_LOCK_PATH, { timeoutMs: 12000, staleMs: 30000 });
  if (token === null) {
    process.stderr.write(
      '[cortex:learner] tracking lock unavailable after 12s; ' +
      'skipping flush — next Stop will re-emit the same snapshot\n'
    );
    return;
  }
  const tmp = TRACKING_FILE_PATH + '.tmp.' + process.pid;
  try {
    fs.writeFileSync(tmp, JSON.stringify(tracking, null, 2), { mode: 0o600 });
    try {
      fs.renameSync(tmp, TRACKING_FILE_PATH);
    } catch (e) {
      // Cleanup the .tmp.PID so a failed rename does not leak it. P2 of #49.
      try { fs.unlinkSync(tmp); } catch (_) {}
      throw e;
    }
  } catch (e) {
    if (process.env.CORTEX_DEBUG) process.stderr.write('[cortex:learner] tracking flush: ' + e.message + '\n');
  } finally {
    fileLock.release(token);
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
  // v3.36.1 (audit P1-empty-action-field): quality gate — a truncated or
  // hollow action ("... try: " with nothing after, or under 40 chars) is
  // data corruption, not knowledge; it can never inject anything useful.
  // Reject before persisting so proposals.json stops accumulating them.
  const rejected = newProposals.filter(
    (p) => String(p.action || '').trim().length < 40 || /try:\s*$/.test(String(p.action || '').trim())
  );
  if (rejected.length > 0) {
    log(`Quality gate rejected ${rejected.length} hollow proposal(s): ${rejected.map((p) => p.id).join(', ')}`);
    newProposals = newProposals.filter((p) => !rejected.includes(p));
  }
  if (newProposals.length === 0) return;

  // v3.29.5 §F5 — one-shot migration: split historical accepted+rejected
  // entries to proposals-history.jsonl so proposals.json only carries the
  // live working set (pending + held) going forward. Idempotent — guarded
  // by a flag file inside the module.
  try {
    const r = migrateAcceptedRejectedToHistory();
    if (!r.alreadyDone && r.migrated > 0) {
      log(`v3.29.5 §F5: migrated ${r.migrated} terminal proposals to history.jsonl, ${r.kept} live retained`);
    }
  } catch (e) {
    log(`v3.29.5 §F5 migration warning: ${e.message}`);
  }

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

  // v3.29.5 §F5 — route terminal-state proposals (accepted, rejected) to
  // history.jsonl and persist only pending + held to proposals.json.
  const live = splitForPersist(deduped);

  writeJsonFile(PROPOSALS_PATH, live);
  log(`Wrote ${newProposals.length} new proposal(s), ${live.length} live in proposals.json (${deduped.length - live.length} archived to history)`);
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

    // v3.36.1 (audit counter-drift): total_projects was never updated here —
    // memory.json said 11 while registry.json had 31. Count project dirs.
    let projCount = 0;
    try {
      projCount = fs.readdirSync(projDir, { withFileTypes: true }).filter((e) => e.isDirectory()).length;
    } catch (_) {}

    mem.stats.total_observations = obsCount;
    mem.stats.total_instincts = globalInst + projInst;
    mem.stats.total_laws = lawCount;
    if (projCount > 0) mem.stats.total_projects = projCount;
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
// v3.31.0 — Sinapsis-style narrative format:
//   - Spanish, ≤ 500 bytes, basenames (max 6, deduped)
//   - Errors emit a CTA to /cx-analyze instead of "Errors: 0"
//   - Replaces the v3.30 telemetry blob (Tools used: Bash 7799...)
// -------------------------------------------------------------------

// Cross-platform basename: handles both POSIX (/) and Windows (\)
function pathBasename(p) {
  return String(p || '').split(/[\\/]/).pop() || '';
}

function writeContextFile(observations) {
  if (observations.length === 0) return;

  const projectId = observations[0]._projectId || 'global';
  const projectDir = path.join(PROJECTS_DIR, projectId);

  let projectName = projectId;
  const registry = readJsonFile(REGISTRY_PATH);
  if (registry && registry[projectId]) {
    projectName = registry[projectId].name || projectId;
  }

  // Files touched: basenames, dedup, max 6 (Sinapsis-style)
  const filesBasenames = [...new Set(
    observations
      .filter((o) => o.tool === 'Edit' || o.tool === 'Write')
      .map((o) => {
        try {
          const inp = JSON.parse(o.input || '{}');
          return inp.file_path ? pathBasename(inp.file_path) : null;
        } catch {
          return null;
        }
      })
      .filter(Boolean)
  )].slice(0, 6);

  const errorCount = observations.filter((o) => isError(o)).length;

  const lines = [
    `## Proyecto: ${projectName}`,
    `Última sesión: ${TODAY}`,
    `Observaciones totales: ${observations.length}`,
    filesBasenames.length > 0
      ? `Archivos activos: ${filesBasenames.join(', ')}`
      : null,
    errorCount > 0
      ? `Posibles gotchas detectados: ${errorCount} — ejecuta /cx-analyze`
      : null,
  ].filter(Boolean);
  const content = lines.join('\n') + '\n';

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
  // v3.29.4: gate the user-defined error_pattern through the shared ReDoS
  // guard before compiling, matching the protection already in place at
  // session-learner.js:912 and :921. Without this, a malformed instinct
  // trigger could hang the Stop hook on impact-funnel evaluation.
  if (!isSafeRegex(ev.error_pattern)) return 'ignore';
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
          } catch (e) {
            // v3.29.4: surface the failure under CORTEX_DEBUG so silent
            // disk-full / EACCES on the knowledge log is visible to operators.
            // Plain append is intentional — concurrent Stop hooks tolerate
            // interleaved single-line writes; tmp+rename without a lock would
            // drop concurrent updates.
            if (process.env.CORTEX_DEBUG) {
              try { process.stderr.write(`[cortex:learner] knowledge-log append failed: ${e.message}\n`); } catch {}
            }
          }
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

    // v3.29.0 (Sprint 8 Día 2): all proposal-emitting detectors are now
    // reactivated as HUMAN-gated emitters after the §4.2-§4.5 rewrites.
    // CORTEX_LEGACY_DETECTORS env var (used in v3.28.9 to gate them while
    // they were structurally broken) is retired in the same change.
    //
    // CORTEX_DETECTORS_OFF=1 (§4.8 kill switch) short-circuits every
    // proposal-emitting detector to []. The side-effecting detectors
    // (detectTimeOfDayPatterns → productivity-patterns.json, detectCommandUsage
    // → timeline.jsonl) and the downstream pipeline (updateInstincts,
    // updateReflexes, impact correlation, outcome nudge) keep running so the
    // kill switch is scoped to "stop generating proposals" only — essential
    // tracking data is preserved.
    const detectorsOff = process.env.CORTEX_DETECTORS_OFF === '1';

    // v3.34.1: `correction` + `file-coupling` have a lifetime ~0% accept rate
    // (pure backlog noise). Gate them selectively via memory.json
    // config.noisy_detectors_off (opt-in, default false) or env override —
    // WITHOUT touching error-fix / agent detectors, which carry real signal.
    let noisyOff = process.env.CORTEX_NOISY_DETECTORS_OFF === '1';
    try {
      const _cfg = JSON.parse(fs.readFileSync(path.join(CORTEX_DIR, 'memory.json'), 'utf8')).config || {};
      if (_cfg.noisy_detectors_off === true) noisyOff = true;
    } catch { /* missing/unreadable config → leave default */ }

    // Step 2: Detect error-fix pairs (KEEP — only detector with valid trigger,
    // actionable action, and whitelisted domain)
    const errorProposals = detectorsOff ? [] : detectErrorResolutions(observations);
    log(`Detected ${errorProposals.length} error-fix pair(s)`);

    // Step 3b: Detect user corrections (v3.29.0 §4.3 HUMAN-gated rewrite —
    // domain `correction`, conf 0.55, imperative action, scope `project`)
    const correctionProposals = (detectorsOff || noisyOff) ? [] : detectUserCorrections(observations);
    log(`Detected ${correctionProposals.length} user correction(s)`);

    // Step 3d: Detect agent patterns (v3.29.0 §4.5 — min items 3 → 4)
    const agentProposals = detectorsOff ? [] : detectAgentPatterns(observations);
    log(`Detected ${agentProposals.length} agent pattern(s)`);

    // Step 3e: Detect agent subtypes (v3.29.0 §4.4 HUMAN-gated rewrite —
    // domain `agent-quality`, conf 0.50, imperative action)
    const resolvedSessionId = observations[0]._resolvedSession || observations[0].sid || '';
    const agentSubtypeProposals = detectorsOff ? [] : detectAgentSubtypes(observations, resolvedSessionId);
    log(`Detected ${agentSubtypeProposals.length} agent subtype issue(s)`);

    // Step 3f: Detect file coupling (v3.29.0 §4.2 HUMAN-gated rewrite —
    // domain `coupling`, conf 0.55, regex trigger, scope `project`)
    const couplingProposals = (detectorsOff || noisyOff) ? [] : detectFileCoupling(observations, resolvedSessionId);
    log(`Detected ${couplingProposals.length} file coupling pattern(s)`);

    // Step 3g: Detect time-of-day patterns (v3.27.0, side-effect to
    // productivity-patterns.json — NOT gated by CORTEX_DETECTORS_OFF, the
    // kill switch is scoped to proposals only per §4.8)
    detectTimeOfDayPatterns(observations);

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

    // Step 5f: Storage rotation (issue #56.2, v3.35.1) — impact.jsonl and
    // cross-day-tracker.jsonl had rotation code that was never called from
    // anywhere. Size-gated + 24h marker; impact events are archived to
    // impact.archive/, never deleted.
    try {
      const { maybeRotateStorage } = require(path.join(__dirname, 'lib', 'storage-rotation'));
      maybeRotateStorage(log);
    } catch (e) {
      log(`Storage rotation failed: ${e.message}`);
    }

    // Step 6: Combine all proposals with session_date for cross-day tracking
    // (v3.29.0 §4.6: repetitionProposals + workflowProposals lists removed
    // along with their source detectors.)
    const rawProposals = [
      ...errorProposals,
      ...correctionProposals,
      ...agentProposals,
      ...agentSubtypeProposals,   // v3.27.0
      ...couplingProposals,        // v3.27.0
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
    summarizeFixInput, writeProposals, // v3.36.1 — quality-gate testability
    detectErrorResolutions,
    // v3.29.0 §4.6: detectRepetitions and detectWorkflowChains retired.
    detectUserCorrections, detectAgentPatterns,
    detectAgentSubtypes, detectFileCoupling, detectTimeOfDayPatterns, // v3.27.0
    detectCommandUsage, dedupProposalsByIncident,
    // v3.14.0 — impact funnel correlator (orphan-sid fix v3.19.1)
    correlateImpactEvents,
    // v3.18.0 — reflex auto-evaluation
    evalToolSubstitution, evalPreconditionCheck, evalErrorMonitor,
    evaluateReflex, correlateReflexFeedback,
  };
}
