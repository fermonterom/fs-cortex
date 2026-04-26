# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 3.x.x   | :white_check_mark: |
| 2.x.x   | :x:                |
| 1.x.x   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in fs-cortex, **do NOT open a public issue**.

Instead, please report it privately:

1. **Email**: info@fersora.com
2. **Subject**: `[fs-cortex] Security: <brief description>`
3. **Include**:
   - Affected file(s) and line number(s)
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

You will receive acknowledgment within 48 hours and a resolution timeline within 7 days.

## Scope

fs-cortex runs as Claude Code hooks with access to:
- Local filesystem (`~/.claude/cortex/`)
- Tool use observations (sanitized, secrets scrubbed)
- Git metadata (remote URLs, project roots)

### In scope

- Prompt injection via instinct action/trigger fields
- Command injection via hooks (`observe.py`, `session-start.py`, `injector.sh`, `injector.js`, `injector-engine.js`)
- Secret leakage in observation logs
- Path traversal in project detection or backup/restore
- ReDoS in instinct trigger regex patterns
- Race conditions in file writes (observations, settings)
- Permission issues on generated files

### Out of scope

- Vulnerabilities in Claude Code itself (report to [Anthropic](https://www.anthropic.com/security))
- Issues requiring physical access to the machine
- Social engineering attacks

## Security Measures

Baseline (since v3.6) — preserved and extended in every release:

- Prompt injection sanitization on all injected text (instinct actions, context.md, EOD resume)
- `execFileSync` instead of `execSync` to prevent command injection
- 12-pattern secret scrubbing (AWS, GitHub, Stripe, Slack, Anthropic, OpenAI, Google, JWT, PEM, SSH, connection strings)
- ReDoS protection on all regex compilation (length limit, nested quantifier ban, timeout test)
- Atomic file writes via `tmp+rename` pattern (settings.json, observations, obs-count, **impact.jsonl**, **YAML confidence rewrites in v3.20.0**)
- File locking with `flock`/perl fallback for concurrent access
- `umask 077` for consistent permissions
- Instinct validation on import (blocked patterns, action length, wildcard trigger rejection)
- Per-user temp directories with auto-cleanup
- Debug logging behind `CORTEX_DEBUG=1` flag (no silent error swallowing)

Added in v3.20.0 (Sprint 5):

- **Bounded outcome-ranking nudges** — `apply_outcome_nudges` cannot move an instinct's `confidence` outside `[0.10, 0.99]` per call, regardless of outcome history (see `docs/OUTCOME-RANKING.md`)
- **Reflex iids excluded** from confidence rewrites — only YAML instincts are touched; `reflex:*` iids are silently skipped to keep reflex accounting in `reflexes.json`
- **Subprocess timeout** on the Stop-hook nudge call (5s) — Python failures or hangs do not block the rest of the Stop pipeline
- **Sample-size floor** (`min_outcomes=5`) before any nudge — no single observation can swing confidence

## Security Tests

Run the full suite (**240 tests, 13 suites**):

```bash
bash tests/run_all.sh                    # All 13 suites

# Hook + library safety
bash tests/test_security.sh              #  7 security regression tests
bash tests/test_observe.sh               #  9 observer tests (scrubbing, is_error, sid round-trip)
bash tests/test_injector.sh              # 16 injector tests (sanitization, ReDoS, limits, .last-instinct)
bash tests/test_yaml_utils.sh            # 13 YAML parser tests

# Learning + housekeeping
bash tests/test_session_learner.sh       #  8 session learner tests
bash tests/test_dream_cycle.sh           # 35 Dream Cycle tests (dedup, contradictions, staleness)
bash tests/test_impact.sh                # 48 impact funnel tests (Sprint 0–5 incl. outcome ranking)
bash tests/test_migrate_legacy_iid.sh    # 12 migration script tests (v3.19.5)
bash tests/test_integrity.sh             # 14 integrity tests (commands, schemas, version consistency)

# Installer + lifecycle
bash tests/test_install.sh               # 42 install tests (fresh, upgrade, env merge, path traversal)
bash tests/test_uninstall.sh             # 13 uninstall tests (cleanup, backup, env removal)
bash tests/test_hooks_e2e.sh             # 14 end-to-end pipeline tests
pwsh tests/test_install_ps1.ps1          #  9 PowerShell installer tests (Windows-only in CI)
```

CI (`.github/workflows/test.yml`) runs all 12 bash suites on `ubuntu-latest` + `macos-latest` against Python 3.11/3.13 and Node 22/24, plus the PowerShell suite on `windows-latest`.
