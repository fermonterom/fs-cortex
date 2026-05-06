# Sprint 5 — Pending Validation Gates

**Status update 2026-05-06:** both gates' raw counters PASS thresholds
by a wide margin. Holding formal closure to 2026-05-09 to honour the
original 7-day clean window agreed when the measurement window restarted
on 2026-05-04 (post-v3.23.4). Latest reading from `reflexes.json`:

| Reflex                  | fires | useful | noise | ratio  | Gate 2 (≥2.0×, fires≥30, enabled) |
|-------------------------|------:|-------:|------:|-------:|:----------------------------------|
| bash-cat-use-read       |   850 |    114 |     5 |  22.8× | **PASS** (data)                   |
| bash-find-use-glob      |   628 |     12 |     2 |   6.0× | **PASS** (data)                   |
| bash-grep-use-grep-tool |   797 |     50 |     1 |  50.0× | **PASS** (data) — also Gate 1 ✅  |

Gate 1 floor: useful+noise = 51 ≥ 50 ✅. Ratio 50× ≫ 3× threshold.

**Background — original plan (kept for reference below).** Gate 2 was
prematurely closed in v3.22.2 and reopened in v3.23.3 alongside Gate 1
because the matchers had silent regex bugs that produced **0 fires
across 6 days** of intensive Bash use. v3.23.3 fixed the regex;
v3.23.4 fixed the runtime guard that was *also* silencing
`bash-cat-use-read`. Effective measurement window starts 2026-05-04.

**Formal close action on 2026-05-09 (or earlier if user approves):**

1. Re-run the evaluators below; confirm all three reflexes still PASS.
2. Delete this file (`rm docs/SPRINT-5-PENDING-GATES.md`).
3. Remove the "Pending validation" reference from `CLAUDE.md`.
4. Note the closure in `CHANGELOG.md` under the next release entry.

A separate Gate 1 evaluator bug was identified during the 2026-05-06
read: the script below was looking for a non-existent `per_iid` key in
the `impact_log.py stats --json` output. The fix below reads from
`reflexes.json` directly and reports the same numbers as the Gate 2
evaluator.

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

**Status:** ✅ DATA PASS (2026-05-06) — formal close held to 2026-05-09
to honour the agreed 7-day clean window. Latest read: useful=50 noise=1
ratio=50.0× floor=51.

**Pass criterion:** `useful / noise ≥ 3.0` over the post-resetAt window
where `useful + noise ≥ 50`. The 50-event floor protects against
false-pass on tiny samples.

**How to re-measure (fixed evaluator — reads `reflexes.json` directly):**

```bash
python3 -c "
import json
data = json.load(open('/Users/fmm/.claude/cortex/reflexes.json'))
items = data.get('reflexes', data)
items = list(items.values()) if isinstance(items, dict) else items
r = next((x for x in items if x['id'] == 'bash-grep-use-grep-tool'), None)
if not r:
    print('reflex not found'); raise SystemExit(1)
useful = r.get('usefulCount', 0)
noise  = r.get('noiseCount', 0)
fires  = r.get('fireCount', 0)
ratio  = useful / max(noise, 1)
floor  = useful + noise
ok     = ratio >= 3.0 and floor >= 50
print(f'bash-grep-use-grep-tool: fires={fires} useful={useful} noise={noise} ratio={ratio:.2f}x floor={floor}')
print('PASS' if ok else 'PENDING')
"
```

**Why the previous evaluator was wrong:** `impact_log.py stats --json`
returns top-level keys `top_useful` / `top_noisy` (lists), not `per_iid`.
The old script silently returned 0/0 → false PENDING signal.

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

**Status:** ✅ DATA PASS (2026-05-06) — formal close held to 2026-05-09
to honour the agreed 7-day clean window. All three reflexes pass with
margin (cat 22.8×, find 6.0×, grep 50.0×). Was prematurely closed in
v3.22.2; reopened 2026-05-02.

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
