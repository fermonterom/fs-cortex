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
const MARKER_NAME = '.last-storage-rotate';
const DAY_MS = 24 * 3600 * 1000;

function fileMb(p) {
  try { return fs.statSync(p).size / 1048576; } catch (_) { return 0; }
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

  try { fs.writeFileSync(marker, new Date().toISOString() + '\n', { mode: 0o600 }); } catch (_) {}
  return result;
}

module.exports = { maybeRotateStorage, IMPACT_ROTATE_MB, TRACKER_PRUNE_MB, MARKER_NAME };
