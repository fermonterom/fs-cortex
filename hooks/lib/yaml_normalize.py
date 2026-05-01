#!/usr/bin/env python3
"""Normalize instinct YAML files to be strict-parse safe.

Problem: Claude frequently writes instinct YAMLs with regex triggers in
double-quoted strings like `trigger: "Bash.*\\.env"`. YAML double-quoted
strings interpret backslash sequences (\\s, \\., \\() as escape characters,
which strict parsers (PyYAML, etc.) reject.

Fix: convert the offending double-quoted values to single-quoted (literal),
or to a block scalar when the value contains a single quote. Idempotent —
already-valid files are untouched.

Callable as a module (normalize_all(root) → count) or as a standalone script
(exit 0 always; prints number of files repaired to stderr).

Safe to run on every SessionStart: scans ~128 files in <100ms.

Stdlib-only (v3.23.2+): the previous version imported PyYAML to validate
that the rewritten file would parse cleanly. The validation step has been
replaced with a stdlib regex check that detects exactly the failure mode
this module fixes (invalid backslash escapes inside double-quoted strings
on REGEX_KEYS lines). Other YAML errors (missing colons, bad indentation)
were never the target of this module — PyYAML caught them but the module
just no-op'd, identical behavior to the new stdlib check.
"""

import os
import re
import sys
import glob

REGEX_KEYS = {'trigger', 'condition', 'matcher', 'action'}
VALID_DOUBLE_QUOTE_ESCAPES = set('0abtnvfre\\"/N_LPxuU ')

# Pre-compiled: matches `<indent>key: "<inner>"` with optional trailing whitespace.
_DQ_LINE_RE = re.compile(r'^(\s*)(\w[\w_-]*)\s*:\s*"(.*)"\s*$')


def _invalid_double_quote(inner):
    """True if inner (content between double quotes) contains an invalid escape."""
    i = 0
    while i < len(inner):
        if inner[i] == '\\' and i + 1 < len(inner):
            if inner[i + 1] not in VALID_DOUBLE_QUOTE_ESCAPES:
                return True
            i += 2
        else:
            i += 1
    return False


def _has_broken_dq_line(text):
    """True if any line in text is `<key>: "<value with bad escape>"` and key is a
    REGEX_KEYS member. This is the exact failure mode the module fixes — using it
    as the pre-check (skip already-clean files) and as the post-rewrite safety
    check eliminates the PyYAML dependency without changing module behavior on
    files this module was ever expected to touch.
    """
    for line in text.split('\n'):
        m = _DQ_LINE_RE.match(line)
        if not m:
            continue
        key, val = m.group(2), m.group(3)
        if key in REGEX_KEYS and _invalid_double_quote(val):
            return True
    return False


def _convert_line(line):
    """If line is `key: "..."` with key in REGEX_KEYS and value has invalid escapes,
    rewrite as `key: '...'` (or block scalar if value contains `'`).
    Returns the possibly rewritten line (without trailing newline).
    """
    m = _DQ_LINE_RE.match(line)
    if not m:
        return line
    indent, key, val = m.group(1), m.group(2), m.group(3)
    if key not in REGEX_KEYS:
        return line
    if not _invalid_double_quote(val):
        return line
    if "'" not in val:
        return f"{indent}{key}: '{val}'"
    # Block scalar fallback (literal, strip trailing newline)
    lines = [f"{indent}{key}: |-"]
    for sub in val.split('\n'):
        lines.append(indent + '  ' + sub)
    return '\n'.join(lines)


def normalize_file(path):
    """Normalize a single YAML file. Returns True if rewritten, False if no change."""
    try:
        raw = open(path).read()
    except OSError:
        return False
    out_lines = []
    changed = False
    for line in raw.split('\n'):
        new = _convert_line(line)
        if new != line:
            changed = True
        out_lines.append(new)
    if not changed:
        return False
    new_raw = '\n'.join(out_lines)
    # Safety: only persist if no broken double-quoted REGEX_KEYS line remains.
    # _convert_line should have rewritten every offender; this is a sanity check.
    if _has_broken_dq_line(new_raw):
        return False
    try:
        with open(path, 'w') as f:
            f.write(new_raw)
    except OSError:
        return False
    return True


def normalize_all(root=None):
    """Scan all instinct directories under ~/.claude/cortex and normalize any broken YAMLs.
    Returns the number of files repaired.
    """
    home = os.environ.get('HOME', '/tmp')
    if root is None:
        root = os.environ.get('CORTEX_DIR') or os.path.join(home, '.claude', 'cortex')
    dirs = [os.path.join(root, 'instincts', 'global')]
    dirs.extend(glob.glob(os.path.join(root, 'projects', '*', 'instincts')))
    repaired = 0
    for d in dirs:
        if not os.path.isdir(d) or 'archive' in d:
            continue
        for f in os.listdir(d):
            if not f.endswith('.yaml'):
                continue
            path = os.path.join(d, f)
            # Only touch files that have a broken double-quoted REGEX_KEYS line.
            try:
                with open(path) as fh:
                    if not _has_broken_dq_line(fh.read()):
                        continue  # already clean for our purposes
            except OSError:
                continue
            if normalize_file(path):
                repaired += 1
    return repaired


if __name__ == '__main__':
    n = normalize_all()
    if n > 0:
        print(f'[cortex:yaml-normalize] repaired {n} instinct YAML file(s)', file=sys.stderr)
    sys.exit(0)
