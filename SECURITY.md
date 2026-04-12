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
- Command injection via hooks (`observe.py`, `session-start.py`, `injector.sh`, `injector-engine.js`)
- Secret leakage in observation logs
- Path traversal in project detection or backup/restore
- ReDoS in instinct trigger regex patterns
- Race conditions in file writes (observations, settings)
- Permission issues on generated files

### Out of scope

- Vulnerabilities in Claude Code itself (report to [Anthropic](https://www.anthropic.com/security))
- Issues requiring physical access to the machine
- Social engineering attacks

## Security Measures (v3.6)

- Prompt injection sanitization on all injected text (instinct actions, context.md, EOD resume)
- `execFileSync` instead of `execSync` to prevent command injection
- 12-pattern secret scrubbing (AWS, GitHub, Stripe, Slack, Anthropic, OpenAI, Google, JWT, PEM, SSH, connection strings)
- ReDoS protection on all regex compilation (length limit, nested quantifier ban, timeout test)
- Atomic file writes via `tmp+rename` pattern (settings.json, observations, obs-count)
- File locking with `flock`/perl fallback for concurrent access
- `umask 077` for consistent permissions
- Instinct validation on import (blocked patterns, action length, wildcard trigger rejection)
- Per-user temp directories with auto-cleanup
- Debug logging behind `CORTEX_DEBUG=1` flag (no silent error swallowing)

## Security Tests

Run the full suite (124 tests, 8 suites):

```bash
bash tests/run_all.sh             # All 8 suites
bash tests/test_security.sh       # 7 security regression tests
bash tests/test_dream_cycle.sh    # 26 dream cycle tests
bash tests/test_observe.sh        # 7 observer tests (scrubbing, is_error, perf)
bash tests/test_session_learner.sh # 7 session learner tests
bash tests/test_injector.sh       # 14 injector tests (sanitization, ReDoS, limits)
bash tests/test_yaml_utils.sh     # 13 YAML parser tests
bash tests/test_install.sh        # 37 install tests (fresh, upgrade, security)
bash tests/test_hooks_e2e.sh      # 13 end-to-end pipeline tests
```
