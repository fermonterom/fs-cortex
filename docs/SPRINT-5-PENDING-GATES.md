# Sprint 5 — Pending Validation Gates

**Status**: Sprint 5 closed in v3.20.0 (matcher refinement) and v3.21.0
(cohort-based outcome nudging). The code work is done. What remains are
**three measurement gates** that can only be validated with fresh production
data — they were not measurable at release time because the new matchers
had no fire history yet.

**Re-measure after**: 24-48h of normal use (faster) or 7d for the −40%
injection-rate gate (slower, needs comparable workload).

---

## Why this file exists

Cortex has no built-in scheduler for "remind me to check metric X in N days",
so this acts as a project-tracked reminder. It is referenced from
`CLAUDE.md` so it surfaces at SessionStart. When all three gates pass,
delete this file.

---

## Gate 1 — `bash-grep-use-grep-tool` useful/noise ratio > 3×

**Why it matters**: in v3.20.0 we refined the matcher of three NOISY
reflexes that had been auto-disabled. `bash-cat-use-read` and
`bash-find-use-glob` recovered cleanly. `bash-grep-use-grep-tool` is the
last one and the matcher refinement is on probation.

**Current value (2026-04-27)**: 70 useful / 62 noise = **1.13×** — fails.

**How to re-measure**:

```bash
python3 ~/.claude/hooks/cortex/lib/impact_log.py stats --days 14 \
  | grep -A1 "bash-grep-use-grep-tool"
```

**Pass criterion**: useful_count / noise_count ≥ 3.0 over a rolling 14-day
window where total fires ≥ 50.

**Action if it fails after 7+ days of fresh data**:

1. Read the matcher in `core/reflexes.default.json` and the `condition`
   field. Current condition: `^grep\\s+(-[a-zA-Z]*[rR])`.
2. Sample noise events: `python3 ~/.claude/hooks/cortex/lib/impact_log.py
   tail --days 14 --reflex bash-grep-use-grep-tool --kind noise | head -20`
3. Refine the regex to exclude the false-positive class. Bump as
   v3.22.x patch.

---

## Gate 2 — Three NOISY reflexes stay reactivated (no auto-disable loop)

**Why it matters**: v3.20.0 reset useful/noise counters of the three
ex-NOISY reflexes when reactivating them. If the matchers are still wrong,
`session-learner.js` will auto-disable them again at the next Stop event
where the noise threshold trips (`noiseCount >= 3 AND fireCount >= 10`
under `CORTEX_AGENT_DISABLE_REFLEXES=1`).

**Current value (2026-04-27)**: all three are `enabled: true` with 0
noise events recorded against them in `reflexes.json`. The impact log
shows residual signal (see Gate 1 for `bash-grep-use-grep-tool`). Pass.

**How to re-measure**:

```bash
python3 -c "
import json
data = json.load(open('/Users/fmm/.claude/cortex/reflexes.json'))
items = data.get('reflexes', data)
items = list(items.values()) if isinstance(items, dict) else items
for r in items:
    if r['id'] in ('bash-cat-use-read','bash-grep-use-grep-tool','bash-find-use-glob'):
        print(f'{r[\"id\"]:30} enabled={r[\"enabled\"]} fires={r.get(\"fireCount\",0)} noise={r.get(\"noiseCount\",0)}')
"
```

**Pass criterion**: all three `enabled: true` AND `noiseCount < 3` after
7+ days of fresh data.

**Action if any flips back to disabled**: the matcher needs more refinement,
not auto-disable. Re-enable manually, refine matcher, bump v3.22.x.

---

## Gate 3 — Injection rate per session ≥ 40% lower than pre-Sprint-5

**Why it matters**: Sprint 5 promised that better matchers + outcome
ranking would reduce noise inyection. Without a baseline number this
gate is unmeasurable, but the proxy is impact funnel `inject` events
per session over 7 comparable days.

**Current value (2026-04-27)**: 2314 inject events over 14 days,
unknown sessions count. Need a baseline from before v3.20.0.

**How to re-measure**:

```bash
# Total injects per session over the last 7 days (post-Sprint-5)
python3 ~/.claude/hooks/cortex/lib/impact_log.py stats --days 7 --json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('inject/session:', d['inject_total']/max(1,d.get('sessions',1)))"
```

**Pass criterion**: 7-day rolling inject/session is ≥ 40% lower than the
v3.19.x baseline (to be reconstructed from `impact.jsonl` history if
possible — see `docs/IMPACT-RETROSPECTIVE-2026-04-25.html` for the
last known pre-Sprint-5 figures).

**Action if it fails**: inspect which reflex/instinct is the dominant
inject source. Likely candidates from /cx-status --reflexes top-fires
table. May require either narrower matchers or migrating to law-tier
(see Sprint 6).

---

## Cleanup

When all three gates pass:

1. Delete this file: `rm docs/SPRINT-5-PENDING-GATES.md`
2. Remove the reference from `CLAUDE.md` (the line under "Pending validation").
3. Note the closure in `CHANGELOG.md` under the next release.

If only some pass, leave the file with the failed gates only.
