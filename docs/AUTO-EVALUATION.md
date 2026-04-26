# AUTO-EVALUATION — Stop-time agent evaluation of reflex injections

> Introduced in **v3.18.0** (Sprint 1 · Auto-evaluation, follow-up to v3.17.0).
> Implements the "Alcance MAX" left as future work in
> [`AGENT-FEEDBACK.md`](AGENT-FEEDBACK.md).
> Writers: `hooks/lib/injector-engine.js` (inject), `hooks/session-learner.js` (feedback).
>
> ⚠️ **v3.18.0 → v3.19.0 were silently broken.** Three latent bugs in
> `session-learner.js` (`_sid` typo, hardcoded `CORTEX_DIR`, orphan-harness-sid
> filter) prevented `correlateReflexFeedback` and `correlateImpactEvents` from
> ever emitting agent-feedback events. **Fixed in v3.19.1** — see CHANGELOG.

This document is the architectural decision record for **why and how
the agent automatically rates reflex injections at session end**, and
the evaluator contract that lets each reflex declare what "successfully
followed" looks like.

---

## Problem

v3.17.0 split `useful_ratio_user` from `useful_ratio_agent` so the
Sprint 0.5 Gate stays a measure of human value. But the agent ratio
remained empty in practice, because:

1. **Reflexes never emit `inject` events.** Only instincts go through
   the impact funnel. The injector logs an `inject` event for each
   instinct it pushes into PreToolUse, but reflexes are silent.
2. **Manual `/cx-feedback-auto` is a fallback, not a baseline.** The
   agent can only call it when it remembers to, and there is no
   structured evaluation. The data is sparse and inconsistent.
3. **Auto-disable depends on `noiseCount`** which is incremented by
   `/cx-feedback-auto`. Without auto-evaluation, a noisy reflex never
   reaches the threshold organically.

The DA follow-up audit (2026-04-25, this same session) demonstrated the
gap live: 11 reflex fires, 0 in the funnel, 4 manually rated by the
agent. The other 7 left no trace.

---

## Decision

Add **two cooperating mechanisms**:

1. **Reflex inject events** — `injector-engine.js` emits an `ev: inject`
   event with `iid: reflex:<id>` for every reflex it fires. Same shape
   as the existing instinct inject events, just a different prefix.
2. **Stop-time evaluator** — `session-learner.js`, which already runs
   at Stop and processes observations.jsonl, gains a reflex evaluator.
   For each `inject` event with `iid: reflex:*`, it calls a per-reflex
   evaluator function and emits a `feedback` event with `source: agent`.

Each reflex declares its own evaluator in
`core/reflexes.default.json` via a new optional `evaluator` field. If
absent, the reflex is treated as un-evaluable and no feedback is
emitted (preserves backward compatibility with custom user reflexes).

---

## Evaluator contract

Three evaluator types cover the 10 default reflexes:

### Type A — `tool-substitution`
The reflex recommends switching tool. Useful if the next tool call
within `window` events uses the recommended `expected_tool`. Noise if
the same problematic tool keeps being used. Ignore otherwise.

```json
{
  "type": "tool-substitution",
  "expected_tool": "Glob",
  "anti_tool": "Bash",
  "anti_pattern": "find ",
  "window": 3
}
```

Used by: `bash-find-use-glob`, `bash-cat-use-read`.

### Type B — `precondition-check`
The reflex demands a precondition. Useful if the precondition was
satisfied before the matched call (e.g. Read of file before Edit).
Noise if Edit fired but no Read of that path was in the prior window.
Ignore if the matched call ran cleanly without is_error.

```json
{
  "type": "precondition-check",
  "precondition_tool": "Read",
  "match_field": "file_path",
  "lookback": 10
}
```

Used by: `read-before-edit`.

### Type C — `error-monitor`
The reflex reminds about a class of risks (env commit, missing tests,
security headers). The semantics shipped in v3.19.4 are:

- **`useful`** — at least one follow-up observation exists in the window
  AND no observation matches `error_pattern`. The reminder either
  prevented the failure or was redundant-but-aligned.
- **`noise`** — an observation matching `error_pattern` fires within the
  window. The reminder did not prevent the failure.
- **`ignore`** — no follow-up observations at all (no signal either way).

Pre-v3.19.4 the evaluator only ever returned `noise` or `ignore`, which
condemned 16 of 21 reflexes with this type to `useful: 0` and
structurally biased the agent funnel toward noise. See CHANGELOG v3.19.4.

```json
{
  "type": "error-monitor",
  "error_pattern": "secret|key|token|leaked|exposed",
  "window": 10
}
```

Used by: `env-never-commit`, `git-commit-quality`, `git-push-safety`,
`git-merge-verify`, `api-auth-check`, `security-headers`,
`test-after-change`.

### Default behavior

If an `evaluator` field is absent (e.g. user-added custom reflex from
v3.17.x or earlier, or `instinct-downvote` / `capture-decision` which
are intentionally meta-reflexes), the evaluator returns `ignore` and
no feedback is emitted. This is the **safe default** — never fabricate
signal for reflexes we cannot evaluate.

---

## Reflex schema addition

```jsonc
{
  "id": "bash-find-use-glob",
  "matcher": "Bash",
  "condition": "find ",
  "action": "...",
  "severity": "medium",
  "enabled": true,
  "fireCount": 0,
  "lastFired": null,

  // NEW in v3.18.0 (optional, backward compatible):
  "evaluator": {
    "type": "tool-substitution",
    "expected_tool": "Glob",
    "anti_tool": "Bash",
    "anti_pattern": "find ",
    "window": 3
  },
  "noiseCount": 0,        // tracked from v3.17.0; auto-eval makes it organic
  "usefulCount": 0        // NEW: surfaces in /cx-status --reflexes
}
```

`reflexes.json` (the user's runtime copy) is migrated lazily — when
session-learner first writes back, it adds the new fields. Pre-v3.18
files keep working until then.

---

## Inject event for reflexes

The injector currently emits inject events only for instincts via
`logInjectBatch([{id, confidence, domain}, ...], {tool, pid, sid})`.
v3.18.0 extends this to also batch the matched reflexes:

```js
// New: reflexes contribute their own inject batch
if (matchedReflexes.length && impactLog) {
  impactLog.logInjectBatch(
    matchedReflexes.map(r => ({
      id: `reflex:${r.id}`,
      confidence: 0,        // reflexes have no confidence
      domain: 'reflex'
    })),
    { tool: toolName, pid: project.id, sid: sessionId }
  );
}
```

The `reflex:` prefix in `iid` lets readers cleanly distinguish reflex
events from instinct events without a separate enum field.

---

## Stop-time evaluation flow

`hooks/session-learner.js` already loads observations and emits
`follow` events for instincts. v3.18.0 adds a parallel pass for
reflexes:

```
1. Read impact.jsonl events from this session (sid match)
2. Collect inject events with iid prefix "reflex:"
3. For each reflex inject:
     a. Find the reflex in reflexes.json by stripping the prefix
     b. Look up its evaluator (or skip if absent)
     c. Find the matched tool call in observations.jsonl by ts proximity
     d. Find the next N events in the same session
     e. Run the evaluator → useful | noise | ignore
     f. Emit feedback event with source: agent
     g. Update reflex.usefulCount / reflex.noiseCount accordingly
4. Apply auto-disable check (still gated behind env flag in v3.18)
```

The evaluation is best-effort — any error is logged but does not block
session-learner. Pre-v3.18 sessions without reflex inject events
simply produce zero new feedback events.

---

## Auto-disable threshold

Same gate, but as of v3.19.0 enabled by default via the installer
(see "Activation" below):

```
if (reflex.noiseCount >= 3 AND reflex.fireCount >= 10
    AND env.CORTEX_AGENT_DISABLE_REFLEXES === '1') {
  reflex.enabled = false;
  log to knowledge-log.md
}
```

History:
- **v3.17.0** added `noiseCount`/`usefulCount` fields and the env-flag
  guard, but `noiseCount` had to be incremented manually via
  `/cx-feedback-auto`.
- **v3.18.0** automated `noiseCount` accumulation via the Stop-time
  evaluator. The env flag was still opt-in, so the threshold was
  tracked but the auto-disable never fired without manual export.
- **v3.19.0** flips the default. The installer writes
  `CORTEX_AGENT_DISABLE_REFLEXES=1` into `~/.claude/settings.json`'s
  `env` block. Users who don't want auto-disable can delete that key
  or set it to `"0"` / `""`. See "Activation".

## Activation — why settings.json `env` and not `.zshrc`

The auto-disable mechanism reads `process.env.CORTEX_AGENT_DISABLE_REFLEXES`
inside `session-learner.js`, which is launched by the Claude Code
harness as a `Stop` hook subprocess. The variable must be present in
that subprocess's environment.

**Naive approach: `~/.zshrc` / `~/.bashrc`.** This works for
**interactive shell** sessions: when the user opens Terminal and runs
`claude`, the shell sourced the rc file, the variable is exported, and
`claude` (and therefore session-learner) inherits it.

**The bug**: macOS and Windows GUI applications **do not source the
shell's rc files**. They are launched directly by the OS. The Claude
Code Desktop app, opened from Finder/Dock or the Start menu, never
sees `~/.zshrc`. The variable is missing, the auto-disable never
fires, the user thinks they activated it but nothing happens.

This is a long-standing macOS/Windows env var gotcha and has bitten
every CLI tool that tries to handoff config via shell rc files.

**The fix: `settings.json` `env` block.** The Claude Code harness
reads `~/.claude/settings.json` regardless of how it was launched
(Terminal, Desktop, IDE plugin) and injects every key in the `env`
object into every hook subprocess's environment. This works
identically across:

- macOS Terminal / iTerm
- macOS Claude Code Desktop app
- Windows Terminal / PowerShell
- Windows Claude Code Desktop app
- Linux any shell or DE

The installer (`install.sh` / `install.ps1`) writes the variable
during step 10 (configure hooks), idempotently — running the
installer twice does not duplicate or change anything. The uninstaller
(`uninstall.sh`) removes only the Cortex-managed keys; user-defined
`env` entries are preserved. If the env block becomes empty after
removal, the installer drops the `env` key entirely to keep
`settings.json` clean.

### How to opt out

Edit `~/.claude/settings.json` and either delete the key:

```json
{
  "env": {
    /* CORTEX_AGENT_DISABLE_REFLEXES removed */
  }
}
```

Or set it to a falsy value:

```json
{
  "env": {
    "CORTEX_AGENT_DISABLE_REFLEXES": "0"
  }
}
```

Either form makes `correlateReflexFeedback` skip the auto-disable
branch. `noiseCount` continues to accumulate (it's just diagnostic
data) but reflexes never get `enabled: false` automatically.

A future re-run of `bash install.sh` will see your existing key value
and not overwrite it (idempotent), so your opt-out is durable across
upgrades.

### Co-existence with shell rc files

If you have `export CORTEX_AGENT_DISABLE_REFLEXES=1` in your
`~/.zshrc` it doesn't conflict — interactive shells will see it from
the rc file, and GUI apps will see it from settings.json. Either path
works. v3.19.0's installer just removes the gotcha by ensuring the
GUI path is wired up automatically.

---

## `/cx-status --reflexes` panel

New flag. Reads `reflexes.json` and shows runtime stats:

```
REFLEX HEALTH (v3.18.0+):
  ID                    FIRES   USEFUL   NOISE   ENABLED   STATUS
  ───────────────────────────────────────────────────────────────────
  read-before-edit       1171    1100      45    yes       healthy
  env-never-commit       1171    1170       0    yes       healthy
  bash-find-use-glob       45      30      12    yes       borderline
  bash-cat-use-read        67      10      48    yes       NOISY (auto-disable candidate)
  test-after-change         9       8       0    yes       healthy
  ...

  Healthy   : 7   (useful >> noise)
  Borderline: 2   (noise approaching threshold)
  Noisy     : 1   (auto-disable candidate)
```

`STATUS` rules:
- `healthy`     → `useful >= 10 AND noise < 3`
- `borderline`  → `noise == 1 OR noise == 2`
- `NOISY`       → `noise >= 3 AND fireCount >= 10`
- `unknown`     → `fireCount < 10` (not enough data)

---

## Why this stays a minor bump (not major)

- Schema for `reflexes.json` adds optional fields. Old consumers ignore
  them.
- Schema for `impact.jsonl` is unchanged (still v:1). The
  `iid: reflex:*` convention is just a string prefix, not a new event
  type.
- Auto-disable stays opt-in. Default behavior of v3.17.x users is
  preserved exactly.

Version: v3.17.1 → v3.18.0.

---

## Privacy

Reflex inject events log:
- `iid` (e.g. `reflex:bash-find-use-glob`) — predefined, public
- `tool` — Claude Code tool name (Bash, Edit, ...) — already in inject
- `pid` / `sid` — already in inject

They do **NOT** log:
- The matched bash command text
- The file path being edited
- Any user code

Same privacy guarantees as `IMPACT-METRICS.md` apply.

---

## Testing

`tests/test_impact.sh` gains:

20. Reflex inject event has `iid` prefixed with `reflex:`
21. Tool-substitution evaluator returns `useful` when expected_tool follows
22. Tool-substitution evaluator returns `noise` when anti_pattern repeats
23. Precondition-check evaluator returns `useful` when precondition present
24. Error-monitor evaluator returns `noise` when error within window
25. Reflex without evaluator field returns `ignore` (no feedback emitted)
26. Auto-disable threshold respected only when env flag set

`tests/test_session_learner.sh` gains:

15. session-learner picks up reflex inject events from current sid
16. session-learner writes back reflexes.json with usefulCount/noiseCount

---

## Migration

- **Schema**: backward compatible. Pre-v3.18 reflexes.json missing
  `evaluator`/`usefulCount`/`noiseCount` fields are read with defaults.
- **Inject log**: events without `iid: reflex:*` are unaffected; old
  data parses unchanged.
- **Auto-disable**: still opt-in via `CORTEX_AGENT_DISABLE_REFLEXES=1`,
  same flag as v3.17.0. No surprise behavior change.
- **`reflexes.default.json`**: shipped with evaluator metadata for the
  10 default reflexes. Custom user reflexes (added via /cx-distill or
  manual edit) without evaluator simply skip auto-evaluation.

---

## Stability contract

- `iid: reflex:<id>` is now a **public convention**. Readers may rely
  on the prefix. New event sources (e.g. a future `/cx-feedback-auto`
  rewrite) MUST use the same prefix when targeting reflexes.
- Evaluator types `tool-substitution` / `precondition-check` /
  `error-monitor` are frozen for v:1. Adding new types requires no
  schema bump (the `type` field is open) but each implementation must
  return one of `useful` | `noise` | `ignore`.
- Reflex schema: `evaluator`, `usefulCount`, `noiseCount` are the only
  new optional fields. Renaming any of these requires a migration.

---

## What MAX did not include (still future work)

- **Default-on auto-disable** — still opt-in. Will revisit for v3.19+
  after seeing real data.
- **Per-project reflexes** — still global only.
- **Reflex confidence** — explicitly skipped. Reflexes are
  deterministic by design.
- **A/B experiments** — out of scope (mentioned in Sprint 5+).
- **User-facing reflex authoring command** — still requires manual
  edit of `reflexes.default.json`.

---

## Referenced by

- `hooks/lib/injector-engine.js` — emits reflex inject events
- `hooks/session-learner.js` — evaluator + feedback emission
- `core/reflexes.default.json` — evaluator metadata for 10 reflexes
- `commands/cx-status.md` — `--reflexes` flag
- `tests/test_impact.sh` — extended (20-26)
- `tests/test_session_learner.sh` — extended (15-16)
- `CHANGELOG.md` v3.18.0 entry
- `docs/AGENT-FEEDBACK.md` — closed loop (was "future work")
- `docs/IMPACT-METRICS.md` — schema reference
