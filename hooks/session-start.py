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
    # Fallback if lib not available — preserves \t \n \r like the canonical impl
    def sanitize_injection(text, max_len=2000):
        if not isinstance(text, str):
            return ""
        clean = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', text)
        return clean[:max_len]
    def detect_project(cwd):
        return None, cwd, ""


HOME = os.environ.get('HOME', os.environ.get('USERPROFILE', '/tmp'))
CORTEX_DIR = Path(os.environ.get('CORTEX_DIR') or (Path(HOME) / '.claude' / 'cortex'))
LAWS_DIR = CORTEX_DIR / 'laws'
EOD_DIR = CORTEX_DIR / 'daily-summaries'
PROJECTS_DIR = CORTEX_DIR / 'projects'
CONTEXT_TTL_DAYS = 14

_config = {}
try:
    with open(CORTEX_DIR / 'memory.json') as _f:
        _config = json.load(_f).get('config', {})
except (FileNotFoundError, json.JSONDecodeError, OSError):
    pass

LEARN_THRESHOLD = _config.get('learn_threshold', 100)


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


def write_daily_snapshot(last_date):
    """Write aggregate stats for the day to daily-snapshots/YYYY-MM-DD.json. Called when check_new_day fires."""
    if not last_date:
        return
    snapshot_dir = CORTEX_DIR / 'daily-snapshots'
    try:
        snapshot_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        return

    snapshot_path = snapshot_dir / f'{last_date}.json'
    if snapshot_path.exists():
        return  # Already snapshotted

    # v3.28.5 — split observation counts: total_active is lifetime size of
    # observations.jsonl (used for capacity checks), on_date filters lines
    # whose `ts` starts with last_date (used for daily activity reports).
    # Pre-v3.28.5 the field was misleadingly named `observations` and held
    # the lifetime total, suggesting daily volume.
    stats = {
        'date': last_date,
        'observations_total_active': {},
        'observations_on_date': {},
        'proposals_count': 0,
        'instincts_global': 0,
        'instincts_project_total': 0,
        'laws_count': 0,
    }

    if PROJECTS_DIR.is_dir():
        for proj_dir in PROJECTS_DIR.iterdir():
            if not proj_dir.is_dir() or proj_dir.name.startswith('_'):
                continue
            obs_file = proj_dir / 'observations.jsonl'
            if obs_file.exists():
                try:
                    total_lifetime = 0
                    on_date = 0
                    with open(obs_file) as f:
                        for line in f:
                            total_lifetime += 1
                            # Cheap startswith check on raw line — skips JSON parse cost
                            if f'"ts":"{last_date}' in line:
                                on_date += 1
                    stats['observations_total_active'][proj_dir.name] = total_lifetime
                    stats['observations_on_date'][proj_dir.name] = on_date
                except OSError:
                    pass
            inst_dir = proj_dir / 'instincts'
            if inst_dir.is_dir():
                stats['instincts_project_total'] += sum(1 for _ in inst_dir.glob('*.yaml'))

    proposals_path = CORTEX_DIR / 'proposals.json'
    if proposals_path.exists():
        try:
            stats['proposals_count'] = len(json.loads(proposals_path.read_text()))
        except (json.JSONDecodeError, OSError):
            pass

    global_dir = CORTEX_DIR / 'instincts' / 'global'
    if global_dir.is_dir():
        stats['instincts_global'] = sum(1 for _ in global_dir.glob('*.yaml'))

    if LAWS_DIR.is_dir():
        stats['laws_count'] = sum(1 for _ in LAWS_DIR.glob('*.txt'))

    tmp = str(snapshot_path) + '.tmp'
    try:
        with open(tmp, 'w') as f:
            json.dump(stats, f, indent=2)
        os.replace(tmp, str(snapshot_path))
        os.chmod(str(snapshot_path), 0o600)
    except OSError as e:
        print(f'[cortex:daily-snapshot] write failed: {e}', file=sys.stderr)
        try:
            os.unlink(tmp)
        except OSError:
            pass


def check_learn_pending():
    """Check if there are LEARN_THRESHOLD+ new observations since last analyze."""
    if (CORTEX_DIR / '.learn-pending').exists():
        return True, LEARN_THRESHOLD

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
    return new_obs >= LEARN_THRESHOLD, new_obs


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

    # Validate: pending proposals.
    # v3.29.0 (Sprint 8 §4.10): the [ACTION] banner counts ONLY proposals in
    # the auto-validate whitelist (domains that distill_engine would actually
    # promote without human review). Human-gated domains (`correction`,
    # `user-preference`, `decision`, `workflow`, `coupling`, `agent-quality`)
    # accumulate quietly and surface via /cx-status --pipeline instead.
    # Pre-v3.29 every pending proposal triggered the nag, so HUMAN-gated
    # detectors caused a permanent "[ACTION] N pending" reminder even when
    # those proposals required the operator to think, not to push a button.
    proposals_file = CORTEX_DIR / 'proposals.json'
    if proposals_file.exists():
        try:
            with open(proposals_file) as f:
                proposals = json.load(f)
            # Import lazily — distill_engine pulls in regex_guard etc., which
            # we'd rather not load on every SessionStart unless we have
            # proposals to inspect.
            try:
                sys.path.insert(0, str(Path(__file__).parent / 'lib'))
                from distill_engine import VALIDATE_AUTO_DOMAINS as _AUTO
            except Exception:
                # Fallback: hard-coded list matching distill_engine §4.1.
                _AUTO = {'gotcha', 'pattern', 'error-recovery', 'agent-evolution'}
            pending_auto = sum(
                1 for p in proposals
                if isinstance(p, dict)
                and p.get('status', 'pending') == 'pending'
                and p.get('domain') in _AUTO
            )
            if pending_auto > 0:
                reminders.append(f"[ACTION] {pending_auto} pending proposals. Run /cx-validate to review.")
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

        # v3.31.0: read the full file (≤ 500 bytes by design) and wrap in a
        # [project-context] semantic tag. Newlines preserved (sanitize_injection
        # no longer strips them after the cortex_utils.py:24 fix).
        # Bounded read (4096 bytes) prevents memory blowup if a legacy file is
        # ever still around — sanitize_injection truncates further to 2000.
        with open(context_file) as f:
            content = f.read(4096).strip()
        if not content:
            return None

        tagged = f"[project-context]\n{content}"
        return sanitize_injection(tagged, 2000)
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

    # v3.31.0: wrap with [eod-summary YYYY-MM-DD] semantic tag
    tagged = f"[eod-summary {eod_date}]\n{quick_resume}" if quick_resume else quick_resume
    return tagged, priorities, eod_date


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

    # v3.25.0 — track whether anything in this SessionStart deserves explicit
    # surfacing to the user on the first response. Pre-v3.25.0 only the EOD
    # block carried that "present in first response" flag, so pipeline activity
    # (proposals validated, instincts promoted, evolve drafts ready) and
    # maintenance reminders ([ACTION]/[MAINT]) were silently injected as
    # additionalContext and the user only saw them if they ran /cx-status by
    # hand. Now any actionable signal — pending validate, pending distill,
    # promotions, evolve drafts, learn-pending, [ACTION]/[MAINT] reminders —
    # arms a single trailing IMPORTANT block telling the agent to surface it.
    user_actionable: list[str] = []

    # 1. Laws
    laws = load_laws()
    if laws:
        law_lines = '\n'.join(f'- {law}' for law in laws)
        parts.append(f'CORTEX LAWS (follow always):\n{law_lines}')
    else:
        parts.append('CORTEX: No laws configured yet. Add .txt files to ~/.claude/cortex/laws/')

    # 1b. Commands hint — keep this list in sync with commands/cx-*.md and
    # commands/cx-router.md. v3.25.0 added the four that were silently
    # missing: /cx-dashboard /cx-feedback /cx-feedback-auto /cx-timeline.
    parts.append(
        'Cortex commands: /cx-status /cx-dashboard /cx-analyze /cx-distill '
        '/cx-validate /cx-evolve /cx-dream /cx-timeline /cx-audit /cx-eod '
        '/cx-gotcha /cx-feedback /cx-feedback-auto /cx-downvote /cx-retro '
        '/cx-export /cx-backup /cx-restore /cx-router /cx-promote. '
        'Use /cx-status for system state.'
    )

    # 2. New day check
    is_new, last_date, today = check_new_day()
    if is_new and last_date:
        write_daily_snapshot(last_date)  # v3.28.0
        parts.append(f'\nNEW DAY (last session: {last_date}). Consider running /cx-analyze to detect patterns.')
    elif is_new:
        parts.append('\nNEW DAY (first session). Welcome to Cortex.')

    # 3. Learn-pending
    has_pending, count = check_learn_pending()
    if has_pending:
        msg = f'You have {count}+ new observations. Run /cx-analyze to detect patterns.'
        parts.append(f'\n{msg}')
        user_actionable.append(f'• {msg}')

    # 3b. Maintenance reminders
    for reminder in check_maintenance():
        parts.append(f'\n{reminder}')
        # [ACTION] and [MAINT] markers signal the user should know about it.
        if '[ACTION]' in reminder or '[MAINT]' in reminder:
            user_actionable.append(f'• {reminder.strip()}')

    # 3d. Knowledge pipeline summary (Sprint 7).
    # v3.29.0 (Sprint 8 §4.8): the CORTEX_AUTODISTILL_OFF kill switch lives
    # inside run_auto_distill itself, so it also gates the manual CLI
    # (`python3 distill_engine.py auto`), the test harness, and any future
    # caller — not just this SessionStart entry point.
    try:
        from distill_engine import run_auto_distill
        s = run_auto_distill()
        lines = []
        if s.get("validated"): lines.append(f"  ✓ Validated: {s['validated']} proposals → instincts")
        if s.get("decayed"):   lines.append(f"  · Decayed: {s['decayed']} instincts")
        if s.get("archived"):  lines.append(f"  · Archived: {s['archived']} stale instincts")
        if s.get("promoted"):  lines.append(f"  ✓ Promoted: {s['promoted']} instinct(s) → laws")
        if s.get("evolve_drafts"): lines.append(f"  ✓ Evolve drafts: {s['evolve_drafts']} skill(s) at evolved/skills/")
        if s.get("candidates"): lines.append(f"  ⚠ Pending review: {s['candidates']} law candidate(s) — run /cx-distill")
        if s.get("skipped_validate"): lines.append(f"  ⚠ Pending review: {s['skipped_validate']} proposal(s) need judgment — run /cx-validate")
        if lines:
            parts.append("\n[CORTEX KNOWLEDGE PIPELINE]\n" + "\n".join(lines))
            # Pipeline lines that move state (validated/promoted/evolve_drafts)
            # OR demand action (candidates/skipped_validate) are surfaced.
            for key, label in (
                ("validated",        "instincts auto-promoted"),
                ("promoted",         "laws auto-promoted"),
                ("evolve_drafts",    "skills ready to review at evolved/skills/ (run /cx-evolve)"),
                ("candidates",       "law candidates pending — run /cx-distill"),
                ("skipped_validate", "proposals need judgment — run /cx-validate"),
            ):
                v = s.get(key)
                if v:
                    user_actionable.append(f"• {v} {label}")
    except Exception:
        pass  # never block session-start on engine errors

    # 3c. Context bridge
    ctx = inject_context_bridge(input_json)
    if ctx:
        parts.append(f'\nPROJECT CONTEXT: {ctx}')

    # 4. EOD Resume — v3.31.0: tagged_resume already includes [eod-summary YYYY-MM-DD]\n
    eod_result = inject_eod_resume()
    if eod_result:
        tagged_resume, priorities, eod_date = eod_result
        if tagged_resume:
            sanitized = sanitize_injection(tagged_resume, 2000)
            parts.append(f'\n{sanitized}')
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
