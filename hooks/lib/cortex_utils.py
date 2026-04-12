# CORTEX-MANAGED — do not edit manually, updated by install.sh
# Shared Python utilities for Cortex hooks (session-start.py, observe.py)
"""Shared utilities: sanitization, project detection, file I/O."""

import hashlib
import json
import os
import re
import subprocess
import tempfile

# Prompt injection patterns — same set used by injector-engine.js
BLOCKED_KEYWORDS = re.compile(
    r'\b(ignore|forget|override|disregard|bypass|system\s*:|you\s+are|'
    r'all\s+previous|new\s+instructions|do\s+not\s+follow)\b',
    re.IGNORECASE
)


def sanitize_injection(text, max_len=2000):
    """Strip control chars and prompt injection keywords from injected text."""
    if not isinstance(text, str):
        return ""
    clean = re.sub(r'[\x00-\x1f\x7f]', '', text)
    clean = BLOCKED_KEYWORDS.sub('[BLOCKED]', clean)
    return clean[:max_len]


def detect_project(cwd):
    """Detect project from git remote URL → sha256[:12]. Returns (project_id, root, remote)."""
    root = ""
    remote = ""
    try:
        result = subprocess.run(
            ['git', '-C', cwd, 'rev-parse', '--show-toplevel'],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            root = result.stdout.strip()
    except Exception:
        pass
    try:
        result = subprocess.run(
            ['git', '-C', cwd, 'remote', 'get-url', 'origin'],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            remote = result.stdout.strip()
    except Exception:
        pass
    hash_input = remote or root
    if not hash_input:
        return None, cwd, ""
    project_id = hashlib.sha256(hash_input.encode()).hexdigest()[:12]
    return project_id, root or cwd, remote


def read_json_safe(filepath, default=None):
    """Read JSON file, return default on any error."""
    try:
        with open(filepath) as f:
            return json.load(f)
    except Exception:
        return default if default is not None else {}


def atomic_write(filepath, content):
    """Write content atomically via temp+rename."""
    dirpath = os.path.dirname(filepath)
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix='.tmp-')
    try:
        os.write(fd, content.encode() if isinstance(content, str) else content)
        os.close(fd)
        os.chmod(tmp, 0o600)
        os.replace(tmp, filepath)
    except Exception:
        os.close(fd) if not os.get_inheritable(fd) else None
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise
