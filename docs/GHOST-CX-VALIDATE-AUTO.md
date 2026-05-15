# Ghost script `cx-validate-auto` — Forensic Report

**Investigation date:** 2026-05-15 (Día 0 of Sprint 8)
**Status:** 🔒 EXTERNAL, NON-REPRODUCIBLE — mitigation via preventive guard (Sprint 8 §4.7)

---

## Symptoms

847 proposals in `~/.claude/cortex/proposals.json` have:
- `status: "rejected"`
- `rejected_by: "cx-validate-auto"`
- `rejected_at: "2026-05-05"` (single-day burst)
- `rejected_reason`: typically `"session-learner noise: frequency counter / repetition / generic workflow without ..."`

Distribution: mostly `correction-*` proposals with `domain: user-preference`. Some legitimate `agent-evolution` (conf 0.55-0.70) that `distill_engine.auto_validate_proposals` would have ACCEPTED were also rejected.

## Archaeology performed

```bash
# 1) Literal string search in fs-cortex repo history
git log --all --full-history -S "cx-validate-auto" --oneline
# Result: ONLY this Sprint's own commits (38e555c documenting the ghost)

# 2) Assembled-string regex search
git log --all --full-history -G "cx[-_]validate[-_]auto" --oneline
# Result: same — only documentation commits

# 3) Deletion history
git log --all --diff-filter=D --summary | grep -i validate
# Result: nothing matching cx-validate-auto

# 4) External scan
grep -rln "cx-validate-auto\|cx_validate_auto" \
  ~/.claude/commands/ ~/.claude/agents/ ~/.claude/plugins/ \
  ~/.claude/skills/ ~/.claude/hooks/
# Result: only logs from fs-codex MCP server (records of this session's own
# AD review conversations) — NOT the script itself

# 5) Settings + plugin manifests
grep -rln "cx-validate-auto" ~/.claude/settings*.json
find ~/.claude/plugins/ -name "manifest.json" -exec grep -l "cx-validate-auto" {} \;
# Result: nothing
```

## Conclusion

**The script `cx-validate-auto` does NOT exist** in:
- fs-cortex repo (any branch, any history)
- `~/.claude/commands/`
- `~/.claude/agents/`
- `~/.claude/plugins/`
- `~/.claude/skills/`
- `~/.claude/hooks/`
- `settings.json` / `settings.local.json`

The script that bulk-rejected 847 proposals on 2026-05-05 is a **fenómeno externo no reproducible**. Most likely explanation: an ad-hoc Python one-liner executed by the operator (or a now-deleted experimental script) that applied a noise heuristic to the proposals.json on that date and was not preserved.

## Mitigation (Sprint 8 §4.7)

Since the script source cannot be located, the v3.29.0 mitigation is **defensive at the `distill_engine` boundary**:

1. **Preventive guard in `auto_validate_proposals()`**: an authorized whitelist of `rejected_by` values. `cx-validate-auto` is **deliberately excluded**.
2. **Auto-restore**: any proposal with `rejected_by` outside the whitelist is restored to `status: pending` and logged as `[CORTEX SECURITY]`.
3. **Pre-ship acceptance test**: `tests/test_v329_acceptance.sh` injects a synthetic proposal with `rejected_by: "cx-validate-auto"` and asserts restoration. Tag v3.29.0 cannot be created unless this passes.

## What to do if the ghost reappears post-v3.29.0

1. `cx-status --pipeline` will show a new `unauthorized_rejections_restored` counter
2. `knowledge-log.md` will have `[CORTEX SECURITY]` entries
3. Investigation: find what process wrote those rejections → likely a script in PATH or a `launchd` daemon
4. If legitimate (user-installed quietly), add to whitelist intentionally; if malicious, file an issue

## Closure

This file is kept for historical record. Delete it when the v3.29.0 guard has been live ≥ 90 days with zero `[CORTEX SECURITY]` events.
