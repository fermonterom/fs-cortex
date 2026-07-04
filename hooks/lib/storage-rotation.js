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
// NaN guard (adversarial review): a non-numeric CORTEX_DAILY_KEEP_FILES
// would make `entries.length <= NaN` false and `slice(NaN)` ≡ slice(0) —
// deleting EVERY snapshot. `|| <default>` maps NaN and the falsy "0" to the
// default; Math.max floors negatives to 1 so the newest file always
// survives.
const DAILY_KEEP_FILES = Math.max(1, parseInt(process.env.CORTEX_DAILY_KEEP_FILES || '60', 10) || 60);
const FIREONCE_MAX_DAYS = Math.max(1, parseInt(process.env.CORTEX_FIREONCE_MAX_DAYS || '30', 10) || 30);
// v3.37.0 (audit 2026-07-04) — impact.archive/ (rotated impact.jsonl chunks)
// and log/timeline.jsonl had no prune path: 105MB archive dir, 5.1MB/79k-line
// timeline observed.
const IMPACT_ARCHIVE_KEEP_FILES = Math.max(1, parseInt(process.env.CORTEX_IMPACT_ARCHIVE_KEEP_FILES || '5', 10) || 5);
const TIMELINE_ROTATE_MB = parseFloat(process.env.CORTEX_TIMELINE_ROTATE_MB || '2');
const TIMELINE_KEEP_LINES = Math.max(1, parseInt(process.env.CORTEX_TIMELINE_KEEP_LINES || '1000', 10) || 1000);
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

// Keep the newest `keep` files in a directory. Snapshots are regenerable
// (derived from live state) and are simply deleted; when `archiveDir` is
// given (AD fix #5, 2026-07-02 — daily-summaries have no regeneration path,
// they're the only record of that day's digest) the pruned files are
// rename-moved there instead of unlinked. `archiveDir` files never come
// back into the scan: readdirSync's isFile() filter already excludes the
// archive subdirectory itself from the candidate list.
function _pruneDirByCount(dir, keep, log, label, archiveDir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isFile() && !e.name.startsWith('.'))
      .map((e) => {
        const full = path.join(dir, e.name);
        return { full, name: e.name, mtime: fs.statSync(full).mtimeMs };
      });
  } catch (_) { return; }
  if (entries.length <= keep) return;
  entries.sort((a, b) => b.mtime - a.mtime);
  const doomed = entries.slice(keep);
  if (archiveDir) {
    try { fs.mkdirSync(archiveDir, { recursive: true, mode: 0o700 }); } catch (_) {}
    for (const d of doomed) {
      try { fs.renameSync(d.full, path.join(archiveDir, d.name)); } catch (_) {}
    }
    log(`Storage rotation: ${label} archived ${doomed.length} file(s) → ${path.basename(archiveDir) === 'archive' ? path.basename(dir) + '/archive/' : archiveDir} (keep newest ${keep})`);
    return;
  }
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

// v3.37.0 (audit 2026-07-04) — stale lock files (writer crashed/killed before
// release) and .bak/.backup snapshots left by ad-hoc edits. Walk CORTEX_DIR
// one level plus known subdirectory groups (projects/*) rather than a full
// recursive scan, matching this file's existing flat-tree assumptions.
const STALE_FILE_MAX_DAYS = 30;

function _walkFilesShallow(dir, depth) {
  let out = [];
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return out; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isFile()) { out.push(full); continue; }
    if (e.isDirectory() && depth > 0) { out = out.concat(_walkFilesShallow(full, depth - 1)); }
  }
  return out;
}

function _pruneStaleLocks(log) {
  const cutoff = Date.now() - STALE_FILE_MAX_DAYS * DAY_MS;
  let removed = 0;
  for (const full of _walkFilesShallow(CORTEX_DIR, 3)) {
    if (!full.endsWith('.lock')) continue;
    try {
      if (fs.statSync(full).mtimeMs < cutoff) { fs.unlinkSync(full); removed++; }
    } catch (_) {}
  }
  if (removed > 0) log(`Storage rotation: stale locks pruned ${removed} .lock file(s) older than ${STALE_FILE_MAX_DAYS}d`);
}

function _pruneBackupFiles(log) {
  const cutoff = Date.now() - STALE_FILE_MAX_DAYS * DAY_MS;
  let removed = 0;
  for (const full of _walkFilesShallow(CORTEX_DIR, 3)) {
    if (!/\.(bak|backup)$/.test(full)) continue;
    try {
      if (fs.statSync(full).mtimeMs < cutoff) { fs.unlinkSync(full); removed++; }
    } catch (_) {}
  }
  if (removed > 0) log(`Storage rotation: .bak/.backup pruned ${removed} file(s) older than ${STALE_FILE_MAX_DAYS}d`);
}

// Keep the last `keepLines` JSONL entries, archiving the rest (rename-rotate
// style: write the trimmed tail to a temp file, rename over the live file,
// archive the original next to it). No dependency on external tools.
function _rotateJsonlKeepLast(file, archiveDir, keepLines, maxMb, log, label) {
  if (fileMb(file) < maxMb) return;
  let lines;
  try { lines = fs.readFileSync(file, 'utf8').split('\n'); } catch (_) { return; }
  if (lines.length && lines[lines.length - 1] === '') lines.pop();
  if (lines.length <= keepLines) return;
  try { fs.mkdirSync(archiveDir, { recursive: true, mode: 0o700 }); } catch (_) {}
  const base = path.basename(file);
  const dest = path.join(archiveDir, `${base}.${_stamp()}-${process.pid}`);
  try {
    fs.renameSync(file, dest);
    const tail = lines.slice(-keepLines).join('\n') + '\n';
    fs.writeFileSync(file, tail, { mode: 0o600 });
    log(`Storage rotation: ${label} kept last ${keepLines} of ${lines.length} lines, rest archived → ${path.basename(archiveDir)}/`);
  } catch (e) {
    log(`Storage rotation: ${label} rotate error: ${e.message}`);
  }
}

function maybeRotateStorage(log) {
  log = log || (() => {});
  const marker = path.join(CORTEX_DIR, MARKER_NAME);
  try {
    const gateAgeMs = Date.now() - fs.statSync(marker).mtimeMs;
    if (gateAgeMs < DAY_MS) {
      // P1-7 (audit 2026-07-04): a file that already blew past its own
      // threshold by 1.5x must not wait out the full 24h gate — sessions
      // spaced >24h apart let it grow unbounded. Early-trigger on size alone.
      const trackerMbNow = (() => {
        try { return fileMb(require(path.join(__dirname, 'cross-day-tracker')).TRACKER_PATH); } catch (_) { return 0; }
      })();
      if (trackerMbNow < TRACKER_PRUNE_MB * 1.5) {
        return { ran: false };
      }
      log(`Storage rotation: gate bypassed — cross-day-tracker.jsonl ${trackerMbNow.toFixed(1)}MB ≥ ${(TRACKER_PRUNE_MB * 1.5).toFixed(1)}MB (1.5x threshold)`);
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
  // impact.archive/ itself is unbounded (each rotate adds a file, never
  // removed) — keep only the newest IMPACT_ARCHIVE_KEEP_FILES.
  try {
    _pruneDirByCount(path.join(CORTEX_DIR, 'impact.archive'), IMPACT_ARCHIVE_KEEP_FILES, log, 'impact.archive');
  } catch (e) {
    log(`Storage rotation: impact.archive prune error: ${e.message}`);
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
    // AD fix #5 — daily-summaries are the only record of that day's digest
    // (no regeneration path, unlike daily-snapshots which mirror live
    // state), so pruning archives them to daily-summaries/archive/ instead
    // of unlinking.
    _pruneDirByCount(
      path.join(CORTEX_DIR, 'daily-summaries'), DAILY_KEEP_FILES, log, 'daily-summaries',
      path.join(CORTEX_DIR, 'daily-summaries', 'archive')
    );
  } catch (e) {
    log(`Storage rotation: daily prune error: ${e.message}`);
  }
  try { _pruneFireOnceMarkers(log); } catch (e) {
    log(`Storage rotation: fire-once prune error: ${e.message}`);
  }
  try { _pruneStaleLocks(log); } catch (e) {
    log(`Storage rotation: stale lock prune error: ${e.message}`);
  }
  try { _pruneBackupFiles(log); } catch (e) {
    log(`Storage rotation: backup prune error: ${e.message}`);
  }
  try {
    _rotateJsonlKeepLast(
      path.join(CORTEX_DIR, 'log', 'timeline.jsonl'),
      path.join(CORTEX_DIR, 'log', 'timeline.archive'),
      TIMELINE_KEEP_LINES, TIMELINE_ROTATE_MB, log, 'log/timeline.jsonl'
    );
  } catch (e) {
    log(`Storage rotation: timeline rotate error: ${e.message}`);
  }

  try { fs.writeFileSync(marker, new Date().toISOString() + '\n', { mode: 0o600 }); } catch (_) {}
  return result;
}

module.exports = {
  maybeRotateStorage, IMPACT_ROTATE_MB, TRACKER_PRUNE_MB, MARKER_NAME,
  HISTORY_ROTATE_MB, KNOWLEDGE_ROTATE_MB, DAILY_KEEP_FILES, FIREONCE_MAX_DAYS,
  IMPACT_ARCHIVE_KEEP_FILES, TIMELINE_ROTATE_MB, TIMELINE_KEEP_LINES,
};
