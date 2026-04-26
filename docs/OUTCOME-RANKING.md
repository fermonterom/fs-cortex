# OUTCOME-RANKING — Confidence nudges driven by observed outcomes

> Introduced in **v3.20.0** (Sprint 5 · Autonomy + intelligence).
> Writer: `hooks/lib/impact_log.py` (`compute_outcome_ranking`,
> `apply_outcome_nudges`).
> Caller: `hooks/session-learner.js` Step 5e (Stop-time subprocess).

This document is the architectural decision record for **how observed
clean-vs-error outcomes after an instinct injection automatically adjust
the instinct's confidence**, and the safeguards that keep this signal
honest.

---

## Problem

Pre-v3.20.0 the impact funnel collected `inject`, `follow`, `feedback`,
and `outcome` events but never closed the loop on instinct confidence.
Confidence was set at instinct birth (`/cx-validate`) and only changed
via:

- Manual `/cx-downvote` (decay)
- Distillation to a law (`/cx-distill`, snap to ≥0.90)
- Dream Cycle staleness decay (last-seen based)

None of these used the **post-injection signal** the funnel was already
collecting. v3.19.4 unblocked `outcome` events (carrying
`error_within_10` per inject), so by v3.20.0 we have ~14 days of data
covering ~300 outcome events per active session — enough to nudge.

---

## Decision

For each instinct (NOT reflex) that emitted at least
`NUDGE_MIN_OUTCOMES=5` outcome events in the last 14 days, compute:

```
outcome_clean_ratio = count(error_within_10 == false) / count(outcome)
```

And map the ratio to a confidence delta:

| Ratio range            | Nudge   | Meaning |
|------------------------|---------|---------|
| `>= 0.85`              | `+0.05` | Boost — instinct correlates with clean follow-up |
| `>  0.30 AND < 0.85`   | `0`     | Held — no clear signal |
| `<= 0.30`              | `-0.05` | Decay — instinct correlates with errors |

The nudge is applied to `confidence:` in the instinct's YAML
frontmatter, **clamped to `[NUDGE_MIN_CONF=0.10, NUDGE_MAX_CONF=0.99]`**.
The 0.99 cap explicitly leaves law promotion (≥0.90 + distillation) as
the only path to "law" status — outcome nudges can saturate at 0.99 but
never auto-promote to 1.0+ (laws live in `~/.claude/cortex/laws/*.txt`,
not in YAML).

Each applied nudge writes one line to `~/.claude/cortex/knowledge-log.md`
in the existing pipe-delimited format:

```
2026-04-26 | outcome-nudge | <iid> | conf 0.7700 → 0.8200 (+0.05) | impact-funnel
```

---

## Why reflexes are excluded

Reflex iids (`iid: reflex:*`) carry their own runtime accounting
(`fireCount`, `usefulCount`, `noiseCount`, `enabled`) and have a
parallel auto-disable loop in `correlateReflexFeedback`. They have **no
`confidence` field** in YAML — they live in `reflexes.json`, not in
instinct YAMLs.

`apply_outcome_nudges` iterates the YAML files only and skips any iid
starting with `reflex:`. The compute function (`compute_outcome_ranking`)
returns rankings for ALL iids (instincts and reflexes both) — useful
for auditing — but the application function silently drops reflex
candidates. See `tests/test_impact.sh` Test 35.

---

## Algorithm contract

```python
def compute_outcome_ranking(days=14, min_outcomes=5) -> dict:
    """
    Returns:
      {
        "<iid>": {
          "outcome_total": int,
          "outcome_clean": int,
          "outcome_error": int,
          "ratio": float,    # 0.00 - 1.00
          "nudge": float,    # one of -NUDGE_DELTA, 0, +NUDGE_DELTA
        },
        ...
      }
    """
```

Iids with fewer than `min_outcomes` outcome events in the window are
**excluded entirely** — not given nudge=0. This prevents a single
clean outcome from being interpreted as evidence in either direction.

```python
def apply_outcome_nudges(rankings, dry_run=False) -> list[dict]:
    """
    For each instinct YAML whose `id` matches a ranking with a non-zero
    nudge, rewrite `confidence: <new>` in the frontmatter.

    Returns list of {iid, path, before, after, nudge} for every change.
    """
```

The YAML rewrite uses a regex against the frontmatter (no full YAML
parser required — keeps the dependency surface zero). The atomic write
uses `tmp + os.replace` so a crash mid-write cannot leave a half-written
YAML.

---

## CLI surface

Two new subcommands on `impact_log.py`:

```bash
# Print rankings (read-only)
python3 ~/.claude/hooks/cortex/lib/impact_log.py outcome-ranking --days 14

# Dry-run nudge application (read-only)
python3 ~/.claude/hooks/cortex/lib/impact_log.py outcome-nudge --days 14

# Actually persist nudges + log to knowledge-log.md
python3 ~/.claude/hooks/cortex/lib/impact_log.py outcome-nudge --days 14 --apply
```

Both support `--json` for machine-readable output and `--min-outcomes N`
to override the default threshold.

---

## Stop-hook integration

`hooks/session-learner.js` runs at every Stop event and adds **Step 5e**
after `correlateReflexFeedback` (Step 5d):

```js
// Step 5e: Outcome auto-ranking — nudge instinct confidence based on
// observed outcome cleanliness. Sprint 5, v3.20.0.
const r = spawnSync('python3', [impactPy, 'outcome-nudge', '--days', '14', '--apply', '--json'],
  { encoding: 'utf8', timeout: 5000, env: process.env });
```

The subprocess timeout is 5s — outcome nudge is a non-critical "best
effort" step; if Python crashes or times out, the rest of the Stop hook
proceeds normally.

---

## Safeguards

1. **Minimum sample size** — `min_outcomes=5` per iid before any
   nudge is computed. Single-shot outcomes never move confidence.
2. **Bounded delta** — `±0.05` per Stop hook. Even at maximum cadence
   (one Stop per minute), confidence cannot move >3 points per hour.
3. **Hard clamp** — `[0.10, 0.99]`. An instinct cannot saturate to 0
   (gets re-tested forever) or to 1.0 (law promotion stays manual).
4. **Reflexes immune** — reflex iids skipped at apply time.
5. **Conservative middle band** — ratio in `(0.30, 0.85)` returns 0,
   so noisy mid-range data never moves confidence by accident.
6. **Knowledge log** — every applied nudge writes one line. The
   `/cx-timeline` command surfaces these for retrospective review.
7. **Cohort-based gating (v3.21.0+)** — `~/.claude/cortex/nudge-state.json`
   schema v2 records `{last_event_ts, last_nudge_ts, last_direction,
   conf_at_last_nudge}` per iid. The apply path
   (`compute_outcome_decisions()`) only counts outcomes whose `ts` is
   **strictly later** than `last_event_ts`. The ratio is therefore
   *marginal* — it answers "did the new evidence point up or down?"
   instead of "what does the rolling 14-day average look like?".
   This closes four bugs the v3.20.2 `outcome_total` gate left open:
   *(a) drift* (aggregate stays >0.85 even when the recent cohort is
   80% errors); *(b) archive decrement* (`rotate()` removes >30d
   events, `outcome_total` falls below `prev_seen`, gate skips
   silently); *(c) race condition* in parallel Stop hooks (now
   serialized by `fcntl.flock` advisory lock on
   `nudge-state.json.lock`); *(d) reverse-direction whiplash* (data
   sours but aggregate is still positive — cohort ratio decays
   immediately). The v3.20.0 / v3.20.1 saturation symptom
   (`gotcha-agent-spawn-preflight` racing `0.77 → 0.99` in five
   hooks) was only the first observable manifestation of these
   four underlying defects.

### Reset

If `nudge-state.json` becomes inconsistent with reality (e.g. after a
manual confidence rewrite, a knowledge-log review, or recovery from a
bug like the v3.20.0/.1 saturation), delete the file:

```bash
rm ~/.claude/cortex/nudge-state.json
```

The next Stop hook re-creates it from the current `impact.jsonl` view.
Note that the existing YAML confidence values are NOT touched — only the
"have I already nudged for these outcomes?" memory is wiped.

---

## Failure modes considered

- **Python subprocess crashes**: caught in JS try/except; logged but
  does not block the Stop hook.
- **Concurrent YAML rewrites** (Stop fires while user is editing the
  YAML): `tmp + replace` is atomic on POSIX/Windows; the worst case is
  the user sees the new value on next save.
- **Schema drift in `outcome` events** (new fields added): the function
  reads only `iid` and `error_within_10`; extra fields are ignored.
- **Imbalanced sample** (one iid with 1000 outcomes, another with 5):
  no normalization. By design — frequently-fired instincts are the
  ones we most want to refine.

---

## What this does NOT do

- **No A/B experiments.** The brief left this for v4.1+; a 1-day-off
  experiment would need explicit user opt-in.
- **No automatic law promotion.** Confidence ≥0.90 still requires
  `/cx-distill` + manual confirmation to crystallize as a law.
- **No reflex enabling/disabling.** Reflex auto-disable still uses the
  `noiseCount >= 3 AND fireCount >= 10 AND env-flag` rule from v3.18.0.

---

## Reflex matcher refinements (Sprint 5 task 2c)

Same release adds refined matchers for the three `tool-substitution`
reflexes that were auto-disabled in v3.19.x:

| Reflex | Old matcher | New matcher | Rationale |
|--------|-------------|-------------|-----------|
| `bash-cat-use-read` | `"cat \|head -\|tail -` | `^(cat\|head\|tail)\s+[\.\/~]?\S*\.(py\|js\|jsx\|ts\|tsx\|md\|json\|ya?ml\|sh\|html\|css\|toml\|cfg\|ini\|conf\|sql\|env)\b` | Source files only; excludes pipes, heredocs, log tails |
| `bash-grep-use-grep-tool` | `grep -[rRnl]` | `^grep\s+(-[a-zA-Z]*[rR])` | Recursive search only; drops `-n` (line nums) and `-l` (filenames-only) which are common pipe usage |
| `bash-find-use-glob` | `find .* -name` | `^find\s+\S+\s+-name\s+\S+(?!.*-(exec\|delete\|newer\|mtime\|print0\|prune))` | Plain `-name` searches only; Glob can't replace `find -exec`/`-delete`/etc. |

All three were re-enabled with `usefulCount=0` / `noiseCount=0` in
the same release. If they cross the auto-disable threshold again, the
matchers need further tuning before the next reactivation.

---

## Audit of NEVER-FIRED reflexes (Sprint 5 task 2b)

Reflexes with `fireCount==0` after weeks of use were reviewed for
trigger calibration. Decision:

| Reflex | Decision | Reason |
|--------|----------|--------|
| `git-merge-verify` | leave | matcher `gh pr merge` is correct; user uses GitHub UI for merges in this corpus |
| `security-headers` | leave | matcher `vercel.json\|next.config` is correct; files just not touched in this window |
| `html-twin-deliverables` | leave | matcher `\.(docx\|pdf\|pptx\|xlsx)` is correct; deliverables are rare |
| `python3-bypass-write-tool` | leave | narrow matcher `python3.*write_text` is correct |
| `instinct-downvote` | leave | meta-reflex — fires on `/cx-downvote` invocations only |
| `capture-decision` | leave | meta-reflex — fires on user-language patterns |
| `tavily-rate-limit` | leave | matcher `tavily` tool is correct; tool not used in window |
| `docker-cross-network` | leave | matcher `docker compose\|docker network` is correct; tool not used in window |
| `git-tag-after-amend` | leave | matcher correct; only fires during release flow |

None of the never-fired reflexes have over-broad matchers — they're
all genuinely domain-specific. The "9 NEVER FIRED" diagnostic was
therefore a corpus signal (which domains the user touches), not a
matcher problem. No changes were made.

---

## Tests

`tests/test_impact.sh` gains 7 new tests (Test 31–37):

31. `compute_outcome_ranking` returns `nudge=+0.05` for clean iid
32. Dirty iid earns `nudge=-0.05`
33. Middling ratio (0.30 < r < 0.85) earns `nudge=0`
34. Iids below `min-outcomes` are excluded
35. `apply_outcome_nudges` skips `reflex:*` iids
36. Nudge persisted to YAML and clamped to `[0.10, 0.99]`
37. `knowledge-log.md` gets one line per applied nudge

Pre-Sprint-5 baseline was 40 tests; Sprint 5 brings the suite to 48.

---

## Stability contract

- `compute_outcome_ranking()` return shape is frozen for v:1. Adding
  fields is allowed; renaming or removing requires a function rename.
- `apply_outcome_nudges()` may NEVER move a confidence outside
  `[NUDGE_MIN_CONF, NUDGE_MAX_CONF]` even with adversarial input.
- The `outcome-nudge` CLI subcommand defaults to dry-run; `--apply`
  must be passed explicitly to persist (the Stop-hook path passes
  `--apply` because the agent is the one auditing it).

---

## Referenced by

- `hooks/lib/impact_log.py` — implementation
- `hooks/session-learner.js` — Step 5e subprocess call
- `tests/test_impact.sh` — Tests 31–37
- `core/reflexes.default.json` — refined matchers (Sprint 5 task 2c)
- `~/.claude/cortex/knowledge-log.md` — audit trail of every applied nudge
- `CHANGELOG.md` v3.20.0 entry
- `docs/IMPACT-METRICS.md` — schema reference for `outcome` events
