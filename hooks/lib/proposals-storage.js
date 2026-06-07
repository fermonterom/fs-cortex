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
const fileLock = require('./file-lock');

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';
const CORTEX_DIR = process.env.CORTEX_DIR || path.join(HOME, '.claude', 'cortex');
const PROPOSALS_PATH = path.join(CORTEX_DIR, 'proposals.json');
const HISTORY_PATH = path.join(CORTEX_DIR, 'proposals-history.jsonl');
const MIGRATE_FLAG_PATH = path.join(CORTEX_DIR, '.migrated-to-history.jsonl');
// Issue #49 — shared cross-runtime lock for proposals-history.jsonl and
// instinct-tracking.json. The Python backfill (distill_engine.py) takes the
// SAME lockfile via O_EXCL; coordination is at the filesystem level.
const HISTORY_LOCK_PATH = path.join(CORTEX_DIR, '.proposals-history.lock');

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
  if (proposals.length === 0) return true;
  const dir = path.dirname(HISTORY_PATH);
  try { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); } catch (_) {}
  const lines = proposals.map(p => JSON.stringify(p)).join('\n') + '\n';
  // Issue #49 — take the shared cross-runtime lock so a concurrent
  // /cx-backfill --apply (which atomically rewrites this file) cannot lose
  // these appends. AD P0-2 fix: if we cannot acquire the lock, we DO NOT
  // append without it (that reintroduces the original TOCTOU). Return
  // false so the caller can keep these proposals in proposals.json and
  // retry on the next Stop. 12 s timeout fits inside the Stop hook's 15 s
  // wall clock and is well above stale_ms so a genuinely orphaned lock
  // will be detected and stolen rather than blocking us indefinitely.
  const token = fileLock.acquire(HISTORY_LOCK_PATH, { timeoutMs: 12000, staleMs: 30000 });
  if (token === null) {
    process.stderr.write(
      '[cortex:proposals-storage] history lock unavailable after 12s; ' +
      `keeping ${proposals.length} terminal proposal(s) in proposals.json — ` +
      'will be re-attempted next Stop\n'
    );
    return false;
  }
  try {
    fs.appendFileSync(HISTORY_PATH, lines, { mode: 0o600 });
  } finally {
    fileLock.release(token);
  }
  return true;
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

  let appended = true;
  if (terminal.length > 0) {
    appended = _appendHistory(terminal);
  }
  // AD P0-2: if the append was skipped (lock unavailable), keep the
  // terminal entries in proposals.json instead of dropping them silently
  // and do NOT mark the migration as done — we will retry next Stop.
  if (!appended) {
    _atomicWriteJson(PROPOSALS_PATH, [...live, ...terminal]);
    return { migrated: 0, kept: live.length + terminal.length, alreadyDone: false, deferred: true };
  }
  _atomicWriteJson(PROPOSALS_PATH, live);

  // Idempotency flag — file mtime is the migration timestamp.
  fs.writeFileSync(MIGRATE_FLAG_PATH, new Date().toISOString() + '\n', { mode: 0o600 });

  return { migrated: terminal.length, kept: live.length, alreadyDone: false };
}

// Per-Stop archive: takes a "deduped" proposal list (pending + held + just-
// transitioned accepts/rejects), routes terminal-state ones to history and
// returns the live-only subset that should be persisted to proposals.json.
// AD P0-2: if _appendHistory could not acquire the lock, keep the
// terminal entries in the returned set so the caller persists them back to
// proposals.json — they will be re-attempted on the next Stop hook rather
// than dropped.
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
  if (terminal.length === 0) return live;
  const appended = _appendHistory(terminal);
  if (!appended) return [...live, ...terminal];
  return live;
}

module.exports = {
  migrateAcceptedRejectedToHistory,
  splitForPersist,
  PROPOSALS_PATH,
  HISTORY_PATH,
  HISTORY_LOCK_PATH,
  MIGRATE_FLAG_PATH,
  LIVE_STATUSES,
};
