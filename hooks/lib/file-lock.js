'use strict';

// file-lock.js — cross-runtime advisory lock paired with hooks/lib/file_lock.py.
// See docs/ISSUE-49-PLAN.md for the full design.
//
// Mechanism: lockfile via fs.openSync(path, 'wx'). The Python side uses
// os.open(O_CREAT|O_EXCL|O_WRONLY) — same semantics. Coordination happens at
// the filesystem level, so the two runtimes serialize correctly without any
// native dependency.
//
// Stale detection: lockfile mtime older than `staleMs` AND the recorded PID
// not alive → reclaim. Both conditions required (recycled PIDs must not
// trigger a steal of a live lock).
//
// Synchronous sleep uses Atomics.wait on a SharedArrayBuffer — standard since
// Node 11. No busy-spin, no dependency.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

// AD P0-1 fix: per-lock nonce so release() only unlinks a lockfile we still
// own. Without this, a process resumed after a long pause (event-loop block,
// GC) could unlink a lock that a stale-stealer already reclaimed — leading
// to two co-owners.
const _ownedNonces = new Map();

const _sleepBuf = new Int32Array(new SharedArrayBuffer(4));
function _sleepSync(ms) {
  if (ms <= 0) return;
  try { Atomics.wait(_sleepBuf, 0, 0, ms); } catch (_) {
    // Fallback for environments without Atomics.wait (very old Node).
    const end = Date.now() + ms;
    while (Date.now() < end) { /* spin */ }
  }
}

function _pidAlive(pid) {
  if (!pid || pid < 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    if (e && e.code === 'EPERM') return true;
    return false;
  }
}

function _readPayload(lockPath) {
  try {
    const raw = fs.readFileSync(lockPath, 'utf8');
    if (!raw || !raw.trim()) return {};
    return JSON.parse(raw);
  } catch (_) {
    return {};
  }
}


function _isStale(lockPath, staleMs) {
  let st;
  try {
    st = fs.statSync(lockPath);
  } catch (e) {
    return false; // ENOENT or unreadable → not "a stale lock to break"
  }
  if (Date.now() - st.mtimeMs <= staleMs) return false;
  const payload = _readPayload(lockPath);
  const pid = Number(payload && payload.pid) || 0;
  if (pid && _pidAlive(pid)) return false;
  return true;
}

function _pathExists(p) {
  try { fs.statSync(p); return true; } catch (_) { return false; }
}

function _tryStealIfStale(lockPath, staleMs) {
  // AD round 4 fix — the janitor must NOT break itself by age. Two processes
  // could concurrently decide a stale janitor is old, both unlink it, both
  // create a fresh one, and one would steal a valid lock. On EEXIST we return
  // false immediately — no stat, no unlink of the existing janitor.
  // Orphaned janitors (crash between open and finally-unlink) are left in place
  // and block reclaim until manually removed or the lock dir is cleaned.
  if (!_isStale(lockPath, staleMs)) {
    return !_pathExists(lockPath); // gone already → free to create
  }
  const janitor = lockPath + '.janitor';
  let jfd;
  try {
    jfd = fs.openSync(janitor, 'wx', 0o600);
  } catch (e) {
    if (e && e.code === 'EEXIST') {
      // Another reclaimer holds the janitor — do not break it (meta-TOCTOU).
      return false;
    }
    return false;
  }
  try {
    // Re-verify staleness UNDER the janitor. If a fresh lock now exists,
    // _isStale is false → we must not remove it.
    if (!_isStale(lockPath, staleMs)) {
      return !_pathExists(lockPath);
    }
    try { fs.unlinkSync(lockPath); } catch (e) {
      if (!(e && e.code === 'ENOENT')) return false;
    }
    return true;
  } finally {
    try { fs.closeSync(jfd); } catch (_) {}
    try { fs.unlinkSync(janitor); } catch (_) {}
  }
}

function acquire(lockPath, opts) {
  const timeoutMs = (opts && Number.isFinite(opts.timeoutMs)) ? opts.timeoutMs : 5000;
  const staleMs = (opts && Number.isFinite(opts.staleMs)) ? opts.staleMs : 30000;
  const dir = path.dirname(lockPath);
  try { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); } catch (_) {}

  const nonce = crypto.randomBytes(16).toString('hex');
  const payload = JSON.stringify({
    pid: process.pid,
    ts: Date.now() / 1000,
    host: os.hostname(),
    owner: 'node',
    nonce,
  });

  const deadline = Date.now() + timeoutMs;
  while (true) {
    let fd;
    try {
      fd = fs.openSync(lockPath, 'wx', 0o600);
    } catch (e) {
      if (e && e.code === 'EEXIST') {
        const stolen = _tryStealIfStale(lockPath, staleMs);
        if (stolen) continue;
        if (Date.now() >= deadline) return null;
        _sleepSync(50);
        continue;
      }
      // Unexpected OS error — respect timeout, retry.
      if (Date.now() >= deadline) return null;
      _sleepSync(50);
      continue;
    }
    try {
      fs.writeSync(fd, payload);
    } finally {
      try { fs.closeSync(fd); } catch (_) {}
    }
    // AD round 3 P0 fix — "empty-payload steal": if we paused for > staleMs
    // between openSync('wx') and writeSync, the empty lockfile could have been
    // reclaimed by a stale-stealer (empty payload → pid 0 → stealable). We
    // would then write into a stale fd and falsely own the lock. Re-read the
    // on-disk payload and confirm OUR nonce is there; if not, retry.
    const onDisk = _readPayload(lockPath);
    if (!onDisk || onDisk.nonce !== nonce) {
      if (Date.now() >= deadline) return null;
      _sleepSync(50);
      continue;
    }
    _ownedNonces.set(lockPath, nonce);
    return lockPath;
  }
}

function release(token) {
  // AD P0-1 fix: verify the on-disk payload still carries OUR nonce before
  // unlinking. If a stale-stealer reclaimed the lock while we were paused,
  // we MUST NOT delete the new owner's lockfile.
  if (!token) return;
  const ourNonce = _ownedNonces.get(token);
  _ownedNonces.delete(token);
  if (!ourNonce) return;
  let raw;
  try {
    raw = fs.readFileSync(token, 'utf8');
  } catch (e) {
    if (e && e.code === 'ENOENT') return;
    return;
  }
  if (raw && raw.trim()) {
    let payload;
    try { payload = JSON.parse(raw); } catch (_) { return; }
    if (payload && typeof payload === 'object' && payload.nonce && payload.nonce !== ourNonce) {
      // Someone else owns this lock now; leave it alone.
      return;
    }
  }
  try { fs.unlinkSync(token); } catch (_) { /* best-effort */ }
}

function refresh(token) {
  if (!token) return;
  try {
    const now = Date.now() / 1000;
    fs.utimesSync(token, now, now);
  } catch (_) { /* best-effort */ }
}

module.exports = { acquire, release, refresh };
