'use strict';
// storage-rotation.js — issue #56.2: the two unbounded global JSONL files
// (impact.jsonl, cross-day-tracker.jsonl) had rotation/prune code that was
// never wired to any caller, so they grew without limit (impact.jsonl hit
// 80MB). session-learner.js calls maybeRotateStorage() at Stop (Step 5f).
//
// Guarantees:
//   - impact.jsonl is ARCHIVED (impact_log.py rotate → impact.archive/),
//     never deleted.
//   - cross-day-tracker.jsonl is pruned by its own prune() (keeps 365 days
//     + compacts same-day duplicates — both shipped semantics since v3.28.4).
//   - Size-gated: nothing runs while the files stay small.
//   - Marker-gated: at most one pass per 24h, so a steady-state file larger
//     than the threshold does not trigger a full rewrite on every Stop.
//   - The impact rotation spawns python3 DETACHED by default: the Stop hook
//     has a 15s budget and the first rotation of a multi-MB file can exceed
//     it. Tests set CORTEX_ROTATE_SYNC=1 for deterministic behavior.

const fs = require('fs');
const path = require('path');

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';
const CORTEX_DIR = process.env.CORTEX_DIR || path.join(HOME, '.claude', 'cortex');

// Env-overridable for tests and operator tuning.
const IMPACT_ROTATE_MB = parseFloat(process.env.CORTEX_IMPACT_ROTATE_MB || '10');
const TRACKER_PRUNE_MB = parseFloat(process.env.CORTEX_TRACKER_PRUNE_MB || '1');
// v3.36.0 (audit 2026-06-10) — four more unbounded artifacts gained caps:
// proposals-history.jsonl (append-only, rename-rotated under its writer
// lock), knowledge-log.md (rename-rotated), daily-snapshots/ +
// daily-summaries/ (keep newest N files), .fire-once/ markers (age-pruned).
const HISTORY_ROTATE_MB = parseFloat(process.env.CORTEX_HISTORY_ROTATE_MB || '3');
const KNOWLEDGE_ROTATE_MB = parseFloat(process.env.CORTEX_KNOWLEDGE_ROTATE_MB || '2');
const DAILY_KEEP_FILES = parseInt(process.env.CORTEX_DAILY_KEEP_FILES || '60', 10);
const FIREONCE_MAX_DAYS = parseInt(process.env.CORTEX_FIREONCE_MAX_DAYS || '30', 10);
const MARKER_NAME = '.last-storage-rotate';
const DAY_MS = 24 * 3600 * 1000;

function fileMb(p) {
  try { return fs.statSync(p).size / 1048576; } catch (_) { return 0; }
}

function _stamp() {
  return new Date().toISOString().slice(0, 19).replace(/[:T]/g, '').replace(/-/g, '');
}

// Rename-rotate an append-only file into `archiveDir` once it crosses
// `maxMb`. Appenders recreate the live file on next write; readers that
// want history can opt-in to scanning the archive dir.
function _renameRotate(file, archiveDir, maxMb) {
  const mb = fileMb(file);
  if (mb < maxMb) return null;
  fs.mkdirSync(archiveDir, { recursive: true, mode: 0o700 });
  const base = path.basename(file);
  const dest = path.join(archiveDir, `${base}.${_stamp()}-${process.pid}`);
  fs.renameSync(file, dest);
  return { rotated: base, sizeMb: +mb.toFixed(1), dest };
}

// proposals-history.jsonl is appended under .proposals-history.lock by both
// runtimes (proposals-storage.js, distill_engine.py). Take the SAME lock for
// the rename so no appender writes into a half-moved file.
function _rotateProposalsHistory(log) {
  const file = path.join(CORTEX_DIR, 'proposals-history.jsonl');
  if (fileMb(file) < HISTORY_ROTATE_MB) return;
  let fileLock;
  try { fileLock = require(path.join(__dirname, 'file-lock')); } catch (_) { return; }
  const token = fileLock.acquire(path.join(CORTEX_DIR, '.proposals-history.lock'), { timeoutMs: 2000 });
  if (!token) { log('Storage rotation: proposals-history lock busy — skipped'); return; }
  try {
    const r = _renameRotate(file, path.join(CORTEX_DIR, 'proposals.archive'), HISTORY_ROTATE_MB);
    if (r) log(`Storage rotation: proposals-history.jsonl ${r.sizeMb}MB → proposals.archive/`);
  } finally {
    fileLock.release(token);
  }
}

// Keep the newest `keep` files in a directory, delete the rest (derived,
// regenerable artifacts only — snapshots and summaries).
function _pruneDirByCount(dir, keep, log, label) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isFile() && !e.name.startsWith('.'))
      .map((e) => {
        const full = path.join(dir, e.name);
        return { full, mtime: fs.statSync(full).mtimeMs };
      });
  } catch (_) { return; }
  if (entries.length <= keep) return;
  entries.sort((a, b) => b.mtime - a.mtime);
  const doomed = entries.slice(keep);
  for (const d of doomed) {
    try { fs.unlinkSync(d.full); } catch (_) {}
  }
  log(`Storage rotation: ${label} pruned ${doomed.length} file(s) (keep newest ${keep})`);
}

function _pruneFireOnceMarkers(log) {
  const dir = path.join(CORTEX_DIR, '.fire-once');
  let removed = 0;
  let entries;
  try { entries = fs.readdirSync(dir); } catch (_) { return; }
  const cutoff = Date.now() - FIREONCE_MAX_DAYS * DAY_MS;
  for (const name of entries) {
    const full = path.join(dir, name);
    try {
      if (fs.statSync(full).mtimeMs < cutoff) { fs.unlinkSync(full); removed++; }
    } catch (_) {}
  }
  if (removed > 0) log(`Storage rotation: .fire-once pruned ${removed} marker(s) older than ${FIREONCE_MAX_DAYS}d`);
}

function maybeRotateStorage(log) {
  log = log || (() => {});
  const marker = path.join(CORTEX_DIR, MARKER_NAME);
  try {
    if (Date.now() - fs.statSync(marker).mtimeMs < DAY_MS) {
      return { ran: false };
    }
  } catch (_) { /* no marker yet — proceed */ }

  const result = { ran: true, impact: null, tracker: null };

  // impact.jsonl → impact.archive/ via `impact_log.py rotate` (>30d, archived)
  const impactMb = fileMb(path.join(CORTEX_DIR, 'impact.jsonl'));
  if (impactMb >= IMPACT_ROTATE_MB) {
    try {
      const impactPy = path.join(__dirname, 'impact_log.py');
      if (fs.existsSync(impactPy)) {
        const cp = require('child_process');
        if (process.env.CORTEX_ROTATE_SYNC === '1') {
          const r = cp.spawnSync('python3', [impactPy, 'rotate'],
            { encoding: 'utf8', timeout: 60000, env: process.env });
          result.impact = r.status === 0 ? (r.stdout || '').trim() : `failed (status ${r.status})`;
        } else {
          const child = cp.spawn('python3', [impactPy, 'rotate'],
            { detached: true, stdio: 'ignore', env: process.env });
          child.on('error', () => {});
          child.unref();
          result.impact = 'spawned detached';
        }
        log(`Storage rotation: impact.jsonl ${impactMb.toFixed(1)}MB — ${result.impact}`);
      }
    } catch (e) {
      log(`Storage rotation: impact rotate error: ${e.message}`);
    }
  }

  // cross-day-tracker.jsonl — prune >365d + same-day duplicate compaction
  try {
    const tracker = require(path.join(__dirname, 'cross-day-tracker'));
    if (fileMb(tracker.TRACKER_PATH) >= TRACKER_PRUNE_MB) {
      const res = tracker.prune();
      result.tracker = res;
      log(`Storage rotation: cross-day-tracker ${res.before} → ${res.after} entries (${res.pruned} pruned)`);
    }
  } catch (e) {
    log(`Storage rotation: tracker prune error: ${e.message}`);
  }

  // v3.36.0 — remaining unbounded artifacts (audit 2026-06-10). Each block
  // is independent: a failure in one never blocks the others.
  try { _rotateProposalsHistory(log); } catch (e) {
    log(`Storage rotation: proposals-history error: ${e.message}`);
  }
  try {
    const r = _renameRotate(
      path.join(CORTEX_DIR, 'knowledge-log.md'),
      path.join(CORTEX_DIR, 'knowledge-log.archive'),
      KNOWLEDGE_ROTATE_MB
    );
    if (r) log(`Storage rotation: knowledge-log.md ${r.sizeMb}MB → knowledge-log.archive/`);
  } catch (e) {
    log(`Storage rotation: knowledge-log error: ${e.message}`);
  }
  try {
    _pruneDirByCount(path.join(CORTEX_DIR, 'daily-snapshots'), DAILY_KEEP_FILES, log, 'daily-snapshots');
    _pruneDirByCount(path.join(CORTEX_DIR, 'daily-summaries'), DAILY_KEEP_FILES, log, 'daily-summaries');
  } catch (e) {
    log(`Storage rotation: daily prune error: ${e.message}`);
  }
  try { _pruneFireOnceMarkers(log); } catch (e) {
    log(`Storage rotation: fire-once prune error: ${e.message}`);
  }

  try { fs.writeFileSync(marker, new Date().toISOString() + '\n', { mode: 0o600 }); } catch (_) {}
  return result;
}

module.exports = {
  maybeRotateStorage, IMPACT_ROTATE_MB, TRACKER_PRUNE_MB, MARKER_NAME,
  HISTORY_ROTATE_MB, KNOWLEDGE_ROTATE_MB, DAILY_KEEP_FILES, FIREONCE_MAX_DAYS,
};
