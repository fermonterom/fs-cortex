# Sprint 5 — Pending Validation Gates

**Status update 2026-04-30 (v3.22.2):** Gate 2 closed (PASS).
Gate 1 reframed — measurable from mid-May onward (waiting for fresh
post-`resetAt` evidence). Gate 3 dropped as not measurable.

When Gate 1 passes, delete this file and remove the reference from
`CLAUDE.md`.

---

## Gate 1 — `bash-grep-use-grep-tool` useful/noise ratio ≥ 3×

**Status:** ⏳ PENDING — measurable from mid-May 2026 onward.

**Why this gate exists:** v3.20.0 refined the matcher of three NOISY
reflexes that had been auto-disabled. The pre-refinement evidence
contaminated the useful/noise ratio of the new matcher with 62 noise
events from the OLD matcher (1.13×, fail).

**v3.22.1 fix:** added `resetAt: 2026-04-26T13:31:57+02:00` to all three
bash-* reflexes. `impact_log.py` now discards pre-reset events for
those reflexes when computing `--impact` stats. The ratio is now
measured on post-refinement data only.

**Current value (2026-04-30):** 0 useful / 0 noise events post-reset
(only ~5 days of fresh history accumulated). Not enough data to evaluate.

**How to re-measure:**

```bash
python3 ~/.claude/hooks/cortex/lib/impact_log.py stats --days 14 --json \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
useful = next((x['useful'] for x in d.get('per_iid', []) if x['iid'] == 'reflex:bash-grep-use-grep-tool'), 0)
noise  = next((x['noise']  for x in d.get('per_iid', []) if x['iid'] == 'reflex:bash-grep-use-grep-tool'), 0)
ratio  = useful / max(noise, 1)
print(f'bash-grep-use-grep-tool: useful={useful} noise={noise} ratio={ratio:.2f}x')
print('PASS' if ratio >= 3.0 and (useful + noise) >= 50 else 'PENDING')
"
```

**Pass criterion:** `useful / noise ≥ 3.0` over a rolling 14-day window
where `useful + noise ≥ 50`. The 50-event floor protects against
false-pass on tiny samples.

**Action if it fails after enough data has accumulated:**

1. Read the matcher condition in `core/reflexes.default.json`:
   `^grep\s+(-[a-zA-Z]*[rR])`
2. Sample noise events:
   ```
   grep '"iid":"reflex:bash-grep-use-grep-tool"' ~/.claude/cortex/impact.jsonl \
     | grep '"rating":"noise"' | tail -10
   ```
3. Refine the regex to exclude the false-positive class. Bump v3.22.x patch.

---

## Gate 2 — Three reactivated NOISY reflexes stay enabled

**Status:** ✅ PASS (closed 2026-04-30 in v3.22.2).

**Final values:**

| Reflex | enabled | fireCount | noiseCount |
|---|---|---|---|
| `bash-cat-use-read` | yes | 696 | 0 |
| `bash-grep-use-grep-tool` | yes | 665 | 0 |
| `bash-find-use-glob` | yes | 504 | 0 |

All three remain `enabled: true` with `noiseCount: 0` after 5+ days of
fresh post-refinement data. The auto-disable threshold
(`noiseCount >= 3 AND fireCount >= 10` under
`CORTEX_AGENT_DISABLE_REFLEXES=1`) was never hit. Gate 2 is closed.

---

## Gate 3 — Injection rate per session ≥ 40% lower than pre-Sprint-5

**Status:** ❌ DROPPED — not measurable.

**Why dropped:** the original `inject/session` baseline from v3.19.x is
not reconstructible from `impact.jsonl` history (the earliest events in
the current file are 2026-04-25, all post-Sprint-5). Reconstructing a
pre-v3.20.0 baseline would require backup recovery that does not exist.

The intent of Gate 3 — "Sprint 5 should reduce noise injection" — is
already covered by the `useful_ratio` and `noise_ratio` aggregates in
`/cx-status --impact`, which currently report `0.90` user useful and
`0.0003` agent noise (essentially zero). The signal is healthy without
needing this specific ratio.

---

## Cleanup

When Gate 1 passes (estimate: mid-May 2026):

1. Delete this file: `rm docs/SPRINT-5-PENDING-GATES.md`
2. Remove the reference from `CLAUDE.md` (the line under "Pending validation").
3. Note the closure in `CHANGELOG.md` under the next release.
