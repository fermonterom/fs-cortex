# Sprint 5 — Pending Validation Gates

**Status update 2026-05-04 (v3.23.4 + v3.23.5):** Gate 2 reopened. Both
Gate 1 and Gate 2 require a **new measurement window** because the
matchers had silent bugs that produced **0 fires across 6 days** of
intensive Bash use. v3.23.3 fixed the regex; v3.23.4 fixed the runtime
guard that was *also* silencing `bash-cat-use-read`. Honest signal only
starts accumulating once both fixes are deployed.

**Effective measurement window starts 2026-05-04** (post-v3.23.4 install
on the operator's main machine; the previous v3.23.3 window was tainted
because `bash-cat-use-read` was still blocked by the guard).

**Estimate to enough data: 1–2 days** — the operator runs Claude Code
across many projects in parallel daily, so the 30 fires + 50 events
floors should be reached by **2026-05-05 / 2026-05-06**. Re-check
sooner if `/cx-status --reflexes` shows the trio passing the gates.

When Gate 1 + Gate 2 both pass, delete this file and remove the
reference from `CLAUDE.md`.

---

## Background — why we have to start over

The Sprint 5 (v3.20.0) "matcher refinement" of the 3 ex-NOISY reflexes
introduced two regex bugs that made them blind to ~95% of real-world
Bash commands:

1. **Anchor `^`** rejected compound commands (`a; b`, `a && b`, `a | b`)
2. **`-[a-zA-Z]*[rR]`** required `r/R` as the LAST letter of the flag
   prefix, missing `-rn`, `-rE`, `-RE`, etc.

Effect across **6 days of intensive Bash use**:
- 95 commands matching the cat/head/tail-on-source-file pattern → 0 fires
- 133 commands matching `grep -r/-R/-rn/-rE` recursive → 0 fires
- 78 commands matching `find -name` → 0 fires
- **Total: 306 fires lost**, useful/noise both stuck at 0/0

Conclusion was wrong: "no fires = problem disappeared" was actually
"matcher is broken". v3.23.3 fixes the regex; new data lands on the
fixed matcher and starts populating useful/noise from 2026-05-02 onward.

---

## Gate 1 — `bash-grep-use-grep-tool` useful/noise ratio ≥ 3×

**Status:** ⏳ PENDING — re-measurement window starts 2026-05-04 (fresh
matcher + fresh guard). Estimate: enough data by 2026-05-05 / 2026-05-06.

**Pass criterion:** `useful / noise ≥ 3.0` over a rolling 14-day window
where `useful + noise ≥ 50`. The 50-event floor protects against
false-pass on tiny samples.

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

**Action if it fails:**

1. Read the matcher condition in `core/reflexes.default.json`. Current
   (post-v3.23.3): `(?:^|[;&|]\s*)grep\s+(-[a-zA-Z]*[rR][a-zA-Z]*)`
2. Sample noise events to find the false-positive class:
   ```
   grep '"iid":"reflex:bash-grep-use-grep-tool"' ~/.claude/cortex/impact.jsonl \
     | grep '"rating":"noise"' | tail -10
   ```
3. Refine the regex to exclude the false-positive class. Bump v3.23.x patch.

---

## Gate 2 — Three reactivated NOISY reflexes stay enabled and have signal

**Status:** ⏳ REOPENED 2026-05-02. Was prematurely closed in v3.22.2.

**Why reopened:** the original Gate 2 condition (`enabled: true AND
noiseCount < 3`) was technically met since 2026-04-26, but the reason
was that the matchers were broken (0 fires → 0 noise trivially). True
intent of Gate 2 is "the refined matchers are healthy" — that requires
**fires + a healthy useful/noise ratio**, not just zero noise.

**New pass criterion:**

For each of `bash-cat-use-read`, `bash-grep-use-grep-tool`,
`bash-find-use-glob`:

- `enabled: true` AND
- `fireCount post-resetAt ≥ 30` (matcher is actually working) AND
- `usefulCount / max(noiseCount, 1) ≥ 2.0` (decent signal quality, lower
  than Gate 1's 3× because these matchers fire on broader categories)

**How to re-measure:**

```bash
python3 -c "
import json
data = json.load(open('/Users/fmm/.claude/cortex/reflexes.json'))
items = data.get('reflexes', data)
items = list(items.values()) if isinstance(items, dict) else items
for r in items:
    if r['id'] in ('bash-cat-use-read','bash-grep-use-grep-tool','bash-find-use-glob'):
        en = r['enabled']
        fc = r.get('fireCount',0)
        uc = r.get('usefulCount',0)
        nc = r.get('noiseCount',0)
        ratio = uc / max(nc,1)
        ok = en and fc >= 30 and ratio >= 2.0
        print(f'{r[\"id\"]:30} enabled={en} fires={fc} useful={uc} noise={nc} ratio={ratio:.1f}x {\"PASS\" if ok else \"PENDING\"}')
"
```

**Action if it fails:** same as Gate 1 — sample noise events, refine
matcher.

---

## Gate 3 — Injection rate per session ≥ 40% lower than pre-Sprint-5

**Status:** ❌ DROPPED 2026-04-30 in v3.22.2 (kept dropped).

**Why dropped:** the original `inject/session` baseline from v3.19.x is
not reconstructible from `impact.jsonl` history (the earliest events in
the current file are 2026-04-25, all post-Sprint-5). Reconstructing a
pre-v3.20.0 baseline would require backup recovery that does not exist.

The intent of Gate 3 — "Sprint 5 should reduce noise injection" — is
already covered by the `useful_ratio` and `noise_ratio` aggregates in
`/cx-status --impact`, which currently report `0.91` user useful and
`0.0003` agent noise. The signal is healthy without needing this
specific ratio.

---

## Cleanup

When Gate 1 + Gate 2 both pass with fresh post-v3.23.4 data:

1. Delete this file: `rm docs/SPRINT-5-PENDING-GATES.md`
2. Remove the reference from `CLAUDE.md` (the line under "Pending validation").
3. Note the closure in `CHANGELOG.md` under the next release.
