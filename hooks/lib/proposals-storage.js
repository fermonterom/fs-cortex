'use strict';

// v3.29.5 §F5 — proposals.json archive split.
//
// Pre-v3.29.5 proposals.json held every proposal ever created (pending +
// accepted + rejected + held), grew monotonically — the user's file had
// 1,206 entries spanning months. Every Stop hook re-read and re-wrote the
// full array. CHANGELOG-side effect: rotating .bak-* files at ~660 KB each.
//
// This module migrates terminal-state proposals (accepted + rejected) to an
// append-only proposals-history.jsonl while leaving proposals.json with only
// live entries (pending + held). One-shot migration is idempotent via a
// .migrated-to-history.jsonl flag file. Subsequent writes (handled by
// session-learner.js::writeProposals) split new accepts/rejects to history
// in real time.
//
// History format: one JSON object per line, preserving the entire proposal
// payload (status, accepted_at/rejected_at/by/reason, original detection
// metadata). Append-only — never rewritten. /cx-validate / /cx-audit /
// /cx-retro can opt-in to scanning it for historical reporting.

const fs = require('fs');
const path = require('path');

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';
const CORTEX_DIR = process.env.CORTEX_DIR || path.join(HOME, '.claude', 'cortex');
const PROPOSALS_PATH = path.join(CORTEX_DIR, 'proposals.json');
const HISTORY_PATH = path.join(CORTEX_DIR, 'proposals-history.jsonl');
const MIGRATE_FLAG_PATH = path.join(CORTEX_DIR, '.migrated-to-history.jsonl');

// Terminal statuses get archived. Pending/held stay live.
const LIVE_STATUSES = new Set(['pending', 'held']);

function _readProposals() {
  if (!fs.existsSync(PROPOSALS_PATH)) return [];
  try {
    const txt = fs.readFileSync(PROPOSALS_PATH, 'utf8');
    if (!txt.trim()) return [];
    const data = JSON.parse(txt);
    return Array.isArray(data) ? data : [];
  } catch (_) {
    return [];
  }
}

function _atomicWriteJson(filepath, data) {
  const tmp = filepath + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, filepath);
}

function _appendHistory(proposals) {
  if (proposals.length === 0) return;
  const dir = path.dirname(HISTORY_PATH);
  try { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); } catch (_) {}
  const lines = proposals.map(p => JSON.stringify(p)).join('\n') + '\n';
  fs.appendFileSync(HISTORY_PATH, lines, { mode: 0o600 });
}

// One-shot migration: split existing terminal proposals to history.
// Returns {migrated, kept, alreadyDone}.
function migrateAcceptedRejectedToHistory() {
  if (fs.existsSync(MIGRATE_FLAG_PATH)) {
    return { migrated: 0, kept: _readProposals().length, alreadyDone: true };
  }
  const all = _readProposals();
  const terminal = all.filter(p =>
    p && typeof p === 'object' && !LIVE_STATUSES.has(p.status)
  );
  const live = all.filter(p =>
    p && typeof p === 'object' && LIVE_STATUSES.has(p.status)
  );

  if (terminal.length > 0) {
    _appendHistory(terminal);
  }
  _atomicWriteJson(PROPOSALS_PATH, live);

  // Idempotency flag — file mtime is the migration timestamp.
  fs.writeFileSync(MIGRATE_FLAG_PATH, new Date().toISOString() + '\n', { mode: 0o600 });

  return { migrated: terminal.length, kept: live.length, alreadyDone: false };
}

// Per-Stop archive: takes a "deduped" proposal list (pending + held + just-
// transitioned accepts/rejects), routes terminal-state ones to history and
// returns the live-only subset that should be persisted to proposals.json.
function splitForPersist(deduped) {
  const live = [];
  const terminal = [];
  for (const p of deduped) {
    if (!p || typeof p !== 'object') continue;
    if (LIVE_STATUSES.has(p.status)) {
      live.push(p);
    } else {
      terminal.push(p);
    }
  }
  if (terminal.length > 0) _appendHistory(terminal);
  return live;
}

module.exports = {
  migrateAcceptedRejectedToHistory,
  splitForPersist,
  PROPOSALS_PATH,
  HISTORY_PATH,
  MIGRATE_FLAG_PATH,
  LIVE_STATUSES,
};
