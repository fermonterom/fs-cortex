#!/usr/bin/env python3
# CORTEX-MANAGED — do not edit manually, updated by install.sh
"""Cortex observer v3.0 — single-process replacement for observe.sh.

Reads tool use from stdin JSON, applies guards/dedup/scrubbing, writes JSONL.
Replaces ~11 Python spawns with 1.

Usage: python3 observe.py [pre|post]
"""

import sys
import json
import hashlib
import os
import re
import time
import tempfile
import subprocess
from pathlib import Path
from datetime import datetime, timezone

# ── Configuration ────────────────────────────────────────────────────

HOME = os.environ.get("HOME", os.environ.get("USERPROFILE", "/tmp"))
CORTEX_DIR = Path(os.environ.get("CORTEX_DIR") or (Path(HOME) / ".claude" / "cortex"))
PROJECTS_DIR = CORTEX_DIR / "projects"

# Load config from memory.json (dead code no more — Bug INC-9)
_config = {}
try:
    with open(CORTEX_DIR / "memory.json") as _f:
        _config = json.load(_f).get("config", {})
except (FileNotFoundError, json.JSONDecodeError, OSError):
    pass

MAX_FILE_SIZE_MB = _config.get("max_observations_mb", 5)
ARCHIVE_DAYS = _config.get("archive_days", 90)
LEARN_THRESHOLD = _config.get("learn_threshold", 100)

# ── Secret Scrubbing (12 patterns) ───────────────────────────────────

SECRET_RE = re.compile(
    r"(?i)(api[_-]?key|token|secret|password|authorization|credentials?|auth|bearer)"
    r"""(["'\s:=]+)"""
    r"([A-Za-z]+\s+)?"
    r"([A-Za-z0-9_\-/.+=]{8,})"
)
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")
PEM_RE = re.compile(r"-----BEGIN[A-Z \n]+-----[\s\S]*?-----END[A-Z \n]+-----")
SSH_RE = re.compile(r"-----BEGIN OPENSSH[A-Z \n]+-----[\s\S]*?-----END OPENSSH[A-Z \n]+-----")
AWS_RE = re.compile(r"AKIA[A-Z0-9]{16}")
GITHUB_RE = re.compile(r"gh[pousr]_[A-Za-z0-9_]{36,}")
STRIPE_RE = re.compile(r"[sr]k_(live|test)_[A-Za-z0-9]{20,}")
CONNSTR_RE = re.compile(r"(postgres|mysql|mongodb|redis)://[^\s]{10,}")
GOOGLE_RE = re.compile(r"AIza[A-Za-z0-9_-]{35}")
SLACK_RE = re.compile(r"xox[bpsa]-[A-Za-z0-9-]{10,}")
ANTHROPIC_RE = re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")
OPENAI_RE = re.compile(r"sk-[A-Za-z0-9_-]{20,}")

# v3.29.4: HTTPS git remote with embedded credentials (user:token@host).
# SSH remotes (git@host:owner/repo) are credential-free by construction.
GIT_REMOTE_CRED_RE = re.compile(r"^(https?://)[^@/\s]+@")

# v3.29.5 §F4 — Strip the local username from absolute home paths.
# Pre-v3.29.5 observations stored `/Users/fmm/github/X/file.ts` literally in
# the `input` / `output` / `err_msg` fields. The error-fix detector in
# session-learner.js then embedded the raw input into proposal actions, so
# cross-project paths leaked into proposals.json and (eventually) instinct
# YAMLs.
#
# Replacement strategy: `/Users/<username>/...` → `~/...`. The path structure
# (repo dir, leaf filename, extension) is preserved so downstream consumers
# that match `"file_path":"..."` continue to work — `path.basename('~/x/y.ts')`
# still returns `'y.ts'`. The user identity is what gets removed.
#
# Linux: `/home/<username>/...` covered by the same pattern below.
HOME_PATH_RE = re.compile(r"/(Users|home)/[A-Za-z0-9_.\-]+/")


def _scrub_git_remote(url):
    """Strip embedded credentials from an HTTPS git remote URL.

    `git remote get-url origin` faithfully echoes credentials the user
    stored in the remote — once those land in registry.json or the
    project cache they bypass scrub_secrets (which never inspects the
    registry). Strip on entry so the rest of the pipeline only sees a
    safe URL.
    """
    if not url:
        return url
    return GIT_REMOTE_CRED_RE.sub(r"\1", url)


def scrub_secrets(val):
    """Scrub secrets from a string using 12 patterns."""
    if val is None:
        return None
    s = str(val)
    s = SECRET_RE.sub(lambda m: m.group(1) + m.group(2) + (m.group(3) or "") + "[REDACTED]", s)
    s = JWT_RE.sub("[JWT_REDACTED]", s)
    s = PEM_RE.sub("[PEM_REDACTED]", s)
    s = SSH_RE.sub("[SSH_KEY_REDACTED]", s)
    s = AWS_RE.sub("[AWS_KEY_REDACTED]", s)
    s = GITHUB_RE.sub("[GITHUB_TOKEN_REDACTED]", s)
    s = STRIPE_RE.sub("[STRIPE_KEY_REDACTED]", s)
    s = CONNSTR_RE.sub("[CONNSTR_REDACTED]", s)
    s = GOOGLE_RE.sub("[GOOGLE_KEY_REDACTED]", s)
    s = SLACK_RE.sub("[SLACK_TOKEN_REDACTED]", s)
    s = ANTHROPIC_RE.sub("[ANTHROPIC_KEY_REDACTED]", s)
    s = OPENAI_RE.sub("[OPENAI_KEY_REDACTED]", s)
    # v3.29.5 §F4 — normalize absolute home paths to ~/ to prevent
    # cross-project username leakage via observations.jsonl → proposals.json.
    s = HOME_PATH_RE.sub("~/", s)
    return s


# ── Error Detection (9 patterns — keep aligned with session-learner.js isError()) ──

ERROR_PATTERNS = [
    re.compile(r"(?:^|\s)error[:\s]", re.I | re.M),          # "error:" not "ErrorBoundary"
    re.compile(r"(?:^|\s)failed(?!\s*:\s*0)", re.I | re.M),   # not "failed: 0"
    re.compile(r"\bexception\b", re.I),
    re.compile(r"\btraceback\b", re.I),
    re.compile(r"\bfatal\b", re.I),
    re.compile(r"(?:^|\s)panic[:(]", re.I | re.M),            # "panic:" not Go panic()
    re.compile(r"\bsegfault\b", re.I),
    re.compile(r"\bOOM\b"),
    re.compile(r"\bcommand not found\b", re.I),
]


def detect_is_error(output_text):
    """Returns True if output contains error patterns."""
    if not output_text:
        return False
    for pat in ERROR_PATTERNS:
        if pat.search(str(output_text)):
            return True
    return False


# v3.37.0 — binary/base64 payload detection for tc outputs. Screenshots and
# other media arrive as data URIs or long unbroken base64 runs; storing them
# verbatim buries the text outputs the learner's detectors read.
_BASE64_RUN = re.compile(r"^[A-Za-z0-9+/=\s]+$")


def _looks_binary(text):
    s = str(text)
    if s.startswith("data:image") or '"type": "image"' in s[:200] or '"type":"image"' in s[:200]:
        return True
    if len(s) < 500:
        return False
    probe = s[:1000]
    # A 1000-char window with no spaces and only base64 alphabet is a blob.
    compact = probe.replace("\n", "").replace(" ", "")
    return len(compact) > 900 and bool(_BASE64_RUN.match(compact))


# ── File Locking ─────────────────────────────────────────────────────

def write_with_lock(filepath, content, pre_write_fn=None):
    """Write content to file with cross-platform file locking.

    v3.29.3: Windows path uses a separate lockfile (msvcrt.locking on the
    data file's FD corrupted the append cursor). POSIX path is unchanged —
    the .lock file is intentionally persistent (one per project, bounded ≤N).

    v3.29.4: optional `pre_write_fn(filepath)` runs INSIDE the lock right
    before the append. Used for archive rotation — keeping size-check +
    rename inside the same critical section prevents the race where a
    concurrent writer appends to the file we just renamed.
    """
    def _critical_section():
        if pre_write_fn is not None:
            try:
                pre_write_fn(filepath)
            except OSError:
                pass
        with open(filepath, "a") as f:
            f.write(content + "\n")

    lockfile = str(filepath) + ".lock"
    try:
        import fcntl
        with open(lockfile, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                _critical_section()
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
    except ImportError:
        # Windows fallback — lock the SEPARATE lockfile, never the data FD.
        try:
            import msvcrt
            with open(lockfile, "a+") as lock:
                try:
                    lock.seek(0)
                    msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
                    try:
                        _critical_section()
                    finally:
                        try:
                            lock.seek(0)
                            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
                        except OSError:
                            pass
                except OSError:
                    # Lock unavailable — degrade to plain append, never block.
                    _critical_section()
        except (ImportError, OSError):
            # Ultimate fallback — plain append
            _critical_section()


def atomic_write_json(filepath, data):
    """Atomic JSON write via tmp+rename."""
    dirpath = os.path.dirname(filepath)
    os.makedirs(dirpath, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dirpath, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, filepath)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ── Project Detection ────────────────────────────────────────────────

def detect_project(cwd):
    """Detect project ID and name from git remote or cwd. Uses file-based cache (5min TTL)."""
    # Check file-based cache first (avoid git subprocess per tool use)
    cwd_hash = hashlib.sha256(cwd.encode()).hexdigest()[:12]
    cache_file = os.path.join(get_dedup_dir(), f"project-{cwd_hash}")
    try:
        if os.path.exists(cache_file):
            with open(cache_file) as f:
                cached = json.load(f)
            if time.time() - cached.get("ts", 0) < 300:  # 5min TTL
                return cached["pid"], cached["pname"], cached["proot"], cached["remote"]
    except (OSError, json.JSONDecodeError, KeyError):
        pass

    project_id = "global"
    project_name = "global"
    project_root = ""
    remote_url = ""

    try:
        project_root = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3
        ).stdout.strip()
    except Exception:
        pass

    if not project_root:
        return project_id, project_name, project_root, remote_url

    project_name = os.path.basename(project_root)

    try:
        remote_url = subprocess.run(
            ["git", "-C", project_root, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=3
        ).stdout.strip()
    except Exception:
        pass

    # v3.29.4: strip user:token@ from HTTPS remotes before anything downstream
    # (registry.json, project cache, project_id hash) ever sees them.
    remote_url = _scrub_git_remote(remote_url)

    hash_input = remote_url or project_root
    project_id = hashlib.sha256(hash_input.encode()).hexdigest()[:12]

    # Write cache
    try:
        with open(cache_file, "w") as f:
            json.dump({"pid": project_id, "pname": project_name, "proot": project_root, "remote": remote_url, "ts": time.time()}, f)
    except OSError:
        pass

    return project_id, project_name, project_root, remote_url


def update_registry(project_id, project_name, project_root, remote_url):
    """Update projects/registry.json only if project is new or metadata changed."""
    registry_path = PROJECTS_DIR / "registry.json"
    os.makedirs(PROJECTS_DIR, exist_ok=True)

    registry = {}
    try:
        with open(registry_path) as f:
            registry = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        pass

    existing = registry.get(project_id, {})
    if existing.get("root") == project_root and existing.get("remote") == remote_url:
        return  # No change, skip write

    now_str = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    registry[project_id] = {
        "name": project_name,
        "root": project_root,
        "remote": remote_url,
        "last_seen": now_str,
    }

    atomic_write_json(str(registry_path), registry)


# ── Dedup ────────────────────────────────────────────────────────────

def get_dedup_dir():
    """Get per-user dedup directory with auto-cleanup."""
    uid = os.getuid() if hasattr(os, "getuid") else os.environ.get("USERNAME", os.environ.get("UID", "0"))
    base = os.environ.get("XDG_RUNTIME_DIR", os.environ.get("TMPDIR", tempfile.gettempdir()))
    dedup_dir = os.path.join(base, f"cortex-{uid}")
    os.makedirs(dedup_dir, mode=0o700, exist_ok=True)

    # Cleanup old dedup files (>24h)
    try:
        cutoff = time.time() - 86400
        for f in os.listdir(dedup_dir):
            if f.startswith("dedup-"):
                fpath = os.path.join(dedup_dir, f)
                if os.path.getmtime(fpath) < cutoff:
                    os.unlink(fpath)
    except OSError:
        pass

    return dedup_dir


def is_duplicate(dedup_file, input_hash):
    """Check if this observation is a duplicate within the session."""
    if not input_hash:
        return False
    try:
        if os.path.exists(dedup_file):
            with open(dedup_file) as f:
                if input_hash in f.read():
                    return True
    except OSError:
        pass
    return False


def update_dedup(dedup_file, input_hash):
    """Update dedup file, keeping last 5 entries."""
    if not input_hash:
        return
    try:
        lines = []
        if os.path.exists(dedup_file):
            with open(dedup_file) as f:
                lines = f.read().strip().split("\n")[-4:]  # keep last 4
        lines.append(input_hash)
        with open(dedup_file, "w") as f:
            f.write("\n".join(lines) + "\n")
    except OSError:
        pass


# ── Archive ──────────────────────────────────────────────────────────

def archive_if_needed(obs_file, max_mb=None):
    """Archive observations file if it exceeds max_mb."""
    if max_mb is None:
        max_mb = MAX_FILE_SIZE_MB
    try:
        size = os.path.getsize(obs_file)
    except OSError:
        return
    if size / 1048576 >= max_mb:
        archive_dir = os.path.join(os.path.dirname(obs_file), "observations.archive")
        os.makedirs(archive_dir, exist_ok=True)
        # v3.29.4: UTC-aware timestamp matches the rest of the file (line 549).
        ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        dest = os.path.join(archive_dir, f"observations-{ts}-{os.getpid()}.jsonl")
        try:
            os.rename(obs_file, dest)
        except OSError:
            pass


def auto_purge(project_dir, days=None):
    """Purge archived observations older than N days."""
    if days is None:
        days = ARCHIVE_DAYS
    purge_marker = os.path.join(project_dir, ".last-purge")
    try:
        if os.path.exists(purge_marker):
            age = time.time() - os.path.getmtime(purge_marker)
            if age < 86400:  # already purged today
                return
    except OSError:
        pass

    try:
        cutoff = time.time() - (days * 86400)
        archive_dir = os.path.join(project_dir, "observations.archive")
        if os.path.isdir(archive_dir):
            for f in os.listdir(archive_dir):
                fpath = os.path.join(archive_dir, f)
                if f.startswith("observations-") and os.path.getmtime(fpath) < cutoff:
                    os.unlink(fpath)
        # Touch marker
        Path(purge_marker).touch()
    except OSError:
        pass


# ── Obs Count ────────────────────────────────────────────────────────

def update_obs_count():
    """Increment observation count, trigger learn-pending at threshold."""
    count_file = CORTEX_DIR / ".obs-count"
    count = 0
    try:
        if count_file.exists():
            count = int(count_file.read_text().strip())
    except (ValueError, OSError):
        pass

    count += 1

    # Atomic write
    tmp = str(count_file) + f".tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            f.write(str(count))
        os.replace(tmp, str(count_file))
    except OSError:
        pass

    if count >= LEARN_THRESHOLD:
        try:
            (CORTEX_DIR / ".learn-pending").touch()
            tmp2 = str(count_file) + f".tmp.{os.getpid()}"
            with open(tmp2, "w") as f:
                f.write("0")
            os.replace(tmp2, str(count_file))
        except OSError:
            pass


# ── Watchdog ─────────────────────────────────────────────────────────

WATCHDOG_RE = re.compile(r"\b(FATAL|PANIC|OOM|segfault|killed|ENOSPC|out of memory)\b", re.I)


def watchdog_check(output_text):
    """Alert on critical errors in output."""
    if output_text and WATCHDOG_RE.search(str(output_text)):
        sys.stderr.write("[cortex-watchdog] Critical error detected in output.\n")


# ── Main ─────────────────────────────────────────────────────────────

def main():
    hook_phase = sys.argv[1] if len(sys.argv) > 1 else "post"

    # 1. Read stdin
    raw = sys.stdin.read()
    if not raw.strip():
        return

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return

    # 2. Skip if disabled
    if (CORTEX_DIR / "disabled").exists():
        return

    # 2b. v3.29.0 (Sprint 8 §4.8) kill switch. CORTEX_OBSERVE_OFF=1 returns
    # before any writes happen — observations.jsonl (global + per-project),
    # dedup files, registry, archive, obs-count counters all stay untouched.
    # Useful when the operator wants to run Claude Code without contributing
    # to the Cortex learning corpus for one session (privacy, debugging,
    # smoke-testing an unrelated feature).
    if os.environ.get("CORTEX_OBSERVE_OFF", "0") == "1":
        return

    # 3. Session guards
    if os.environ.get("ECC_HOOK_PROFILE", "standard") == "minimal":
        return
    if os.environ.get("ECC_SKIP_OBSERVE", "0") == "1":
        return

    # Capture subagent ID if present (no longer skipped — v3.8.0)
    agent_id = data.get("agent_id", "")

    # Skip non-useful tools (Skill kept for cx-* timeline tracking in session-learner)
    tool_name = data.get("tool_name", data.get("tool", ""))
    if tool_name in ("ToolSearch",):
        return

    # 4. Session ID and dedup
    # Claude Code session_id is a 36-char UUID. Pre-v3.19.3 we truncated to
    # [:24], which broke `correlateReflexFeedback` and `correlateImpactEvents`
    # in session-learner.js (impact.jsonl stores the full UUID, observations
    # stored the truncated form, so candidateSids.has(ev.sid) never matched
    # and usefulCount/noiseCount stayed at 0 for every reflex). Allow the full
    # UUID with margin.
    session_id = re.sub(r"[^a-zA-Z0-9_-]", "", data.get("session_id", "unknown"))[:64]

    tool_input = data.get("tool_input", data.get("input", ""))
    input_str = json.dumps(tool_input) if isinstance(tool_input, dict) else str(tool_input)
    # v3.29.4: SHA256 instead of MD5. MD5 raises ValueError under FIPS mode
    # (RHEL/CentOS hardened deployments) and the top-level except in main()
    # only writes to stderr under CORTEX_DEBUG — observations were silently
    # discarded in production. SHA256 is FIPS-compliant and equally fast.
    input_hash = hashlib.sha256((tool_name + input_str).encode()).hexdigest()[:16]

    dedup_dir = get_dedup_dir()
    dedup_file = os.path.join(dedup_dir, f"dedup-{session_id}")

    if is_duplicate(dedup_file, input_hash):
        return

    update_dedup(dedup_file, input_hash)

    # 5. Extract cwd and detect project
    cwd = data.get("cwd", os.getcwd())
    project_id, project_name, project_root, remote_url = detect_project(cwd)

    project_dir = str(PROJECTS_DIR / project_id) if project_id != "global" else str(CORTEX_DIR)
    os.makedirs(os.path.join(project_dir, "observations.archive"), exist_ok=True)

    # 6. Update registry
    if project_id != "global" and project_root:
        update_registry(project_id, project_name, project_root, remote_url)

    # 7. Auto-purge
    auto_purge(project_dir)

    # 8. Parse observation
    event = "ts" if hook_phase == "pre" else "tc"

    tool_output = data.get("tool_response", data.get("tool_output", data.get("output", "")))
    tool_input_raw = data.get("tool_input", data.get("input", {}))

    # ── v3.15.0 · robust PostToolUse parser ──────────────────────────────
    # Claude Code actually sends tool_response as either a string (older tools)
    # OR as `{"content": [{"type":"text","text":"..."}], "is_error": bool}`
    # (Anthropic API v1 shape, recent release). Older observe.py only looked
    # at top-level .error/.message — so err_msg NEVER persisted (corpus proof:
    # 3 errors detected / 0 err_msg captured on 3730 obs). Fix:
    #   1. Unwrap content[].text into a concatenated plain string when present.
    #   2. Prefer the explicit is_error flag over heuristic detection.
    #   3. Fall back to the heuristic for tools without structured responses.

    def _flatten_tool_response(resp):
        """Return (flat_text, is_error_flag, raw_for_input_logs).

        flat_text — concatenated .text of content[type=text] blocks, or str(resp)
        is_error_flag — resp.is_error if present, else None (caller falls back)
        raw_for_input_logs — the original value (dict or str) for JSON truncation
        """
        if isinstance(resp, dict):
            flag = resp.get("is_error")
            content = resp.get("content")
            if isinstance(content, list):
                parts = []
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        txt = block.get("text", "")
                        if isinstance(txt, str):
                            parts.append(txt)
                if parts:
                    return ("\n".join(parts), flag, resp)
            # Fallback to .error / .message / whole JSON
            for key in ("error", "message", "output", "stderr", "stdout"):
                val = resp.get(key)
                if isinstance(val, str) and val:
                    return (val, flag, resp)
            return (json.dumps(resp)[:2000], flag, resp)
        if isinstance(resp, list):
            # rare: API may send content blocks at the top level
            parts = [b.get("text", "") for b in resp if isinstance(b, dict) and b.get("type") == "text"]
            return ("\n".join(parts) if parts else json.dumps(resp)[:2000], None, resp)
        return (str(resp), None, resp)

    flat_text, is_error_flag, _ = _flatten_tool_response(tool_output)

    is_error = bool(data.get("is_error", False)) or bool(is_error_flag)
    if not is_error and event == "tc":
        is_error = detect_is_error(flat_text[:2000])

    error_msg = None
    if is_error:
        # Prefer the flat_text we just extracted (handles content[].text properly)
        if flat_text:
            error_msg = flat_text[:500]
        elif isinstance(tool_output, dict):
            error_msg = str(tool_output.get("error", tool_output.get("message", "")))[:500]

    # v3.37.0 — caps raised 2000/1000 → 5000/8000. The learner's detectors
    # need enough of the failing input to derive a specific trigger and
    # enough of the output to show real evidence in /cx-validate. Disk cost
    # is bounded by the existing 10MB rotation (archive_if_needed).
    if isinstance(tool_input_raw, dict):
        input_truncated = json.dumps(tool_input_raw)[:5000]
    else:
        input_truncated = str(tool_input_raw)[:5000]

    # For output logging on tc events, prefer flat_text (readable) over raw dict JSON.
    if flat_text and event == "tc":
        output_truncated = flat_text[:8000]
    elif isinstance(tool_output, dict):
        output_truncated = json.dumps(tool_output)[:8000]
    else:
        output_truncated = str(tool_output)[:8000]

    # v3.37.0 — base64/screenshot blobs are disk noise, not signal: recent
    # fersora tc records were mostly image payloads, drowning the few
    # text outputs the detectors actually read.
    if output_truncated and _looks_binary(output_truncated):
        output_truncated = "[binary output omitted]"

    # 9. Build observation with scrubbing
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    observation = {
        "ts": timestamp,
        "ev": event,
        "tool": tool_name,
        "err": is_error,
        "sid": session_id,
        "pid": project_id,
        "pname": project_name,
    }

    if agent_id:
        observation["aid"] = agent_id[:24]

    if is_error and error_msg:
        observation["err_msg"] = scrub_secrets(error_msg)

    if event == "ts" and input_truncated:
        observation["input"] = scrub_secrets(input_truncated)
    if event == "tc" and output_truncated:
        observation["output"] = scrub_secrets(output_truncated)

    obs_line = json.dumps(observation)

    # 10. Archive check + write — both under the same lock (v3.29.4) to
    # prevent a concurrent appender from writing into a just-renamed file.
    obs_file = os.path.join(project_dir, "observations.jsonl")
    write_with_lock(obs_file, obs_line, pre_write_fn=archive_if_needed)

    # 11. Watchdog
    if event == "tc":
        watchdog_check(output_truncated)

    # 12. Obs count
    update_obs_count()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        if os.environ.get("CORTEX_DEBUG"):
            sys.stderr.write(f"[cortex:observe] {e}\n")
    sys.exit(0)
