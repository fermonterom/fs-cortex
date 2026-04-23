---
name: cx-dashboard
description: Generate a visual HTML dashboard of Cortex state with Fersora brand — open in browser
command: true
---

# /cx-dashboard

## What it does

Generates a self-contained, visual HTML report of the complete Cortex state
(laws, instincts, reflexes, projects, activation stats, recent events) styled
with the Fersora brand. Saves to `~/.claude/cortex/dashboard.html` and opens
it in the default browser.

Complements `/cx-status` (which renders a compact ASCII dashboard in the
terminal) — use `/cx-dashboard` when you want a richer, shareable visual
report or a quick at-a-glance overview with health scoring.

## Implementation

### Step 1: Generate the HTML

Run the dashboard generator. It reads all Cortex data files and writes a
single self-contained HTML to `~/.claude/cortex/dashboard.html`:

```bash
python3 ~/.claude/hooks/cortex/lib/dashboard_gen.py
```

The script reads (all read-only, no writes to Cortex data):
- `~/.claude/cortex/laws/*.txt` — level-3 always-loaded rules
- `~/.claude/cortex/instincts/global/*.yaml` + `projects/*/instincts/*.yaml`
- `~/.claude/cortex/reflexes.json` — pre-tool reflexes + fire stats
- `~/.claude/cortex/projects/registry.json` + per-project obs/instinct counts
- `~/.claude/cortex/instinct-tracking.json` — top activations
- `~/.claude/cortex/knowledge-log.md` — last 20 events
- `~/.claude/cortex/memory.json` — version metadata

It computes a health score (0-100) based on:
- Missing laws (−10)
- Excessive instinct count (>50, −10)
- Reflexes that never fired (up to −15)
- Stale projects (>90 days without activity, −10)

### Step 2: Open the HTML

Open the generated file in the user's default browser:

```bash
# macOS
open ~/.claude/cortex/dashboard.html

# Linux
xdg-open ~/.claude/cortex/dashboard.html

# Windows (PowerShell from Claude Code)
start ~/.claude/cortex/dashboard.html
```

If opening fails silently (headless environment, SSH, etc.), report the path
to the user so they can open it manually.

### Step 3: Summary

After generating, print a one-line summary in the chat:

```
Dashboard generated: ~/.claude/cortex/dashboard.html
  N laws · N instincts · N reflexes · N projects · Health: XX/100
```

## Design notes

- **Brand**: Fersora Green (`#B2CE38`), Lavender (`#98B4E0`), Orange (`#E8842A`).
  Typography: Merriweather (headings), Open Sans (body), JetBrains Mono (code).
- **Self-contained**: all CSS + JS inline, fonts loaded from Google Fonts,
  logo from `fersora.com`. Works offline except for fonts and logo.
- **Responsive**: mobile-first, breakpoint at 768px. Nav scrolls horizontally
  on narrow screens without wrapping.
- **Scroll spy**: nav highlights the current section via `IntersectionObserver`.
- **Atomic write**: uses `os.replace()` so a partial HTML never ends up at the
  final path even if the script crashes mid-write.

## What NOT to do

- Do not modify any Cortex data — this is read-only.
- Do not hardcode data: the script reads everything from disk each run.
- Do not open the HTML if the user is in a headless/non-interactive session —
  in that case, just print the path.
