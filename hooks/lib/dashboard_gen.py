# CORTEX-MANAGED — do not edit manually, updated by install.sh/install.ps1
"""Cortex Dashboard Generator — visual HTML report with Fersora brand.

Reads the entire Cortex state (laws, instincts, reflexes, projects, tracking,
memory, timeline) and renders a self-contained HTML file at
~/.claude/cortex/dashboard.html. Styled with the fs-brand visual identity.

Invoked by the /cx-dashboard command. Exit 0 on success, non-zero on error.
Cross-platform (Python 3.8+). No external dependencies.
"""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone
from html import escape
from pathlib import Path

import os as _os
CORTEX_DIR = Path(_os.environ.get("CORTEX_DIR") or (Path.home() / ".claude" / "cortex"))


# ─── Data readers ──────────────────────────────────────────────────────────


def _iso_days_ago(iso: str) -> int | None:
    """Days between an ISO timestamp and now. None if unparseable."""
    if not iso:
        return None
    try:
        s = str(iso).replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - dt).days
    except Exception:
        return None


def _human_date(iso: str) -> str:
    d = _iso_days_ago(iso)
    if d is None:
        return "—"
    if d == 0:
        return "today"
    if d == 1:
        return "yesterday"
    if d < 7:
        return f"{d}d ago"
    if d < 30:
        return f"{d // 7}w ago"
    if d < 365:
        return f"{d // 30}mo ago"
    return f"{d // 365}y ago"


def _read_json(path: Path, default):
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def _parse_yaml_frontmatter(content: str) -> dict:
    """Minimal YAML frontmatter parser — only top-level key: value lines."""
    fields: dict = {}
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
    body = m.group(1) if m else content
    for line in body.splitlines():
        if ":" not in line or line.strip().startswith("#"):
            continue
        k, _, v = line.partition(":")
        key = k.strip()
        val = v.strip().strip("\"'")
        if key:
            fields[key] = val
    return fields


def read_laws() -> list[dict]:
    laws = []
    laws_dir = CORTEX_DIR / "laws"
    if not laws_dir.exists():
        return laws
    for p in sorted(laws_dir.glob("*.txt")):
        try:
            text = p.read_text(encoding="utf-8").strip()
        except Exception:
            continue
        laws.append({"id": p.stem, "text": text[:240]})
    return laws


def read_instincts() -> list[dict]:
    instincts = []
    for base in [
        CORTEX_DIR / "instincts" / "global",
        *[d / "instincts" for d in (CORTEX_DIR / "projects").glob("*") if d.is_dir()],
    ]:
        if not base.exists():
            continue
        for p in sorted(base.glob("*.yaml")):
            try:
                fields = _parse_yaml_frontmatter(p.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not fields.get("id"):
                continue
            try:
                conf = float(fields.get("confidence", "0") or 0)
            except Exception:
                conf = 0.0
            instincts.append(
                {
                    "id": fields.get("id"),
                    "domain": fields.get("domain", "general"),
                    "confidence": conf,
                    "scope": fields.get("scope", "global"),
                    "action": fields.get("action", ""),
                    "last_seen": fields.get("last_seen", ""),
                }
            )
    return instincts


def read_reflexes() -> list[dict]:
    data = _read_json(CORTEX_DIR / "reflexes.json", {"reflexes": []})
    return data.get("reflexes", []) if isinstance(data, dict) else []


def read_projects() -> list[dict]:
    """Read project registry and collapse duplicates by root path.

    Cortex can end up with multiple hashes for the same physical project when
    `git remote` is added/changed after first observation: the first hash is
    derived from the root path (no remote), the second from the remote URL.
    We dedupe by root here so the dashboard shows one row per physical
    project, summing obs/inst counts and keeping the most recent last_seen.
    The `duplicates` field surfaces the extra hashes so users can run
    /cx-dream to consolidate them permanently.
    """
    reg = _read_json(CORTEX_DIR / "projects" / "registry.json", {})
    if not isinstance(reg, dict):
        return []

    # First pass: collect per-hash data
    rows = []
    for h, meta in reg.items():
        proj_dir = CORTEX_DIR / "projects" / h
        obs_file = proj_dir / "observations.jsonl"
        inst_dir = proj_dir / "instincts"
        obs_count = 0
        if obs_file.exists():
            try:
                with obs_file.open("r", encoding="utf-8", errors="ignore") as f:
                    obs_count = sum(1 for _ in f)
            except Exception:
                obs_count = 0
        inst_count = len(list(inst_dir.glob("*.yaml"))) if inst_dir.exists() else 0
        if not isinstance(meta, dict):
            meta = {}
        rows.append(
            {
                "hash": h[:12],
                "name": meta.get("name") or h[:12],
                "root": meta.get("root") or "—",
                "last_seen": meta.get("last_seen") or "",
                "obs": obs_count,
                "inst": inst_count,
                "remote": meta.get("remote") or "",
            }
        )

    # Second pass: merge duplicates by normalized root (case-insensitive, strip trailing /)
    def norm(path: str) -> str:
        return path.rstrip("/").lower() if path and path != "—" else ""

    merged: dict[str, dict] = {}
    for r in rows:
        key = norm(r["root"]) or f"__hash__{r['hash']}"
        if key not in merged:
            merged[key] = {**r, "duplicates": []}
            continue
        # Collapse: canonical = entry with remote (or with most recent activity)
        existing = merged[key]
        incoming_days = _iso_days_ago(r["last_seen"])
        existing_days = _iso_days_ago(existing["last_seen"])
        prefer_incoming = (
            bool(r["remote"]) and not existing["remote"]
        ) or (
            (incoming_days is not None and existing_days is not None and incoming_days < existing_days)
        )
        if prefer_incoming:
            canonical, other = r, existing
        else:
            canonical, other = existing, r
        merged[key] = {
            **canonical,
            "obs": existing["obs"] + r["obs"],
            "inst": existing["inst"] + r["inst"],
            "duplicates": existing.get("duplicates", []) + [other["hash"]],
        }

    out = list(merged.values())
    out.sort(key=lambda p: _iso_days_ago(p["last_seen"]) or 9999)
    return out


def read_tracking_top(limit: int = 10) -> list[dict]:
    data = _read_json(CORTEX_DIR / "instinct-tracking.json", {})
    if not isinstance(data, dict):
        return []
    rows = []
    for k, v in data.items():
        if not isinstance(v, dict):
            continue
        rows.append(
            {
                "id": k,
                "count": int(v.get("count", 0) or 0),
                "sessions": len(v.get("sessions", []) or []),
                "first_seen": v.get("first_seen", ""),
                "last_seen": v.get("last_seen", ""),
            }
        )
    rows.sort(key=lambda r: -r["count"])
    return rows[:limit]


def read_timeline(limit: int = 20) -> list[str]:
    p = CORTEX_DIR / "knowledge-log.md"
    if not p.exists():
        return []
    try:
        lines = [
            line.strip() for line in p.read_text(encoding="utf-8").splitlines() if line.strip()
        ]
    except Exception:
        return []
    return lines[-limit:][::-1]


def read_evolved_counts() -> dict:
    base = CORTEX_DIR / "evolved"
    out = {k: 0 for k in ("skills", "commands", "rules", "agents")}
    if not base.exists():
        return out
    for k in out:
        d = base / k
        if d.exists():
            out[k] = len([x for x in d.iterdir() if x.is_file()])
    return out


def read_memory() -> dict:
    return _read_json(CORTEX_DIR / "memory.json", {}) or {}


# ─── HTML rendering ────────────────────────────────────────────────────────


def _confidence_tier(c: float) -> tuple[str, str]:
    if c >= 0.90:
        return ("LAW", "fersora")
    if c >= 0.70:
        return ("INSTINCT", "lavender")
    if c >= 0.50:
        return ("PATTERN", "orange")
    if c >= 0.30:
        return ("HYPOTHESIS", "muted")
    return ("OBSERVATION", "muted")


def _render_laws(laws: list[dict]) -> str:
    if not laws:
        return '<p class="empty">No laws yet. Run /cx-distill to promote mature instincts.</p>'
    items = []
    for law in laws:
        items.append(
            f'<div class="item item-law"><span class="item-id">{escape(law["id"])}</span>'
            f'<span class="item-text">{escape(law["text"])}</span></div>'
        )
    return '<div class="items">' + "".join(items) + "</div>"


def _render_instincts(instincts: list[dict]) -> str:
    if not instincts:
        return '<p class="empty">No instincts yet. Work normally — Cortex will detect patterns automatically.</p>'
    # group by tier
    tiers = {"LAW": [], "INSTINCT": [], "PATTERN": [], "HYPOTHESIS": [], "OBSERVATION": []}
    for i in instincts:
        tier, _ = _confidence_tier(i["confidence"])
        tiers[tier].append(i)
    html_parts = []
    for tier in ("LAW", "INSTINCT", "PATTERN", "HYPOTHESIS", "OBSERVATION"):
        rows = tiers[tier]
        if not rows:
            continue
        html_parts.append(f'<h4 class="tier tier-{tier.lower()}">{tier} ({len(rows)})</h4>')
        html_parts.append('<table class="data"><thead><tr><th>ID</th><th>Domain</th><th>Confidence</th><th>Last seen</th></tr></thead><tbody>')
        for i in sorted(rows, key=lambda x: -x["confidence"])[:15]:
            html_parts.append(
                f"<tr><td><code>{escape(i['id'])}</code></td>"
                f'<td><span class="tag">{escape(i["domain"])}</span></td>'
                f"<td>{i['confidence']:.2f}</td>"
                f"<td>{escape(_human_date(i['last_seen']))}</td></tr>"
            )
        html_parts.append("</tbody></table>")
    return "".join(html_parts)


def _reflex_health(fires: int, useful: int, noise: int) -> str:
    """v3.18.0+ health classification — see cx-status --reflexes spec."""
    if fires < 10:
        return "unknown"
    if noise >= 3:
        return "NOISY"
    if noise in (1, 2):
        return "borderline"
    if useful >= 10:
        return "healthy"
    return "no-data"


def _render_reflexes(reflexes: list[dict]) -> str:
    if not reflexes:
        return '<p class="empty">No reflexes configured.</p>'
    rows = []
    active = 0
    total_fires = 0
    never = 0
    health_counts = {"healthy": 0, "borderline": 0, "NOISY": 0, "unknown": 0, "no-data": 0}
    for r in reflexes:
        enabled = bool(r.get("enabled", False))
        if enabled:
            active += 1
        fires = int(r.get("fireCount", 0) or 0)
        useful = int(r.get("usefulCount", 0) or 0)
        noise = int(r.get("noiseCount", 0) or 0)
        total_fires += fires
        if fires == 0:
            never += 1
        health = _reflex_health(fires, useful, noise)
        health_counts[health] = health_counts.get(health, 0) + 1
        last = _human_date(r.get("lastFired", ""))
        sev = r.get("severity", "medium")
        badge = f'<span class="sev sev-{escape(sev)}">{escape(sev)}</span>'
        en_badge = '<span class="pill on">on</span>' if enabled else '<span class="pill off">off</span>'
        fires_cell = f"{fires}" if fires > 0 else '<span class="never">never</span>'
        useful_cell = f"{useful}" if useful > 0 else '<span class="never">0</span>'
        noise_cell = f"{noise}" if noise > 0 else '<span class="never">0</span>'
        health_cell = f'<span class="health health-{escape(health)}">{escape(health)}</span>'
        rows.append(
            f"<tr><td><code>{escape(r.get('id', ''))}</code></td>"
            f"<td><code class='matcher'>{escape(str(r.get('matcher', ''))[:40])}</code></td>"
            f"<td>{badge}</td>"
            f"<td>{en_badge}</td>"
            f"<td>{fires_cell}</td>"
            f"<td>{useful_cell}</td>"
            f"<td>{noise_cell}</td>"
            f"<td>{health_cell}</td>"
            f"<td>{escape(last)}</td></tr>"
        )
    summary = (
        f'<p class="summary">Active: <strong>{active}/{len(reflexes)}</strong> · '
        f'Total fires: <strong>{total_fires}</strong> · '
        f'Healthy: <strong>{health_counts["healthy"]}</strong> · '
        f'Borderline: <strong>{health_counts["borderline"]}</strong> · '
        f'<span class="health-NOISY-text">NOISY: <strong>{health_counts["NOISY"]}</strong></span> · '
        f'Unknown: <strong>{health_counts["unknown"]}</strong></p>'
    )
    table = (
        '<table class="data"><thead><tr>'
        "<th>ID</th><th>Matcher</th><th>Severity</th><th>Status</th>"
        "<th>Fires</th><th>Useful</th><th>Noise</th><th>Health</th><th>Last fired</th>"
        "</tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
    )
    return summary + table


def _render_projects(projects: list[dict]) -> str:
    if not projects:
        return '<p class="empty">No projects registered yet.</p>'
    rows = []
    dup_count = 0
    for p in projects:
        dups = p.get("duplicates") or []
        dup_badge = ""
        if dups:
            dup_count += len(dups)
            dup_badge = (
                f' <span class="dup-badge" title="Merged from extra hash(es): '
                f'{escape(", ".join(dups))}. Run /cx-dream to consolidate permanently.">'
                f"+{len(dups)} dup</span>"
            )
        rows.append(
            f"<tr><td><strong>{escape(p['name'])}</strong>{dup_badge}</td>"
            f"<td><code>{escape(p['root'])}</code></td>"
            f"<td>{escape(_human_date(p['last_seen']))}</td>"
            f'<td class="num">{p["obs"]}</td>'
            f'<td class="num">{p["inst"]}</td></tr>'
        )
    warning = ""
    if dup_count > 0:
        warning = (
            f'<p class="summary" style="color: var(--orange);">'
            f"⚠ Detected <strong>{dup_count}</strong> duplicate project hash(es) "
            f"(same root, different hashes — likely from a git remote added/changed after first observation). "
            f"Counts below are already merged. Run <code>/cx-dream</code> to consolidate permanently.</p>"
        )
    return warning + (
        '<table class="data"><thead><tr>'
        "<th>Name</th><th>Root</th><th>Last seen</th><th>OBS</th><th>INST</th>"
        "</tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
    )


def _render_tracking(rows: list[dict]) -> str:
    if not rows:
        return '<p class="empty">No activation data yet. Cortex starts tracking on next tool use.</p>'
    trs = []
    for r in rows:
        trs.append(
            f"<tr><td><code>{escape(r['id'])}</code></td>"
            f'<td class="num"><strong>{r["count"]}</strong></td>'
            f'<td class="num">{r["sessions"]}</td>'
            f"<td>{escape(_human_date(r['first_seen']))}</td>"
            f"<td>{escape(_human_date(r['last_seen']))}</td></tr>"
        )
    return (
        '<table class="data"><thead><tr>'
        "<th>ID</th><th>Activations</th><th>Sessions</th><th>First</th><th>Last</th>"
        "</tr></thead><tbody>" + "".join(trs) + "</tbody></table>"
    )


def _render_timeline(lines: list[str]) -> str:
    if not lines:
        return '<p class="empty">No events logged yet.</p>'
    items = []
    for line in lines:
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 4:
            date, event, target, detail = parts[:4]
            items.append(
                f'<li><span class="tl-date">{escape(date)}</span>'
                f'<span class="tl-event tl-{escape(event)}">{escape(event)}</span>'
                f'<code class="tl-target">{escape(target)}</code>'
                f'<span class="tl-detail">{escape(detail)}</span></li>'
            )
        else:
            items.append(f"<li><code>{escape(line)}</code></li>")
    return '<ul class="timeline">' + "".join(items) + "</ul>"


def _health_score(laws, instincts, reflexes, projects) -> tuple[int, str]:
    score = 100
    if not laws:
        score -= 10
    if len(instincts) > 50:
        score -= 10
    never = sum(1 for r in reflexes if int(r.get("fireCount", 0) or 0) == 0)
    if never > 3:
        score -= min(15, never * 3)
    stale_projects = sum(
        1 for p in projects if (_iso_days_ago(p["last_seen"]) or 0) > 90
    )
    if stale_projects > 2:
        score -= 10
    score = max(0, min(100, score))
    label = "EXCELLENT" if score >= 85 else "HEALTHY" if score >= 70 else "ATTENTION" if score >= 50 else "NEEDS WORK"
    return score, label


# ─── HTML template ─────────────────────────────────────────────────────────


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cortex Dashboard — v{version}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Merriweather:wght@400;700;800;900&family=Open+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root {{
  --bg: #E8EDF6;
  --surface: #FAFCFF;
  --recessed: #F0F4FA;
  --fersora: #B2CE38;
  --fersora-dark: #7A9B1A;
  --lavender: #98B4E0;
  --orange: #E8842A;
  --red: #DC3545;
  --green: #1E9B50;
  --dark: #1A202C;
  --heading: #212121;
  --body: #444649;
  --muted: #718096;
  --border: rgba(0,0,0,0.08);
}}
*, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{
  font-family: 'Open Sans', sans-serif;
  color: var(--body);
  background: var(--bg);
  background-image:
    radial-gradient(ellipse at 20% 10%, rgba(178,206,56,0.06) 0%, transparent 60%),
    radial-gradient(ellipse at 80% 90%, rgba(152,180,224,0.08) 0%, transparent 60%);
  line-height: 1.65;
  font-size: 15px;
  -webkit-font-smoothing: antialiased;
}}
h1, h2, h3, h4, h5 {{ font-family: 'Merriweather', serif; color: var(--heading); }}
code, pre, .mono {{ font-family: 'JetBrains Mono', monospace; }}

.nav {{
  position: sticky; top: 0; z-index: 100;
  background: var(--dark);
  overflow-x: auto; scrollbar-width: none;
  padding: 0 20px;
}}
.nav::-webkit-scrollbar {{ display: none; }}
.nav-inner {{
  max-width: 1100px; margin: 0 auto;
  display: flex; align-items: center; gap: 0;
  min-width: max-content;
}}
@media (min-width: 769px) {{ .nav {{ padding: 0 40px; }} }}
.nav-logo {{ height: 28px; margin-right: 24px; flex-shrink: 0; }}
.nav a {{
  font-size: 12px; font-weight: 600;
  color: rgba(255,255,255,0.55);
  text-decoration: none;
  padding: 14px 10px;
  white-space: nowrap;
  border-bottom: 2px solid transparent;
  transition: color 0.2s, border-color 0.2s;
}}
.nav a:hover, .nav a.active {{
  color: var(--fersora);
  border-bottom-color: var(--fersora);
}}

.container {{ max-width: 1100px; margin: 0 auto; padding: 0 20px 60px; }}
@media (min-width: 769px) {{ .container {{ padding: 0 40px 80px; }} }}

.hero {{ padding: 40px 0 24px; }}
@media (min-width: 769px) {{ .hero {{ padding: 64px 0 40px; }} }}
.hero-tag {{
  display: inline-block; font-family: 'JetBrains Mono', monospace;
  font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 1.5px;
  color: var(--fersora-dark); background: rgba(178,206,56,0.12);
  padding: 6px 12px; border-radius: 6px; margin-bottom: 16px;
}}
.hero h1 {{
  font-weight: 900; font-size: clamp(28px, 5vw, 44px); line-height: 1.15;
  color: var(--heading); margin-bottom: 12px;
}}
.hero .lead {{ color: var(--muted); font-size: 16px; max-width: 680px; }}

.stats-row {{
  display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin-top: 32px;
}}
@media (min-width: 769px) {{ .stats-row {{ grid-template-columns: repeat(4, 1fr); }} }}
.stat {{
  background: var(--surface); border-radius: 14px; padding: 20px;
  box-shadow: 0 2px 12px rgba(0,0,0,0.04); border: 1px solid var(--border);
}}
.stat-num {{
  font-family: 'Merriweather', serif; font-weight: 900; font-size: 38px;
  color: var(--heading); line-height: 1;
}}
.stat-label {{
  display: block; margin-top: 8px; font-size: 12px; text-transform: uppercase;
  letter-spacing: 1px; color: var(--muted); font-weight: 600;
}}
.stat.highlight {{ border: 2px solid var(--fersora); box-shadow: 0 4px 20px rgba(178,206,56,0.18); }}
.stat.highlight .stat-num {{ color: var(--fersora-dark); }}

.health-badge {{
  display: inline-flex; align-items: center; gap: 10px; margin-top: 16px;
  padding: 10px 18px; border-radius: 24px; font-weight: 600; font-size: 14px;
}}
.health-EXCELLENT {{ background: rgba(30,155,80,0.12); color: var(--green); }}
.health-HEALTHY {{ background: rgba(178,206,56,0.14); color: var(--fersora-dark); }}
.health-ATTENTION {{ background: rgba(232,132,42,0.14); color: var(--orange); }}
.health-NEEDS {{ background: rgba(220,53,69,0.12); color: var(--red); }}

section.panel {{
  background: var(--surface); border-radius: 14px; padding: 28px;
  box-shadow: 0 2px 12px rgba(0,0,0,0.04); border: 1px solid var(--border);
  margin-top: 24px;
}}
.section-header {{ display: flex; align-items: center; gap: 14px; margin-bottom: 20px; }}
.section-num {{
  width: 30px; height: 30px; border-radius: 8px;
  background: var(--fersora); color: var(--dark);
  display: grid; place-items: center; font-family: 'JetBrains Mono', monospace;
  font-weight: 700; font-size: 14px; flex-shrink: 0;
}}
.section-header h2 {{ font-size: 22px; font-weight: 700; }}

.items {{ display: grid; gap: 10px; }}
.item {{
  background: var(--recessed); border-radius: 10px; padding: 14px 16px;
  border-left: 3px solid var(--fersora);
}}
.item-id {{
  display: inline-block; font-family: 'JetBrains Mono', monospace;
  font-size: 11px; font-weight: 600; color: var(--fersora-dark);
  text-transform: uppercase; letter-spacing: 1px; margin-bottom: 6px;
}}
.item-text {{ display: block; font-size: 14px; color: var(--body); }}

.tier {{ font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: 1.5px; margin: 20px 0 10px; }}
.tier-law {{ color: var(--fersora-dark); }}
.tier-instinct {{ color: var(--lavender); }}
.tier-pattern {{ color: var(--orange); }}
.tier-hypothesis, .tier-observation {{ color: var(--muted); }}

table.data {{
  width: 100%; border-collapse: collapse; margin-top: 8px;
  font-size: 13px;
}}
table.data th, table.data td {{
  padding: 10px 12px; text-align: left;
  border-bottom: 1px solid var(--border);
}}
table.data th {{
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 1px; color: var(--muted); background: var(--recessed);
}}
table.data td.num {{ text-align: right; font-family: 'JetBrains Mono', monospace; }}
table.data code {{ font-size: 12px; color: var(--dark); background: var(--recessed); padding: 2px 6px; border-radius: 4px; }}
table.data code.matcher {{ color: var(--fersora-dark); }}

.tag {{
  display: inline-block; font-family: 'JetBrains Mono', monospace;
  font-size: 10px; padding: 2px 8px; border-radius: 12px;
  background: rgba(152,180,224,0.18); color: var(--lavender); font-weight: 600;
}}
.sev {{ display: inline-block; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: 600; text-transform: uppercase; }}
.sev-critical {{ background: rgba(220,53,69,0.12); color: var(--red); }}
.sev-high {{ background: rgba(232,132,42,0.14); color: var(--orange); }}
.sev-medium {{ background: rgba(178,206,56,0.14); color: var(--fersora-dark); }}
.sev-low {{ background: rgba(113,128,150,0.14); color: var(--muted); }}
.pill {{ display: inline-block; font-size: 11px; padding: 2px 8px; border-radius: 10px; font-weight: 600; }}
.pill.on {{ background: rgba(30,155,80,0.14); color: var(--green); }}
.pill.off {{ background: rgba(113,128,150,0.14); color: var(--muted); }}
.never {{ color: var(--muted); font-style: italic; font-size: 12px; }}
.health {{ display: inline-block; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: 600; text-transform: lowercase; }}
.health-healthy {{ background: rgba(30,155,80,0.14); color: var(--green); }}
.health-borderline {{ background: rgba(232,132,42,0.14); color: var(--orange); }}
.health-NOISY {{ background: rgba(220,53,69,0.18); color: var(--red); text-transform: uppercase; font-weight: 700; }}
.health-unknown {{ background: rgba(113,128,150,0.14); color: var(--muted); }}
.health-no-data {{ background: rgba(113,128,150,0.10); color: var(--muted); font-style: italic; }}
.health-NOISY-text {{ color: var(--red); font-weight: 600; }}
.dup-badge {{
  display: inline-block; font-family: 'JetBrains Mono', monospace;
  font-size: 10px; padding: 2px 7px; border-radius: 10px;
  background: rgba(232,132,42,0.14); color: var(--orange); font-weight: 600;
  margin-left: 6px; cursor: help;
}}
.summary {{ margin-bottom: 12px; color: var(--muted); font-size: 13px; }}
.empty {{ color: var(--muted); font-style: italic; padding: 14px 0; }}

.timeline {{ list-style: none; padding: 0; display: grid; gap: 10px; }}
.timeline li {{
  background: var(--recessed); padding: 10px 14px; border-radius: 8px;
  display: grid; grid-template-columns: 110px 140px 1fr auto; gap: 12px;
  font-size: 13px; align-items: center;
}}
@media (max-width: 768px) {{
  .timeline li {{ grid-template-columns: 1fr; gap: 4px; padding: 10px; }}
}}
.tl-date {{ font-family: 'JetBrains Mono', monospace; font-size: 11px; color: var(--muted); }}
.tl-event {{
  font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: 600;
  padding: 2px 8px; border-radius: 6px; text-transform: uppercase; letter-spacing: 1px;
  justify-self: start; background: var(--lavender); color: white;
}}
.tl-promoted, .tl-promote {{ background: var(--fersora); color: var(--dark); }}
.tl-archived, .tl-archive-purged {{ background: var(--muted); color: white; }}
.tl-context-cleaned, .tl-orphan-removed {{ background: var(--orange); color: white; }}
.tl-downvoted {{ background: var(--red); color: white; }}
.tl-target {{ font-size: 12px; color: var(--dark); background: transparent; padding: 0; }}
.tl-detail {{ font-size: 12px; color: var(--muted); }}

.footer {{
  margin-top: 80px; padding-top: 32px; border-top: 1px solid var(--border);
  text-align: center; color: var(--muted); font-size: 13px;
}}
.footer-logo {{ height: 28px; margin-bottom: 14px; filter: brightness(0.2); }}
.footer .name {{ font-family: 'Merriweather', serif; font-weight: 700; color: var(--heading); }}
.footer .company {{ color: var(--fersora-dark); font-weight: 600; }}
.footer a {{ color: var(--fersora-dark); text-decoration: none; }}
.footer a:hover {{ text-decoration: underline; }}
.footer .meta {{ margin-top: 10px; font-size: 12px; }}
</style>
</head>
<body>

<div class="nav">
  <div class="nav-inner">
    <img class="nav-logo" src="https://fersora.com/wp-content/uploads/2023/12/Logo-Fersora-Blanco-con-color-y-transparente-300x80.png" alt="Fersora">
    <a href="#overview" class="active">Overview</a>
    <a href="#laws">Laws</a>
    <a href="#instincts">Instincts</a>
    <a href="#reflexes">Reflexes</a>
    <a href="#projects">Projects</a>
    <a href="#tracking">Tracking</a>
    <a href="#timeline">Timeline</a>
  </div>
</div>

<div class="container">

  <section class="hero" id="overview">
    <span class="hero-tag">fs-cortex · v{version}</span>
    <h1>Cortex Dashboard</h1>
    <p class="lead">Estado completo del sistema de aprendizaje continuo — laws, instincts, reflexes, projects y actividad reciente. Generado el {ts}.</p>

    <div class="stats-row">
      <div class="stat highlight">
        <div class="stat-num">{n_laws}</div>
        <span class="stat-label">Laws</span>
      </div>
      <div class="stat">
        <div class="stat-num">{n_instincts}</div>
        <span class="stat-label">Instincts</span>
      </div>
      <div class="stat">
        <div class="stat-num">{n_reflexes}</div>
        <span class="stat-label">Reflexes</span>
      </div>
      <div class="stat">
        <div class="stat-num">{n_projects}</div>
        <span class="stat-label">Projects</span>
      </div>
    </div>

    <div class="health-badge health-{health_class}">System health: {health_score}/100 — {health_label}</div>
  </section>

  <section class="panel" id="laws">
    <div class="section-header"><div class="section-num">1</div><h2>Laws <span style="font-weight: 400; color: var(--muted); font-size: 14px;">— always loaded (SessionStart)</span></h2></div>
    {laws_html}
  </section>

  <section class="panel" id="instincts">
    <div class="section-header"><div class="section-num">2</div><h2>Instincts <span style="font-weight: 400; color: var(--muted); font-size: 14px;">— confidence-gated (PreToolUse)</span></h2></div>
    {instincts_html}
  </section>

  <section class="panel" id="reflexes">
    <div class="section-header"><div class="section-num">3</div><h2>Reflexes <span style="font-weight: 400; color: var(--muted); font-size: 14px;">— deterministic pre-tool rules</span></h2></div>
    {reflexes_html}
  </section>

  <section class="panel" id="projects">
    <div class="section-header"><div class="section-num">4</div><h2>Projects</h2></div>
    {projects_html}
  </section>

  <section class="panel" id="tracking">
    <div class="section-header"><div class="section-num">5</div><h2>Top activations</h2></div>
    {tracking_html}
  </section>

  <section class="panel" id="timeline">
    <div class="section-header"><div class="section-num">6</div><h2>Recent events</h2></div>
    {timeline_html}
  </section>

  <footer class="footer">
    <img class="footer-logo" src="https://fersora.com/wp-content/uploads/2023/12/Logo-Fersora-Blanco-con-color-y-transparente-300x80.png" alt="Fersora">
    <div class="name">Fernando Montero</div>
    <div class="company">Fersora Solutions</div>
    <div><a href="mailto:info@fersora.com">info@fersora.com</a> · <a href="https://fersora.com">fersora.com</a></div>
    <div class="meta">fs-cortex v{version} · Cortex Dashboard · Generated {ts}</div>
  </footer>

</div>

<script>
// Scroll spy for nav
const links = document.querySelectorAll('.nav a');
const sections = Array.from(links).map(a => document.querySelector(a.getAttribute('href'))).filter(Boolean);
const observer = new IntersectionObserver((entries) => {{
  entries.forEach(e => {{
    if (e.isIntersecting) {{
      const id = '#' + e.target.id;
      links.forEach(l => l.classList.toggle('active', l.getAttribute('href') === id));
    }}
  }});
}}, {{ rootMargin: '-40% 0px -55% 0px' }});
sections.forEach(s => observer.observe(s));
</script>

</body>
</html>
"""


def generate(output_path: Path | None = None) -> Path:
    laws = read_laws()
    instincts = read_instincts()
    reflexes = read_reflexes()
    projects = read_projects()
    tracking = read_tracking_top(10)
    timeline = read_timeline(20)
    memory = read_memory()

    version = (memory.get("version") if isinstance(memory, dict) else "") or "—"
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")
    score, label = _health_score(laws, instincts, reflexes, projects)
    health_class = label.split()[0]  # 'NEEDS WORK' → 'NEEDS'

    html = HTML_TEMPLATE.format(
        version=escape(version),
        ts=escape(ts),
        n_laws=len(laws),
        n_instincts=len(instincts),
        n_reflexes=len(reflexes),
        n_projects=len(projects),
        health_score=score,
        health_label=label,
        health_class=health_class,
        laws_html=_render_laws(laws),
        instincts_html=_render_instincts(instincts),
        reflexes_html=_render_reflexes(reflexes),
        projects_html=_render_projects(projects),
        tracking_html=_render_tracking(tracking),
        timeline_html=_render_timeline(timeline),
    )

    out = output_path or (CORTEX_DIR / "dashboard.html")
    out.parent.mkdir(parents=True, exist_ok=True)
    # Atomic write
    tmp = out.with_suffix(".html.tmp")
    tmp.write_text(html, encoding="utf-8")
    os.replace(tmp, out)
    return out


if __name__ == "__main__":
    try:
        path = generate()
        print(str(path))
        sys.exit(0)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
