#!/usr/bin/env python3
# CORTEX-MANAGED — do not edit manually, updated by install.sh
# Cortex Session Start v3.0 — SessionStart hook (Python rewrite)
# Injects Laws + EOD Quick Resume + context.md bridge + maintenance reminders.
# Fires on SessionStart and /compact.
"""
Pure Python replacement for session-start.sh. Eliminates BSD/GNU date
incompatibilities, inline python3 -c snippets, and sed/tr/grep chains.
"""

import json
import os
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

# Import shared utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
try:
    from cortex_utils import sanitize_injection, detect_project
except ImportError:
    # Fallback if lib not available
    def sanitize_injection(text, max_len=2000):
        if not isinstance(text, str):
            return ""
        clean = re.sub(r'[\x00-\x1f\x7f]', '', text)
        return clean[:max_len]
    def detect_project(cwd):
        return None, cwd, ""


HOME = os.environ.get('HOME', os.environ.get('USERPROFILE', '/tmp'))
CORTEX_DIR = Path(os.environ.get('CORTEX_DIR') or (Path(HOME) / '.claude' / 'cortex'))
LAWS_DIR = CORTEX_DIR / 'laws'
EOD_DIR = CORTEX_DIR / 'daily-summaries'
PROJECTS_DIR = CORTEX_DIR / 'projects'
CONTEXT_TTL_DAYS = 14


def load_laws():
    """Read law files (max 10), return list of one-liners."""
    if not LAWS_DIR.is_dir():
        return []
    law_files = sorted(LAWS_DIR.glob('*.txt'))[:10]
    laws = []
    for f in law_files:
        try:
            first_line = f.read_text().split('\n')[0].strip()
            if first_line:
                laws.append(first_line)
        except Exception:
            pass
    return laws


def check_new_day():
    """Compare today vs last session date. Returns (is_new_day, last_date)."""
    today = datetime.now().strftime('%Y-%m-%d')
    date_file = CORTEX_DIR / '.last-session-date'

    last_date = ""
    if date_file.exists():
        try:
            last_date = date_file.read_text().strip()
        except Exception:
            pass

    # Always update
    CORTEX_DIR.mkdir(parents=True, exist_ok=True)
    date_file.write_text(today)

    return today != last_date, last_date, today


def check_learn_pending():
    """Check if there are 50+ new observations since last analyze."""
    if (CORTEX_DIR / '.learn-pending').exists():
        return True, 50

    last_count = 0
    count_file = CORTEX_DIR / '.last-learn-count'
    if count_file.exists():
        try:
            last_count = int(count_file.read_text().strip())
        except Exception:
            pass

    total = 0
    if PROJECTS_DIR.is_dir():
        for obs_file in PROJECTS_DIR.glob('*/observations.jsonl'):
            try:
                with open(obs_file) as f:
                    total += sum(1 for _ in f)
            except Exception:
                pass

    new_obs = total - last_count
    return new_obs >= 50, new_obs


def check_maintenance():
    """Check distill (7d), audit (30d), validate (pending proposals)."""
    reminders = []

    # Distill: only surface when there are pending candidates (Sprint 6).
    # Auto-distill now handles decay/archive/promotion automatically; the
    # manual /cx-distill reminder fires only when candidates need human review.
    candidates_file = CORTEX_DIR / 'auto-distill-candidates.md'
    has_candidates = False
    if candidates_file.exists():
        try:
            content = candidates_file.read_text(encoding='utf-8').strip()
            has_candidates = bool(content)
        except Exception:
            pass
    if has_candidates:
        reminders.append("[MAINT] Run /cx-distill — promotion candidates pending review.")

    # Audit: monthly
    audit_file = CORTEX_DIR / '.last-audit'
    if not audit_file.exists() or _file_older_than(audit_file, 30):
        reminders.append("[MAINT] Run /cx-audit — 30+ days since last audit (duplicates, token overhead, cleanup).")

    # Validate: pending proposals
    proposals_file = CORTEX_DIR / 'proposals.json'
    if proposals_file.exists():
        try:
            with open(proposals_file) as f:
                proposals = json.load(f)
            pending = sum(1 for p in proposals if p.get('status', 'pending') == 'pending')
            if pending > 0:
                reminders.append(f"[ACTION] {pending} pending proposals. Run /cx-validate to review.")
        except Exception:
            pass

    return reminders


def _file_older_than(filepath, days):
    """Check if file modification time is older than N days."""
    try:
        mtime = os.path.getmtime(filepath)
        age_days = (time.time() - mtime) / 86400
        return age_days > days
    except Exception:
        return True


def inject_context_bridge(input_json):
    """Inject project context.md if fresh enough."""
    try:
        cwd = input_json.get('cwd', '')
        if not cwd or not os.path.isabs(cwd) or '..' in cwd or not os.path.isdir(cwd):
            return None
        cwd = os.path.realpath(cwd)  # Resolve symlinks

        project_id, project_root, remote = detect_project(cwd)
        if not project_id:
            return None

        context_file = PROJECTS_DIR / project_id / 'context.md'
        if not context_file.exists():
            return None

        # Check TTL
        age_days = (time.time() - os.path.getmtime(context_file)) / 86400
        if age_days >= CONTEXT_TTL_DAYS:
            return None

        # Read first 10 lines
        lines = []
        with open(context_file) as f:
            for i, line in enumerate(f):
                if i >= 10:
                    break
                lines.append(line.rstrip())

        content = ' '.join(lines).strip()
        if not content:
            return None

        return sanitize_injection(content, 2000)
    except Exception:
        return None


def inject_eod_resume():
    """Find and inject EOD Quick Resume. Returns (resume_text, priorities, eod_date) or None."""
    eod_last_read_file = CORTEX_DIR / '.eod-last-read'
    eod_last_read = ""
    if eod_last_read_file.exists():
        try:
            eod_last_read = eod_last_read_file.read_text().strip()
        except Exception:
            pass

    today = datetime.now().strftime('%Y-%m-%d')
    yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')

    eod_file = None
    eod_date = ""

    # Check today, yesterday, then most recent
    for candidate_date in [today, yesterday]:
        candidate = EOD_DIR / f'{candidate_date}.md'
        if candidate.exists():
            eod_file = candidate
            eod_date = candidate_date
            break

    if not eod_file and EOD_DIR.is_dir():
        md_files = sorted(EOD_DIR.glob('*.md'), reverse=True)
        if md_files:
            eod_file = md_files[0]
            eod_date = eod_file.stem

    if not eod_file or eod_last_read == eod_date:
        return None

    try:
        content = eod_file.read_text()
    except Exception:
        return None

    # Extract Quick Resume section
    resume_match = re.search(
        r'^## Quick Resume\s*\n(.*?)(?=^## |\Z)',
        content, re.MULTILINE | re.DOTALL
    )
    quick_resume = ""
    if resume_match:
        raw = resume_match.group(1).strip()
        # Clean: remove leading > quotes, collapse whitespace
        raw = re.sub(r'^[>\s]+', '', raw, flags=re.MULTILINE)
        quick_resume = ' '.join(raw.split())[:1000]

    # Extract "For tomorrow" bullets
    tomorrow_match = re.search(
        r'^### For tomorrow\s*\n(.*?)(?=^###|^##|^---|$)',
        content, re.MULTILINE | re.DOTALL
    )
    priorities = ""
    if tomorrow_match:
        bullets = re.findall(r'^- (.+)$', tomorrow_match.group(1), re.MULTILINE)
        priorities = ';'.join(bullets[:5])

    # Mark as read
    try:
        eod_last_read_file.write_text(eod_date)
    except Exception:
        pass

    return quick_resume, priorities, eod_date


def main():
    # Reset per-session token budget
    budget_file = CORTEX_DIR / '.session-token-budget'
    try:
        budget_file.unlink(missing_ok=True)
    except Exception:
        pass

    # Silent YAML normalization pass — repairs instinct files whose regex triggers
    # were written with invalid double-quote escapes (\., \s, \(). Idempotent.
    try:
        from yaml_normalize import normalize_all
        repaired = normalize_all()
        if repaired > 0:
            print(f'[cortex:yaml-normalize] repaired {repaired} instinct YAML file(s)', file=sys.stderr)
    except Exception:
        pass  # never block session start on normalization

    # Read stdin for hook data
    try:
        input_json = json.loads(sys.stdin.read())
    except Exception:
        input_json = {}

    # Build context string
    parts = []

    # 1. Laws
    laws = load_laws()
    if laws:
        law_lines = '\n'.join(f'- {law}' for law in laws)
        parts.append(f'CORTEX LAWS (follow always):\n{law_lines}')
    else:
        parts.append('CORTEX: No laws configured yet. Add .txt files to ~/.claude/cortex/laws/')

    # 1b. Commands hint
    parts.append(
        'Cortex commands: /cx-status /cx-analyze /cx-distill /cx-validate /cx-evolve '
        '/cx-dream /cx-audit /cx-eod /cx-gotcha /cx-downvote /cx-retro /cx-export '
        '/cx-backup /cx-restore /cx-router /cx-promote. Use /cx-status for system state.'
    )

    # 2. New day check
    is_new, last_date, today = check_new_day()
    if is_new and last_date:
        parts.append(f'\nNEW DAY (last session: {last_date}). Consider running /cx-analyze to detect patterns.')
    elif is_new:
        parts.append('\nNEW DAY (first session). Welcome to Cortex.')

    # 3. Learn-pending
    has_pending, count = check_learn_pending()
    if has_pending:
        parts.append(f'\nYou have {count}+ new observations. Run /cx-analyze to detect patterns.')

    # 3b. Maintenance reminders
    for reminder in check_maintenance():
        parts.append(f'\n{reminder}')

    # 3d. Auto-distill (Sprint 6 — runs once per 24h, idempotent)
    try:
        from distill_engine import run_auto_distill
        summary = run_auto_distill()
        if summary.get("decayed") or summary.get("archived") or summary.get("promoted") or summary.get("candidates"):
            line = f"[CORTEX] auto-distill: {summary['decayed']} decayed, {summary['archived']} archived, {summary['promoted']} promoted"
            if summary.get("candidates"):
                line += f", {summary['candidates']} candidate(s) — run /cx-distill to review"
            parts.append(f"\n{line}")
    except Exception:
        pass  # never block session-start on engine errors

    # 3c. Context bridge
    ctx = inject_context_bridge(input_json)
    if ctx:
        parts.append(f'\nPROJECT CONTEXT: {ctx}')

    # 4. EOD Resume
    eod_result = inject_eod_resume()
    if eod_result:
        quick_resume, priorities, eod_date = eod_result
        if quick_resume:
            sanitized = sanitize_injection(quick_resume, 1000)
            parts.append(f'\nEOD RESUME ({eod_date}): {sanitized}')
        if priorities:
            parts.append(f'PRIORITIES: {priorities}')
        parts.append(
            'IMPORTANT: Present the EOD resume and priorities to the user in your '
            'FIRST response. Do NOT wait for the user to ask. Greet, summarize '
            'yesterday, list priorities, ask where to start.'
        )

    # Output JSON
    context = '\n'.join(parts)
    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context
        }
    }
    print(json.dumps(output))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        if os.environ.get('CORTEX_DEBUG'):
            sys.stderr.write(f'[cortex:session-start] {e}\n')
    sys.exit(0)
