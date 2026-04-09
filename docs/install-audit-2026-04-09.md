# Install Audit — 2026-04-09

## File Inventory

| File | Installed? | Destination | Notes |
|------|-----------|-------------|-------|
| **Root Files** | | | |
| README.md | No | — | Documentation only |
| LICENSE | No | — | License file |
| CHANGELOG.md | No | — | Version history |
| SECURITY.md | No | — | Security policy |
| .gitignore | No | — | Git configuration |
| install.sh | No | — | Installer script itself |
| uninstall.sh | No | — | Uninstaller script |
| **hooks/*.sh** | Yes | ~/.claude/hooks/cortex/ | observe.sh, session-start.sh, injector.sh |
| **hooks/*.js** | Yes | ~/.claude/hooks/cortex/ | session-learner.js |
| **hooks/lib/*.py** | **NO — CRITICAL GAP** | — | dream_cycle.py, validate_instinct.py NOT copied |
| **commands/*.md** | Yes | ~/.claude/commands/ | 12 command files |
| **skills/cortex/SKILL.md** | Yes | ~/.claude/skills/cortex/SKILL.md | Main skill |
| **agents/*.md** | Yes | ~/.claude/skills/cortex/agents/ | 3 agent files |
| **core/memory.template.json** | Yes (fresh only) | ~/.claude/cortex/memory.json | Preserved on upgrade |
| **core/reflexes.default.json** | Yes (fresh only) | ~/.claude/cortex/reflexes.json | Preserved on upgrade |
| **core/claudemd-section.md** | Yes | ~/.claude/CLAUDE.md | Appended once, never updated |
| **seeds/laws/*.txt** | Yes (fresh only) | ~/.claude/cortex/laws/ | 5 seed laws |
| **seeds/instincts/*.yaml** | Yes (fresh only) | ~/.claude/cortex/instincts/global/ | 7 seed instincts |
| **rules/seed.md** | Yes (fresh only) | ~/.claude/cortex/instincts/global/ | Seed rule |
| **githooks/pre-push** | Yes (conditional) | .git/hooks/pre-push | Only if .git exists |
| **examples/** | No | — | Reference only |
| **docs/** | No | — | Documentation only |
| **tests/** | No | — | Test scripts only |

## Critical Issues Found

### 1. hooks/lib/ NEVER installed (CRITICAL)
- `hooks/lib/dream_cycle.py` and `hooks/lib/validate_instinct.py` are NOT copied by install.sh
- cx-dream command expects them at `~/.claude/hooks/cortex/lib/`
- **Impact**: `/cx-dream` will fail at runtime for any installed user

### 2. /cx-dream missing from claudemd-section.md
- `core/claudemd-section.md` lists 11 commands, should be 12
- Missing: `/cx-dream`

### 3. CLAUDE.md section never updated on upgrade
- If user has old "## Cortex" section, install.sh skips update
- User never gets updated command list or info

### 4. No version tracking
- No `~/.claude/cortex/version` file exists
- Installer can't show "upgrading from vX to vY"

### 5. `paste` command in session-start.sh (line 183)
- Not available on Windows Git Bash
- Should use `tr '\n' ';' | sed 's/;$//'` instead

### 6. memory.template.json says version "2.1.0"
- Should say "3.0.x" for current release

## Cross-Reference Verification

| Check | Status | Details |
|-------|--------|---------|
| observe.sh → Python libs | CLEAN | Uses inline Python only |
| cx-dream.md → hooks/lib | BROKEN | Path `~/.claude/hooks/cortex/lib` never created |
| session-learner.js → Python | CLEAN | Pure Node.js |
| install.sh → hooks/lib | MISSING | Zero mentions of "lib" |
| settings.json hook paths | CLEAN | All correct |
| claudemd-section.md commands | MISSING cx-dream | 11 of 12 listed |
| reflexes.default.json | VALID | 8 reflexes, proper schema |
| Skill agent installation | CORRECT | 3 agents properly copied |
