#!/usr/bin/env python3
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
CORTEX_DIR = Path(HOME) / ".claude" / "cortex"
PROJECTS_DIR = CORTEX_DIR / "projects"
LEARN_THRESHOLD = 50

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
OPENAI_RE = re.compile(r"sk-[A-Za-z0-9]{20,}")


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
    return s


# ── Error Detection (9 patterns from Sinapsis) ──────────────────────

ERROR_PATTERNS = [
    re.compile(r"\berror\b", re.I),
    re.compile(r"\bfailed\b", re.I),
    re.compile(r"\bexception\b", re.I),
    re.compile(r"\btraceback\b", re.I),
    re.compile(r"\bfatal\b", re.I),
    re.compile(r"\bpanic\b", re.I),
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


# ── File Locking ─────────────────────────────────────────────────────

def write_with_lock(filepath, content):
    """Write content to file with cross-platform file locking."""
    lockfile = str(filepath) + ".lock"
    try:
        import fcntl
        with open(lockfile, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                with open(filepath, "a") as f:
                    f.write(content + "\n")
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
    except ImportError:
        # Windows fallback — no fcntl available
        with open(filepath, "a") as f:
            f.write(content + "\n")


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
    """Detect project ID and name from git remote or cwd."""
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

    hash_input = remote_url or project_root
    project_id = hashlib.sha256(hash_input.encode()).hexdigest()[:12]

    return project_id, project_name, project_root, remote_url


def update_registry(project_id, project_name, project_root, remote_url):
    """Update projects/registry.json with project metadata."""
    registry_path = PROJECTS_DIR / "registry.json"
    os.makedirs(PROJECTS_DIR, exist_ok=True)

    registry = {}
    try:
        with open(registry_path) as f:
            registry = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        pass

    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    registry[project_id] = {
        "name": project_name,
        "root": project_root,
        "remote": remote_url,
        "last_seen": now,
    }

    atomic_write_json(str(registry_path), registry)


# ── Dedup ────────────────────────────────────────────────────────────

def get_dedup_dir():
    """Get per-user dedup directory with auto-cleanup."""
    uid = os.getuid() if hasattr(os, "getuid") else os.environ.get("UID", "0")
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

def archive_if_needed(obs_file, max_mb=10):
    """Archive observations file if it exceeds max_mb."""
    try:
        size = os.path.getsize(obs_file)
    except OSError:
        return
    if size / 1048576 >= max_mb:
        archive_dir = os.path.join(os.path.dirname(obs_file), "observations.archive")
        os.makedirs(archive_dir, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        dest = os.path.join(archive_dir, f"observations-{ts}-{os.getpid()}.jsonl")
        try:
            os.rename(obs_file, dest)
        except OSError:
            pass


def auto_purge(project_dir, days=30):
    """Purge archived observations older than N days."""
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

    # 3. Session guards
    if os.environ.get("ECC_HOOK_PROFILE", "standard") == "minimal":
        return
    if os.environ.get("ECC_SKIP_OBSERVE", "0") == "1":
        return

    # Skip subagents
    agent_id = data.get("agent_id", "")
    if agent_id:
        return

    # Skip non-useful tools
    tool_name = data.get("tool_name", data.get("tool", ""))
    if tool_name in ("ToolSearch", "Skill"):
        return

    # 4. Session ID and dedup
    session_id = re.sub(r"[^a-zA-Z0-9_-]", "", data.get("session_id", "unknown"))[:24]

    tool_input = data.get("tool_input", data.get("input", ""))
    input_str = json.dumps(tool_input) if isinstance(tool_input, dict) else str(tool_input)
    input_hash = hashlib.md5((tool_name + input_str).encode()).hexdigest()[:16]

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

    # is_error: from Claude Code flag OR output pattern detection
    is_error = data.get("is_error", False)
    if not is_error and event == "tc":
        output_str = json.dumps(tool_output)[:2000] if isinstance(tool_output, dict) else str(tool_output)[:2000]
        is_error = detect_is_error(output_str)

    error_msg = None
    if is_error:
        if isinstance(tool_output, dict):
            error_msg = str(tool_output.get("error", tool_output.get("message", "")))[:500]
        elif isinstance(tool_output, str):
            error_msg = tool_output[:500]

    if isinstance(tool_input_raw, dict):
        input_truncated = json.dumps(tool_input_raw)[:2000]
    else:
        input_truncated = str(tool_input_raw)[:2000]

    if isinstance(tool_output, dict):
        output_truncated = json.dumps(tool_output)[:1000]
    else:
        output_truncated = str(tool_output)[:1000]

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

    if is_error and error_msg:
        observation["err_msg"] = scrub_secrets(error_msg)

    if event == "ts" and input_truncated:
        observation["input"] = scrub_secrets(input_truncated)
    if event == "tc" and output_truncated:
        observation["output"] = scrub_secrets(output_truncated)

    obs_line = json.dumps(observation)

    # 10. Archive check + write with lock
    obs_file = os.path.join(project_dir, "observations.jsonl")
    archive_if_needed(obs_file)
    write_with_lock(obs_file, obs_line)

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
