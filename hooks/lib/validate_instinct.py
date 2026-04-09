#!/usr/bin/env python3
"""Validate instinct YAML files against injection patterns and safety rules."""

import re
import sys


BLOCKED_PATTERNS = [
    r'\b(ignore|forget|override|disregard|bypass)\b.*\b(previous|instructions|rules)\b',
    r'\b(system\s*:)',
    r'\b(you\s+are\s+now)\b',
]


def validate_instinct(filepath):
    """Validate an instinct YAML file against injection patterns.

    Returns (is_valid, reason).
    """
    try:
        with open(filepath) as f:
            content = f.read()
    except (OSError, IOError) as e:
        return False, f"Cannot read file: {e}"

    # Check action field
    for line in content.split('\n'):
        stripped = line.strip()
        if stripped.startswith('action:'):
            action = stripped.split(':', 1)[1].strip().strip('"').strip("'")
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


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: validate_instinct.py <filepath>", file=sys.stderr)
        sys.exit(1)
    valid, reason = validate_instinct(sys.argv[1])
    print(f"{'VALID' if valid else 'INVALID'}: {reason}")
    sys.exit(0 if valid else 1)
