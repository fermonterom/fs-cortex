#!/usr/bin/env python3
"""Dream Cycle — Knowledge maintenance modules for Cortex.

Modules:
  1. Jaccard dedup (Unicode-safe)
  2. Contradiction detection (EN+ES, safe pairs)
  3. Staleness scoring + auto-archive
  4. Regex validation for instinct triggers
  5. Health score calculation 0-100
  6. Cleanup: orphan projects, expired context, old archives
"""

import json
import os
import re
import time
import datetime


# ── Module 1: Jaccard Dedup ─────────────────────────────────────────


def jaccard_similarity(text_a, text_b):
    """Jaccard similarity with Unicode-safe tokenization."""
    def tokenize(text):
        tokens = re.findall(r'\b\w+\b', text.lower(), re.UNICODE)
        # CJK: tokenize by individual character
        cjk = re.findall(
            r'[\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff\uac00-\ud7af]', text
        )
        return set(tokens + cjk)

    set_a = tokenize(text_a)
    set_b = tokenize(text_b)
    if not set_a or not set_b:
        return 0.0
    intersection = set_a & set_b
    union = set_a | set_b
    return len(intersection) / len(union)


def dedup_instincts(instincts, threshold=0.80):
    """Remove duplicate instincts by Jaccard similarity on action field.
    Full pairwise comparison — checks against ALL kept items, not just first match."""
    keep = []
    for inst in instincts:
        matches = []
        for kept in keep:
            sim = jaccard_similarity(inst.get('action', ''), kept.get('action', ''))
            if sim >= threshold:
                matches.append(kept)
        if matches:
            # Keep highest confidence among all similar instincts
            best = max([inst] + matches, key=lambda x: x.get('confidence', 0))
            for m in matches:
                if m in keep:
                    keep.remove(m)
            if best not in keep:
                keep.append(best)
        else:
            keep.append(inst)
    return keep


# ── Module 2: Contradiction Detection ──────────────────────────────

# Safe pairs: avoid "do/don't" which false-positives on "document", "domain"
CONTRADICTION_PAIRS = [
    # EN pairs
    (r'\bmust\b', r'\bmust\s+not\b'),
    (r'\balways\b', r'\bnever\b'),
    (r'\benable\b', r'\bdisable\b'),
    (r'\ballow\b', r'\bblock\b'),
    (r'\brequire\b', r'\bforbid\b'),
    # ES pairs
    (r'\bsiempre\b', r'\bnunca\b'),
    (r'\bpermitir\b', r'\bprohibir\b'),
]


def detect_contradictions(instincts):
    """Find instinct pairs that contradict each other within the same domain."""
    contradictions = []
    for i, a in enumerate(instincts):
        for j, b in enumerate(instincts):
            if i >= j:
                continue
            if a.get('domain') != b.get('domain'):
                continue
            a_action = a.get('action', '')
            b_action = b.get('action', '')
            for pos_re, neg_re in CONTRADICTION_PAIRS:
                if (re.search(pos_re, a_action, re.I) and re.search(neg_re, b_action, re.I)) or \
                   (re.search(neg_re, a_action, re.I) and re.search(pos_re, b_action, re.I)):
                    contradictions.append({
                        'id_a': a.get('id', f'idx:{i}'),
                        'id_b': b.get('id', f'idx:{j}'),
                        'pair': (pos_re, neg_re),
                    })
    return contradictions


# ── Module 3: Staleness Scoring + Auto-Archive ─────────────────────


def staleness_score(instinct):
    """Score 0-100 based on age since last_seen.
    0 = fresh, 100 = completely stale.
    """
    last_seen = instinct.get('last_seen', instinct.get('created', ''))
    if not last_seen:
        return 100
    try:
        last = datetime.datetime.fromisoformat(last_seen.replace('Z', '+00:00'))
        age_days = (datetime.datetime.now(datetime.timezone.utc) - last).days
    except (ValueError, TypeError):
        return 100

    if age_days <= 7:
        return 0
    elif age_days <= 30:
        return int(30 * (age_days - 7) / 23)
    elif age_days <= 60:
        return 30 + int(30 * (age_days - 30) / 30)
    elif age_days <= 90:
        return 60 + int(30 * (age_days - 60) / 30)
    else:
        return min(100, 90 + (age_days - 90) // 10)


def apply_staleness_decay(instincts, archive_threshold=90):
    """Decay confidence based on staleness. Archive if score >= threshold."""
    active = []
    archived = []
    for inst in instincts:
        score = staleness_score(inst)
        if score >= archive_threshold:
            inst['archived'] = True
            inst['archive_reason'] = f'staleness_score={score}'
            archived.append(inst)
        else:
            # Linear decay: -0.05 per 30 days (matches cx-distill and docs)
            confidence = inst.get('confidence', 0.5)
            decay_per_30 = 0.05
            periods = score // 30  # staleness_score is in days
            new_conf = confidence - (decay_per_30 * periods)
            inst['confidence'] = round(max(0.10, new_conf), 4)
            active.append(inst)
    return active, archived


# ── Module 4: Regex Validation ─────────────────────────────────────


def validate_trigger_regex(pattern):
    """Validate instinct trigger regex for safety and correctness.
    Returns (is_valid, reason).
    """
    if not pattern or not isinstance(pattern, str):
        return False, "Empty or non-string trigger"
    if len(pattern) > 100:
        return False, f"Trigger too long ({len(pattern)} chars, max 100)"
    # Ban nested quantifiers (ReDoS)
    if re.search(r'\([^)]*[+*]\)[+*?]', pattern):
        return False, "Nested quantifiers (ReDoS risk)"
    # Ban excessive alternations
    if pattern.count('|') > 5:
        return False, "Too many alternations (max 5)"
    # Try compile
    try:
        re.compile(pattern)
    except re.error as e:
        return False, f"Invalid regex: {e}"
    return True, "OK"


# ── Module 5: Health Score ─────────────────────────────────────────


def calculate_health_score(stats):
    """Calculate knowledge health score 0-100.

    stats keys:
        total_instincts, active_instincts, stale_count,
        contradiction_count, duplicate_count, law_count,
        avg_confidence, last_distill_days, last_dream_days
    """
    score = 100

    # Staleness penalty: -2 per stale instinct
    score -= min(30, stats.get('stale_count', 0) * 2)

    # Contradiction penalty: -10 per contradiction pair
    score -= min(30, stats.get('contradiction_count', 0) * 10)

    # Duplicate penalty: -3 per duplicate
    score -= min(20, stats.get('duplicate_count', 0) * 3)

    # Maintenance penalty: overdue distill/dream
    if stats.get('last_distill_days', 999) > 14:
        score -= 10
    if stats.get('last_dream_days', 999) > 7:
        score -= 5

    # Bonus: laws indicate crystallized knowledge
    score += min(10, stats.get('law_count', 0) * 2)

    # Bonus: healthy confidence average
    avg_conf = stats.get('avg_confidence', 0)
    if avg_conf >= 0.60:
        score += 5

    return max(0, min(100, score))


# ── Module 6: Cleanup — Orphans, Expired Context, Old Archives ────


def detect_orphan_projects(cortex_dir):
    """Find orphan/stale projects in the cortex data directory.

    Detects:
      - dead_entry: registry entry whose directory no longer exists
      - orphan_dir: project directory not listed in registry
      - stale_project: last_seen > 90 days ago

    Returns list of dicts: {id, name, type, detail}
    """
    projects_dir = os.path.join(cortex_dir, "projects")
    registry_path = os.path.join(projects_dir, "registry.json")

    registry = {}
    try:
        with open(registry_path, "r") as f:
            registry = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []

    results = []
    now = time.time()
    stale_threshold = 90 * 86400  # 90 days in seconds

    # Check registry entries against filesystem
    for pid, meta in registry.items():
        proj_dir = os.path.join(projects_dir, pid)
        name = meta.get("name", pid)
        if not os.path.isdir(proj_dir):
            results.append({
                "id": pid,
                "name": name,
                "type": "dead_entry",
                "detail": "Registry entry but directory missing",
            })
            continue
        # Check staleness via last_seen
        last_seen = meta.get("last_seen", "")
        if last_seen:
            try:
                ls = datetime.datetime.fromisoformat(
                    last_seen.replace("Z", "+00:00")
                )
                age_s = now - ls.timestamp()
                if age_s > stale_threshold:
                    age_days = int(age_s / 86400)
                    results.append({
                        "id": pid,
                        "name": name,
                        "type": "stale_project",
                        "detail": f"Last seen {age_days} days ago",
                    })
            except (ValueError, TypeError):
                pass

    # Check filesystem dirs against registry (skip symlinks for safety)
    try:
        for entry in os.listdir(projects_dir):
            full = os.path.join(projects_dir, entry)
            if os.path.islink(full):
                continue
            if not os.path.isdir(full):
                continue
            if entry not in registry:
                results.append({
                    "id": entry,
                    "name": entry,
                    "type": "orphan_dir",
                    "detail": "Directory exists but not in registry",
                })
    except OSError:
        pass

    return results


def cleanup_expired_context(cortex_dir, ttl_days=14):
    """Find context.md files older than TTL.

    Returns list of dicts: {project_id, context_age_days, path}
    """
    projects_dir = os.path.join(cortex_dir, "projects")
    expired = []
    now = time.time()
    ttl_seconds = ttl_days * 86400

    try:
        for entry in os.listdir(projects_dir):
            entry_path = os.path.join(projects_dir, entry)
            if os.path.islink(entry_path):
                continue
            ctx_path = os.path.join(entry_path, "context.md")
            if os.path.isfile(ctx_path) and not os.path.islink(ctx_path):
                age = now - os.path.getmtime(ctx_path)
                if age > ttl_seconds:
                    expired.append({
                        "project_id": entry,
                        "context_age_days": int(age / 86400),
                        "path": ctx_path,
                    })
    except OSError:
        pass

    return expired


def consolidate_old_archives(cortex_dir, days=90):
    """Find old observation archive files that can be purged.

    Returns list of dicts: {project_id, file_count, total_bytes, files}
    """
    projects_dir = os.path.join(cortex_dir, "projects")
    results = []
    now = time.time()
    cutoff = days * 86400

    try:
        for entry in os.listdir(projects_dir):
            entry_path = os.path.join(projects_dir, entry)
            if os.path.islink(entry_path):
                continue
            archive_dir = os.path.join(entry_path, "observations.archive")
            if not os.path.isdir(archive_dir) or os.path.islink(archive_dir):
                continue
            old_files = []
            total_bytes = 0
            for fname in os.listdir(archive_dir):
                fpath = os.path.join(archive_dir, fname)
                if not os.path.isfile(fpath) or os.path.islink(fpath):
                    continue
                age = now - os.path.getmtime(fpath)
                if age > cutoff:
                    size = os.path.getsize(fpath)
                    old_files.append(fpath)
                    total_bytes += size
            if old_files:
                results.append({
                    "project_id": entry,
                    "file_count": len(old_files),
                    "total_bytes": total_bytes,
                    "files": old_files,
                })
    except OSError:
        pass

    return results
