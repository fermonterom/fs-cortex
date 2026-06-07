"""file_lock.py — cross-runtime advisory lock for shared Cortex files.

Coordinates writes to ``proposals-history.jsonl`` and ``instinct-tracking.json``
between the Python distill engine and the Node Stop hook
(``hooks/session-learner.js``). Issue #49.

Mechanism: lockfile created with O_CREAT|O_EXCL. The same semantics are
available in Node via ``fs.openSync(path, 'wx')``, so the two runtimes
coordinate at the filesystem level. Zero external deps.

Stale detection: if the lockfile exists with mtime older than ``stale_ms``
AND the PID it records is not alive, the lock is reclaimed. Both conditions
must hold so a recycled PID (rare but possible in containers) cannot trigger
a steal of a live lock — we degrade to "wait for timeout" rather than risk
double-write.

Usage::

    token = acquire(path, timeout_ms=5000, stale_ms=30000)
    if token is None:
        raise RuntimeError("could not acquire lock")
    try:
        ...
    finally:
        release(token)
"""
from __future__ import annotations

import errno
import json
import os
import secrets
import socket
import threading
import time
from pathlib import Path
from typing import Optional


_RUNTIME_TAG = "py"

# AD P0-1 fix: per-lock nonce so ``release`` only unlinks a lockfile we
# actually still own. Without this, a process resumed from a long pause
# (GC, SIGSTOP) could unlink a lock that a stale-stealer already reclaimed
# in the meantime — leading to two co-owners.
_owned_lock = threading.Lock()
_owned_nonces: dict[str, str] = {}


def _pid_alive(pid: int) -> bool:
    if not pid or pid < 1:
        return False
    if os.name == "nt":
        try:
            import ctypes
            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            handle = ctypes.windll.kernel32.OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid)
            )
            if not handle:
                return False
            try:
                exit_code = ctypes.c_ulong(0)
                STILL_ACTIVE = 259
                ok = ctypes.windll.kernel32.GetExitCodeProcess(
                    handle, ctypes.byref(exit_code)
                )
                if not ok:
                    return False
                return exit_code.value == STILL_ACTIVE
            finally:
                ctypes.windll.kernel32.CloseHandle(handle)
        except Exception:
            # Be conservative: if we cannot tell, assume alive so we wait
            # rather than steal a possibly-live lock.
            return True
    try:
        os.kill(int(pid), 0)
        return True
    except OSError as e:
        if e.errno == errno.EPERM:
            return True
        return False


def _read_lock_payload(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
        if not raw.strip():
            return {}
        return json.loads(raw)
    except (OSError, ValueError):
        return {}




def _is_stale(path: str, stale_ms: int) -> bool:
    """True if the lockfile at `path` is stale (old mtime AND a dead PID)."""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return False
    if (time.time() - st.st_mtime) * 1000.0 <= stale_ms:
        return False
    payload = _read_lock_payload(path)
    try:
        pid = int(payload.get("pid", 0))
    except (TypeError, ValueError):
        pid = 0
    if pid and _pid_alive(pid):
        return False
    return True


def _try_steal_if_stale(path: str, stale_ms: int) -> bool:
    """Reclaim `path` if it is stale. Return True if `path` is now free to
    (re)create, False otherwise (not stale, or another reclaimer is active).

    AD round 4 fix — the janitor must NOT break itself by age. Two processes
    could concurrently decide a stale janitor is old, both unlink it, both
    create a fresh one, and one would steal a valid lock. If the janitor O_EXCL
    fails we return False immediately — no stat, no unlink of the janitor.
    Orphaned janitors (from a crash between open and finally-unlink) are left
    in place and block reclaim until manually removed or the lock dir is cleaned.
    """
    if not _is_stale(path, stale_ms):
        try:
            return not os.path.exists(path)  # gone already → free to create
        except OSError:
            return False
    janitor = path + ".janitor"
    try:
        jfd = os.open(janitor, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        # Another reclaimer holds the janitor — do not break it (meta-TOCTOU).
        return False
    except OSError:
        return False
    try:
        # Re-verify staleness UNDER the janitor. If another process already
        # created a fresh lock, _is_stale is now False → we must not remove it.
        if not _is_stale(path, stale_ms):
            return not os.path.exists(path)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        except OSError:
            return False
        return True
    finally:
        try:
            os.close(jfd)
        except OSError:
            pass
        try:
            os.unlink(janitor)
        except OSError:
            pass


def acquire(
    path: str | os.PathLike,
    timeout_ms: int = 5000,
    stale_ms: int = 30000,
) -> Optional[str]:
    """Acquire the lockfile; return the path on success or None on timeout."""
    p = str(path)
    Path(p).parent.mkdir(parents=True, exist_ok=True)
    nonce = secrets.token_hex(16)
    payload = json.dumps(
        {
            "pid": os.getpid(),
            "ts": time.time(),
            "host": socket.gethostname(),
            "owner": _RUNTIME_TAG,
            "nonce": nonce,
        },
        ensure_ascii=False,
    ).encode("utf-8")

    deadline = time.monotonic() + (timeout_ms / 1000.0)
    while True:
        try:
            fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            stolen = _try_steal_if_stale(p, stale_ms)
            if stolen:
                continue
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.05)
            continue
        except OSError:
            # Treat unexpected OS errors as transient; respect timeout.
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.05)
            continue
        try:
            os.write(fd, payload)
        finally:
            os.close(fd)
        # AD round 3 P0 fix — "empty-payload steal": if we paused for
        # > stale_ms between os.open(O_EXCL) and os.write, the lockfile was
        # empty long enough for a stale-stealer to reclaim it (empty payload →
        # pid 0 → stealable). We would then write into an already-unlinked fd
        # and falsely believe we own the lock. Re-read the on-disk payload and
        # confirm OUR nonce is there; if not, we lost the lock — retry.
        if _read_lock_payload(p).get("nonce") != nonce:
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.05)
            continue
        with _owned_lock:
            _owned_nonces[p] = nonce
        return p


def release(token: Optional[str]) -> None:
    """Release the lock — but only if the on-disk payload still carries OUR
    nonce. If a stale-stealer reclaimed the lock while we were paused, the
    on-disk payload now belongs to the new owner and we MUST NOT unlink it.
    AD P0-1 fix."""
    if not token:
        return
    with _owned_lock:
        our_nonce = _owned_nonces.pop(token, None)
    if our_nonce is None:
        return
    try:
        with open(token, encoding="utf-8") as fh:
            raw = fh.read()
        if not raw.strip():
            # Empty payload (e.g. our own crash between open and write); safe
            # to unlink: nobody else could have written a nonce.
            on_disk_nonce = None
        else:
            payload = json.loads(raw)
            on_disk_nonce = payload.get("nonce") if isinstance(payload, dict) else None
    except FileNotFoundError:
        return
    except (OSError, ValueError):
        # Corrupt or unreadable: leave it for stale detection.
        return
    if on_disk_nonce is not None and on_disk_nonce != our_nonce:
        # Someone else owns this lock now; leave it alone.
        return
    try:
        os.unlink(token)
    except FileNotFoundError:
        pass
    except OSError:
        pass


def refresh(token: Optional[str]) -> None:
    """Touch the lockfile mtime so a long-running owner is not seen as stale."""
    if not token:
        return
    try:
        now = time.time()
        os.utime(token, (now, now))
    except OSError:
        pass
