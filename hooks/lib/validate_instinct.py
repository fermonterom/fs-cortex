#!/usr/bin/env python3
"""Validate instinct YAML files against injection patterns and safety rules."""

import re
import sys


BLOCKED_PATTERNS = [
    r'\b(ignore|forget|override|disregard|bypass)\b.*\b(previous|instructions|rules)\b',
    r'\b(system\s*:)',
    r'\b(you\s+are\s+now)\b',
]


def validate_yaml_content(content):
    """Validate raw YAML instinct content against injection patterns.

    Pure function — operates on the YAML string, no file I/O. Use this from
    callers that have already generated the YAML in memory (e.g. distill_engine
    auto_validate_proposals — v3.29.5 §F2) before writing to disk.

    Returns (is_valid, reason).
    """
    # Check action field — handle YAML multiline values (| or >)
    fm_match = re.search(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
    if fm_match:
        block = fm_match.group(1)
        # Extract action: inline value OR multiline continuation lines
        action_match = re.search(
            r'^action:\s*(?:[|>]-?\s*\n((?:[ \t]+.+\n?)*)|(.*?)$)',
            block, re.MULTILINE
        )
        if action_match:
            action = (action_match.group(1) or action_match.group(2) or '').strip().strip('"').strip("'")
            if len(action) > 500:
                return False, f"Action too long ({len(action)} chars, max 500)"
            for pat in BLOCKED_PATTERNS:
                if re.search(pat, action, re.I):
                    return False, f"Blocked pattern found: {pat}"

    # Check trigger field — reject universal wildcard without domain restriction
    for line in content.split('\n'):
        stripped = line.strip()
        if stripped.startswith('trigger:'):
            trigger = stripped.split(':', 1)[1].strip().strip('"').strip("'")
            if trigger in ['.*', '.+', '.*?', '.+?']:
                return False, "Universal wildcard trigger without domain restriction"

    return True, "OK"


def validate_instinct(filepath):
    """Validate an instinct YAML file against injection patterns.

    Thin wrapper over validate_yaml_content for filepath-based callers (CLI,
    distill_engine.distill, dream_cycle regex audit).

    Returns (is_valid, reason).
    """
    try:
        with open(filepath) as f:
            content = f.read()
    except (OSError, IOError) as e:
        return False, f"Cannot read file: {e}"

    return validate_yaml_content(content)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: validate_instinct.py <filepath>", file=sys.stderr)
        sys.exit(1)
    valid, reason = validate_instinct(sys.argv[1])
    print(f"{'VALID' if valid else 'INVALID'}: {reason}")
    sys.exit(0 if valid else 1)
