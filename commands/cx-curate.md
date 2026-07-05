---
name: cx-curate
description: "Semantic curator — Claude judges law generality/value and acts: demotes niche laws to instincts, fast-tracks top candidates, downvotes noisy instincts. Zero questions, weekly cadence."
command: true
---

# /cx-curate

## What it does

The LLM half of zero-touch curation (v4.4.0). `/cx-maintain` is the
deterministic half — decay, dedup, purge, threshold-gated promotion. This
command is the SEMANTIC judgment that used to be the human's: which laws are
universal vs stack-niche, which candidates deserve a law slot, which instincts
are noise. It acts immediately (no queue, no AskUserQuestion), logs every
action to the knowledge log, and every action is reversible — demoted laws
cascade back to the instinct pool (`law_eligible: false`, v4.3.1), archived
files stay in `archive/` dirs, downvotes floor confidence instead of deleting.

Runs at most weekly, gated by the `~/.claude/cortex/.last-curate` marker. The
SessionStart banner `[CURATE] due` means the week has elapsed — when you see
it, run this command WITHOUT asking the user. Zero-touch means Claude curates
and the human vetoes after the fact (`/cx-review`, `/cx-downvote`), never that
Claude waits for permission.

## Usage

```
/cx-curate           # Respects the 7d marker — no-ops if a pass ran this week
/cx-curate --force   # Run regardless of marker age
```

## Implementation

Steps 1–2 and 4–5 are mechanical; step 3 is where the judgment lives. Do not
delegate step 3 to a script — the whole point of this command is that a model
reads the corpus and judges.

### Step 1: Gate on the weekly marker

Check the marker via the engine (single source of truth for the cadence):

```bash
LIB="${CORTEX_LIB_DIR:-$HOME/.claude/hooks/cortex/lib}"
python3 -c "import sys; sys.path.insert(0, '$LIB'); import distill_engine as de; print(de.curate_due())"
```

If the marker is fresh (not due) and the user did not pass `--force`, print
`curate al día (last run <date>)` and STOP. Nothing else runs.

### Step 2: Snapshot the corpus

Run the engine CLI `curate-snapshot` — installed lib first, repo checkout as
fallback — and pipe it to a temp file so the full JSON never floods the
transcript:

```bash
TS=$(date +%Y%m%d-%H%M%S)
LIB="${CORTEX_LIB_DIR:-$HOME/.claude/hooks/cortex/lib}"
[ -f "$LIB/distill_engine.py" ] || LIB="hooks/lib"   # repo checkout fallback
python3 "$LIB/distill_engine.py" curate-snapshot > "${TMPDIR:-/tmp}/curate-snapshot-$TS.json"
```

Read that file. Also gather the redundancy context the criteria below need:

- `ls ~/.claude/skills/*/SKILL.md` — installed skill names (a law owned by an
  installed `fs-*` skill is redundant as a law).
- Read `~/.claude/CLAUDE.md` — anything already stated there is always in
  context and does not need a law slot.

### Step 3: JUDGE every law, candidate, and flagged instinct

Apply these WRITTEN CRITERIA — they are the contract of this command, not
suggestions:

* **KEEP as law**: behavioral principles or tooling rules that apply to
  virtually every session regardless of stack; short rules preventing
  expensive/irreversible failures.
* **DEMOTE to instinct**: stack/domain-specific (fires value only in
  web/testing/API/scraping sessions); redundant with `~/.claude/CLAUDE.md`
  (always in context anyway) or clearly owned by an installed fs-* skill;
  zero useful impact after 30+ days despite volume. Laws WITHOUT backing
  instinct (`has_backing_instinct` false) need a strictly higher bar: demote
  only when redundant with CLAUDE.md/skill (archive-only death is acceptable
  only for redundant knowledge).
* **PROMOTE candidate**: universal + actionable + non-redundant + NOT already
  served by a live high-confidence instinct whose deterministic trigger fires
  exactly when the knowledge matters + only real blocker is the saturated cap.
  (Finding from the 2026-07-05 audit: every top candidate that day was refuted
  because it already lived as a 0.99-confidence trigger-gated instinct — a
  well-triggered instinct is a BETTER channel than a law. Reserve law slots
  for knowledge with NO reliable trigger moment, e.g. behavioral principles
  that must hold before any tool call.)
* **DOWNVOTE instinct**: impact noise > useful with real volume;
  conf >= 0.90 with vague unactionable text; one-off hyper-specific frozen at
  high confidence.

### Step 4: ACT within the hard budgets

The budgets are engine constants, not judgment calls: **max 2 demotes, 2
promotes, 8 downvotes per pass; never touch laws < 30 days old**. If the
judged list exceeds a budget, act on the strongest cases and leave the rest
for next week's pass.

- **Demote a law** (cascades to instinct pool, refuses when no backing
  trigger exists):

  ```bash
  python3 -c "import sys; sys.path.insert(0, '$LIB'); import distill_engine as de; print(de.demote_law_to_domain('<law-id>'))"
  ```

- **Promote a candidate**: at a saturated cap, pair each top candidate with a
  confirmed demote victim via the atomic swap; below cap, plain promotion:

  ```bash
  python3 -c "import sys; sys.path.insert(0, '$LIB'); import distill_engine as de; print(de.manual_swap_promote('<new-iid>', '<deprecate-iid>'))"
  ```

- **Downvote an instinct** via the engine CLI (confidence-floored, never
  deleted):

  ```bash
  python3 "$LIB/distill_engine.py" downvote <instinct-id>
  ```

- **Re-tier surviving laws**: update the `tier` entries in
  `~/.claude/cortex/laws/laws-meta.json` (`principle` | `tool`) for laws that
  stay, so `session-start.py` groups them correctly.

### Step 5: Close the pass

- Touch the weekly marker:

  ```bash
  python3 -c "import sys; sys.path.insert(0, '$LIB'); import distill_engine as de; de.touch_curate_marker()"
  ```

- The `## cx-curate <date>` block in `~/.claude/cortex/knowledge-log.md`
  accumulates ONLY via the `_log_knowledge` calls the engine functions in
  Step 4 already made — never edit that file by hand.
- Merge a `curate_last_run` object into
  `~/.claude/cortex/.review-digest.json` (read-modify-write, tolerate a
  missing file — preserve whatever `/cx-maintain` last wrote):

  ```json
  "curate_last_run": {"demoted": [], "promoted": [], "downvoted": [], "at": "<iso>"}
  ```

### Step 6: Report to the user

5 lines max: what moved (demotes, promotes, downvotes with ids) and the
one-line why for each, closing with "todo reversible desde archive". No
recommendations, no questions, no homework for the user.
