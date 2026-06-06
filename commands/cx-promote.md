---
name: cx-promote
description: Promote project-scoped instincts to global when detected in multiple projects
command: true
---

# /cx-promote

## What it does

Detects instincts that exist in multiple projects (via Jaccard similarity) and offers to promote them to global scope. This crystallizes cross-project patterns into reusable knowledge.

## Usage

```
/cx-promote                                # Scan all projects for promotion candidates (default)
/cx-promote --dry-run                      # Show candidates without applying changes
/cx-promote --auto <source> --confirm      # v3.32.0 §4.4: promote a HUMAN-gated detector
                                           # source to AUTO once the statistical gate passes
                                           # (n ≥ 20 reviewed, accept_rate ≥ 70 %,
                                           # ≥ 3 distinct sessions, 0 critical rejections)
```

## Sub-modes

The default mode promotes cross-project **instincts** (Jaccard ≥ 0.70 in ≥ 2
projects). Steps 1-5 below describe this mode.

The `--auto <source>` mode (added in v3.32.0 §4.4) is unrelated: it promotes
a **detector source** (e.g. `session-learner:correction`) from HUMAN-gated
to AUTO so future proposals from that source are auto-validated without
operator review. See *Sub-mode --auto* near the bottom.

## Trust boundary (security)

The `--auto <source> --confirm` flow has **no second factor**. `--confirm` is
the only gate: anything that can run this command — the local operator, or any
process with write access to `~/.claude/cortex/` and the ability to invoke the
engine — can flip a detector source from HUMAN-gated to AUTO, after which its
proposals are auto-validated into instincts without review.

The trust boundary is therefore the **local machine / operator account**, not
the command itself. This is acceptable because:
- Cortex is a single-operator, local-only system; there is no multi-user or
  remote surface to authenticate against.
- The statistical gate (`can_promote_to_auto`) still requires n ≥ 20 reviewed
  + accept_rate ≥ 70 % + ≥ 3 distinct sessions + 0 critical rejections, so a
  source cannot be promoted until it has a real human-reviewed track record.
- `.promoted-detectors.json` is the only writer of AUTO state and is
  fail-closed: any parse / schema / source-regex violation reverts to an empty
  set (no source trusted) and logs to `log/security-events.jsonl`.

**If Cortex is ever exposed beyond a single trusted operator** (shared host,
CI, remote trigger), add an explicit second factor here before enabling
`--auto`.

## Implementation

### Step 1: Collect All Project Instincts

Scan `~/.claude/cortex/projects/*/instincts/*.yaml` to collect all project-scoped instincts.

For each instinct, parse: id, trigger, action, confidence, domain, last_seen.

### Step 2: Find Cross-Project Matches

Compare each project instinct against instincts in OTHER projects using Jaccard similarity:

```python
import sys
sys.path.insert(0, os.path.expanduser("~/.claude/hooks/cortex/lib"))
from dream_cycle import jaccard_similarity
```

Promotion criteria (all must be met):
- Jaccard similarity >= 0.70 with instinct in another project
- Present in >= 2 different projects
- Average confidence >= 0.60 across projects
- NOT already in `~/.claude/cortex/instincts/global/`

### Step 3: Present Candidates

For each candidate, show:
```
PROMOTION CANDIDATE #1:
  Action: "Always run tests before committing changes"
  Found in: project-a (conf: 0.75), project-b (conf: 0.80), project-c (conf: 0.65)
  Similarity: 0.82 (Jaccard)
  Avg confidence: 0.73
  Recommendation: PROMOTE (3 projects, high confidence)

  [A] Accept (promote to global)
  [X] Reject (keep project-scoped)
  [S] Skip (decide later)
```

### Step 4: Apply Promotions

For accepted candidates:
1. Create new YAML file in `~/.claude/cortex/instincts/global/` with:
   - Merged action text (from highest-confidence version)
   - Confidence = average across projects (capped at 0.85)
   - Domain = most common domain across matches
   - `promoted_from` field listing source projects
   - `promoted_date` field with current date
2. Do NOT delete the project-scoped originals (they may have project-specific trigger patterns)

### Step 4b: Log to Knowledge Timeline

After applying promotions in Step 4, append one line per promoted instinct to `~/.claude/cortex/knowledge-log.md`:

```bash
echo "$(date +%Y-%m-%d) | global | {id} | {confidence} | cx-promote" >> ~/.claude/cortex/knowledge-log.md
```

### Step 5: Report

```
PROMOTION SUMMARY:
  Candidates found: N
  Promoted: M
  Skipped: K
  Rejected: J

  Promoted instincts are now in ~/.claude/cortex/instincts/global/
  They will be injected in ALL projects going forward.
```

## Sub-mode `--auto <source> --confirm` (v3.32.0 §4.4)

Promotes a **detector source** from HUMAN-gated to AUTO so future
proposals from that source are auto-validated without operator review.
This is the ONLY entrypoint that writes `~/.claude/cortex/.promoted-detectors.json` —
the engine never writes it on its own (AD P0-4 fail-closed design).

### Step 1: Check eligibility

```python
import sys
sys.path.insert(0, os.path.expanduser("~/.claude/hooks/cortex/lib"))
from distill_engine import can_promote_to_auto

eligible, reason, stats = can_promote_to_auto("session-learner:correction")
```

`stats` = `{reviewed_count, accept_count, distinct_sessions, critical_count}`.

Display the gate snapshot:

```
Source: session-learner:correction
  Reviewed:           24
  Accepted:           19  (79.2 %)
  Distinct sessions:   4
  Critical rejections: 0
  Status: ELIGIBLE — all-gates-pass
```

Status values:
- `reviewed N/10 (need review tier)` — not enough data yet
- `visible-only (N/20)` — partial progress, no promotion
- `accept_rate X.XX < 0.70` — below acceptance threshold
- `distinct_sessions N < 3` — too session-local
- `critical_rejections N > 0` — at least one security / breaking /
  injection rejection (enum or ES/EN heuristic fallback)
- `all-gates-pass` — ELIGIBLE

### Step 2: Confirm

`--confirm` is **mandatory** to write the marker. Without it the call
returns `(False, "missing --confirm", {})` so the operator cannot
accidentally promote.

```python
from distill_engine import manual_promote_detector

ok, reason, stats = manual_promote_detector(
    "session-learner:correction",
    confirm=True,
)
```

On success the marker `.promoted-detectors.json` is written atomically
(temp+rename) with the schema:

```json
{
  "version": 1,
  "promoted": [
    {
      "source": "session-learner:correction",
      "since": "2026-05-26T15:23:04Z",
      "approved_by": "operator",
      "gate_snapshot": {
        "reviewed_count": 24,
        "accept_count": 19,
        "accept_rate": 0.792,
        "distinct_sessions": 4
      }
    }
  ]
}
```

Subsequent calls to `auto_validate_proposals` will pass HUMAN-domain
proposals from that source through to the AUTO accept path.

### Step 3: Audit logs

Any parse/schema error in the marker is silently treated as
"not promoted" (fail-closed) AND logged to
`~/.claude/cortex/log/security-events.jsonl`:

```jsonl
{"ts":"2026-05-26T15:30:00Z","event":"promoted-detectors:invalid-source","detail":"session-l3@rner:bad"}
{"ts":"2026-05-26T15:31:00Z","event":"promoted-detectors:invalid-schema","detail":"version=2"}
```

The operator can `cat` that file to see why a marker was rejected.

### Notes

- The marker is **append-only** via this command. To remove a promoted
  source you currently edit `.promoted-detectors.json` by hand and
  remove the entry from the `promoted` list.
- `rejection_category` is captured by `/cx-validate` (v3.32.0+) when
  the operator rejects a proposal; legacy rejects without the field
  fall back to a keyword heuristic over `rejected_reason`
  (ES: seguridad / inseguro / rompedor / inyecci / vulnerab; EN:
  security / breaking / injection / unsafe / vulnerab).
