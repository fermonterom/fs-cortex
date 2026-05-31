#!/bin/bash
# fs-cortex installer
# Usage: bash install.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
CORTEX_DIR="$CLAUDE_DIR/cortex"
SKILLS_DIR="$CLAUDE_DIR/skills"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks/cortex"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
NEW_VERSION="3.34.0"

# v3.25.1 — explicit downgrade flag. The installer is a copy-not-merge of
# hooks/commands, so running an older `install.sh` over a newer install
# silently rewinds your hooks while preserving counters — the failure mode
# that hit on 2026-05-07 when the local repo was not pulled before
# `bash install.sh`. Default is now: abort on downgrade unless the operator
# explicitly opts in.
ALLOW_DOWNGRADE=false
for arg in "$@"; do
    case "$arg" in
        --allow-downgrade) ALLOW_DOWNGRADE=true ;;
    esac
done

# version_lt A B → return 0 (true) iff A < B in semver order. Uses sort -V
# which is GNU+BSD sort -V on macOS 14+ and stock Linux. Identical versions
# return 1 (false) so the caller can branch into a no-op or upgrade path.
version_lt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

print_header() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  fs-cortex — Continuous Learning for Claude Code${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
print_ok() { echo -e "${GREEN}  ✓${NC} $1"; }
print_warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
print_error() { echo -e "${RED}  ✗${NC} $1"; }

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local yn
    if [ "$default" = "y" ]; then
        read -rp "$(echo -e "${BOLD}$prompt [Y/n]:${NC} ")" yn
        yn="${yn:-y}"
    else
        read -rp "$(echo -e "${BOLD}$prompt [y/N]:${NC} ")" yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

# --- Start ---
print_header

# Step 1: Prerequisites
print_step "Checking prerequisites..."

# Check Claude Code directory
if [ ! -d "$CLAUDE_DIR" ]; then
    print_error "~/.claude/ not found. Is Claude Code installed?"
    exit 1
fi
print_ok "Claude Code directory found"

# Check python3
PYTHON_CMD=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    print_error "Python 3 not found. Required for observation hooks."
    exit 1
fi
print_ok "Python found: $PYTHON_CMD"

# Check bash version
BASH_VER="${BASH_VERSINFO[0]}"
if [ "$BASH_VER" -lt 4 ] 2>/dev/null; then
    print_warn "Bash $BASH_VER detected. Some features work better with bash 4+."
fi

# Step 2: Check for existing installations
print_step "Checking for existing installations..."

HAS_CORTEX=false
INSTALLED_VERSION="none"

if [ -d "$CORTEX_DIR" ]; then
    HAS_CORTEX=true
    # Detect installed version
    if [ -f "$CORTEX_DIR/version" ]; then
        INSTALLED_VERSION=$(cat "$CORTEX_DIR/version" 2>/dev/null | tr -d '[:space:]')
    fi
    # Check if there's actual learned data
    LAW_COUNT=$(find "$CORTEX_DIR/laws" -maxdepth 1 -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
    INSTINCT_COUNT=$(find "$CORTEX_DIR/instincts" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$INSTALLED_VERSION" = "none" ]; then
        print_warn "Legacy cortex installation detected (${LAW_COUNT} laws, ${INSTINCT_COUNT} instincts)"
        print_step "Upgrading to v${NEW_VERSION}"
    elif version_lt "$NEW_VERSION" "$INSTALLED_VERSION"; then
        # Downgrade detected. Abort unless explicitly opted in.
        echo "" >&2
        echo -e "${RED}${BOLD}DOWNGRADE BLOCKED${NC}" >&2
        echo -e "${RED}  Installed: v${INSTALLED_VERSION}${NC}" >&2
        echo -e "${RED}  This installer ships: v${NEW_VERSION}${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}Likely cause: this repository copy is behind the remote.${NC}" >&2
        echo -e "${YELLOW}Try:${NC}" >&2
        echo -e "${YELLOW}  cd $(pwd) && git pull origin main${NC}" >&2
        echo -e "${YELLOW}  bash install.sh${NC}" >&2
        echo "" >&2
        if [ "$ALLOW_DOWNGRADE" = "true" ]; then
            echo -e "${YELLOW}--allow-downgrade was passed — proceeding anyway.${NC}" >&2
            print_step "Downgrading from v${INSTALLED_VERSION} → v${NEW_VERSION}"
            print_ok "${LAW_COUNT} laws, ${INSTINCT_COUNT} instincts (preserved)"
        else
            echo -e "${RED}If this is intentional, re-run with --allow-downgrade.${NC}" >&2
            echo "" >&2
            exit 1
        fi
    elif [ "$INSTALLED_VERSION" = "$NEW_VERSION" ]; then
        print_step "fs-cortex v${INSTALLED_VERSION} already installed — refreshing files"
        print_ok "${LAW_COUNT} laws, ${INSTINCT_COUNT} instincts (preserved)"
    else
        print_step "Detected fs-cortex v${INSTALLED_VERSION} → upgrading to v${NEW_VERSION}"
        print_ok "${LAW_COUNT} laws, ${INSTINCT_COUNT} instincts (preserved)"
    fi
    echo -e "${YELLOW}Existing data will be preserved. Only hooks, commands, and skill will be updated.${NC}"
    if ! ask_yes_no "Update cortex installation?" "y"; then
        echo "Installation cancelled."
        exit 0
    fi
fi

# Step 3: Check for backup to import
IMPORT_BACKUP=""
if ! $HAS_CORTEX; then
    echo ""
    echo -e "${BOLD}Do you have a backup from a previous Cortex installation?${NC}"
    echo "  (Created with /cx-backup — a .tar.gz file)"
    read -rp "  Path to backup (or Enter to skip): " IMPORT_BACKUP
    if [ -n "$IMPORT_BACKUP" ]; then
        if [ ! -f "$IMPORT_BACKUP" ]; then
            print_warn "Not a valid file: $IMPORT_BACKUP — skipping backup import"
            IMPORT_BACKUP=""
        elif ! tar -tzf "$IMPORT_BACKUP" >/dev/null 2>&1; then
            print_warn "Not a valid .tar.gz archive — skipping backup import"
            IMPORT_BACKUP=""
        fi
    fi
fi

# Step 4: Create directory structure (v2.0)
print_step "Creating directory structure..."
mkdir -p "$CORTEX_DIR"/{laws/archive,instincts/{global,archive},projects,evolved/{skills,commands,rules,agents},exports,daily-summaries,log}
chmod 700 "$CORTEX_DIR"
print_ok "Created ~/.claude/cortex/"

# Create knowledge-log.md (append-only event log) — only if not already present
KNOWLEDGE_LOG="$CORTEX_DIR/knowledge-log.md"
if [ ! -f "$KNOWLEDGE_LOG" ]; then
    touch "$KNOWLEDGE_LOG"
    chmod 600 "$KNOWLEDGE_LOG"
    print_ok "Created knowledge-log.md (event log)"
fi

# Step 5: Copy core files (preserve existing data on reinstall)
print_step "Installing core files..."
if [ ! -f "$CORTEX_DIR/memory.json" ]; then
    cp "$SCRIPT_DIR/core/memory.template.json" "$CORTEX_DIR/memory.json"
    print_ok "Created memory.json"
else
    print_warn "memory.json exists, preserving user data"
    # Migrate memory.json: remove dead identity block, update version (v3.12.0+)
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, os, tempfile
mem_path = '$CORTEX_DIR/memory.json'
try:
    with open(mem_path) as f:
        mem = json.load(f)
    changed = False
    if 'identity' in mem:
        del mem['identity']
        changed = True
    cur = mem.get('version', '0.0.0')
    cur_parts = tuple(int(x) for x in cur.split('.') if x.isdigit())
    if cur_parts < (3, 12, 0):
        mem['version'] = '3.12.0'
        changed = True
    if changed:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(mem_path), suffix='.tmp')
        with os.fdopen(fd, 'w') as f:
            json.dump(mem, f, indent=2)
            f.write('\n')
        os.replace(tmp, mem_path)
        print('  Migrated memory.json (removed identity, updated version)')
except Exception as e:
    pass
" 2>/dev/null
    fi
fi
if [ ! -f "$CORTEX_DIR/reflexes.json" ]; then
    cp "$SCRIPT_DIR/core/reflexes.default.json" "$CORTEX_DIR/reflexes.json"
    print_ok "Created reflexes.json"
else
    print_warn "reflexes.json exists, preserving user data"
    # Migrate reflexes: add new + update matcher/condition/action of existing (v3.10.6+)
    # Preserves user runtime data: fireCount, lastFired, enabled
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
rpath = '$CORTEX_DIR/reflexes.json'
dpath = '$SCRIPT_DIR/core/reflexes.default.json'
try:
    with open(rpath) as f: user = json.load(f)
    with open(dpath) as f: defaults = json.load(f)
    user_by_id = {r['id']: r for r in user.get('reflexes', [])}
    added, updated = 0, 0
    for d in defaults.get('reflexes', []):
        if d['id'] not in user_by_id:
            user['reflexes'].append(d)
            added += 1
        else:
            u = user_by_id[d['id']]
            changed = False
            for field in ('matcher', 'condition', 'action', 'severity'):
                if field in d and u.get(field) != d[field]:
                    u[field] = d[field]
                    changed = True
            # v3.23.3+ also propagate evaluator.anti_pattern (matcher fix needs both)
            if 'evaluator' in d and isinstance(d['evaluator'], dict):
                u_eval = u.get('evaluator', {})
                if isinstance(u_eval, dict):
                    for sub in ('anti_pattern', 'expected_tool', 'anti_tool',
                                'precondition_tool', 'match_field', 'lookback',
                                'window', 'error_pattern', 'type'):
                        if sub in d['evaluator'] and u_eval.get(sub) != d['evaluator'][sub]:
                            u_eval[sub] = d['evaluator'][sub]
                            changed = True
                    u['evaluator'] = u_eval
            if changed:
                updated += 1
    if added or updated:
        with open(rpath, 'w') as f: json.dump(user, f, indent=2)
        parts = []
        if added: parts.append(str(added) + ' new')
        if updated: parts.append(str(updated) + ' updated')
        print('  Reflexes migrated: ' + ', '.join(parts))
except Exception as e:
    print(f'  Reflex migration skipped: {e}', file=sys.stderr)
" 2>/dev/null
    fi
fi
print_ok "Core files ready"

# Step 6: Install skill
print_step "Installing cortex skill..."
mkdir -p "$SKILLS_DIR/cortex/agents"
cp "$SCRIPT_DIR/skills/cortex/SKILL.md" "$SKILLS_DIR/cortex/SKILL.md"
cp "$SCRIPT_DIR/agents/"*.md "$SKILLS_DIR/cortex/agents/" 2>/dev/null || true
print_ok "Skill installed to ~/.claude/skills/cortex/"

# Step 7: Install commands
print_step "Installing commands..."
mkdir -p "$COMMANDS_DIR"
for cmd in "$SCRIPT_DIR/commands/"*.md; do
    [ -f "$cmd" ] && cp "$cmd" "$COMMANDS_DIR/"
done
INSTALLED_CMDS=$(ls "$SCRIPT_DIR/commands/"*.md 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ', ' | sed 's/,$//')
print_ok "Commands installed: $INSTALLED_CMDS"

# Step 8: Install hooks (v3.10: observe.py, session-start.py, injector.sh, session-learner.js)
print_step "Installing hooks..."
mkdir -p "$HOOKS_DIR"

# Remove legacy shell hooks replaced by Python in v3.10.0
for legacy in "$HOOKS_DIR/session-start.sh" "$HOOKS_DIR/observe.sh"; do
    if [ -f "$legacy" ]; then
        echo "  Removing legacy hook: $(basename "$legacy")"
        rm -f "$legacy"
    fi
done

for hook in "$SCRIPT_DIR/hooks/"*.sh "$SCRIPT_DIR/hooks/"*.js "$SCRIPT_DIR/hooks/"*.py; do
    [ -f "$hook" ] && cp "$hook" "$HOOKS_DIR/" && chmod +x "$HOOKS_DIR/$(basename "$hook")"
done
print_ok "Hooks installed to ~/.claude/hooks/cortex/"

# Step 8a: Install lib modules (Python + JS)
if [ -d "$SCRIPT_DIR/hooks/lib" ]; then
    mkdir -p "$HOOKS_DIR/lib"
    for libfile in "$SCRIPT_DIR/hooks/lib/"*.py "$SCRIPT_DIR/hooks/lib/"*.js; do
        [ -f "$libfile" ] && cp "$libfile" "$HOOKS_DIR/lib/"
    done
    print_ok "Lib modules installed to ~/.claude/hooks/cortex/lib/"
fi

# Step 8b: Install git pre-push hook (version+changelog enforcement)
# v3.21.1 fix: use --absolute-git-dir; previous --git-dir returned a relative
# `.git` when invoked from outside the repo, breaking `cp` (resolved against CWD).
if git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir >/dev/null 2>&1; then
    GIT_HOOKS_DIR="$(git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir 2>/dev/null)/hooks"
    if [ -f "$SCRIPT_DIR/githooks/pre-push" ] && [ -d "$GIT_HOOKS_DIR" ]; then
        cp "$SCRIPT_DIR/githooks/pre-push" "$GIT_HOOKS_DIR/pre-push"
        chmod +x "$GIT_HOOKS_DIR/pre-push"
        print_ok "Git pre-push hook installed (version+changelog guard)"
    fi
fi

# Step 9: Install seed instinct (only if not already present)
print_step "Installing seed instinct..."
if [ -f "$CORTEX_DIR/instincts/global/read-instructions-before-executing.yaml" ]; then
    print_warn "Seed instinct already exists, preserving"
elif [ -f "$SCRIPT_DIR/rules/seed.md" ]; then
    cp "$SCRIPT_DIR/rules/seed.md" "$CORTEX_DIR/instincts/global/read-instructions-before-executing.yaml"
    print_ok "Seed instinct installed"
else
    print_warn "Seed rule not found, skipping"
fi

# Step 10: Configure settings.json
print_step "Configuring hooks in settings.json..."

if [ -f "$SETTINGS_FILE" ]; then
    # Backup
    BACKUP_FILE="${SETTINGS_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$SETTINGS_FILE" "$BACKUP_FILE"
    print_ok "Backup: $BACKUP_FILE"
fi

# Use Python to safely merge hooks into settings.json
if "$PYTHON_CMD" << 'PYEOF'
import json, os

settings_file = os.path.expanduser("~/.claude/settings.json")

# Read existing settings
settings = {}
if os.path.exists(settings_file):
    with open(settings_file) as f:
        settings = json.load(f)

# Ensure structure
settings.setdefault("permissions", {})
settings["permissions"].setdefault("allow", [])
settings["permissions"].setdefault("additionalDirectories", [])

# Add cortex permissions
cortex_perms = [
    "Read(~/.claude/cortex/**)",
    "Edit(~/.claude/cortex/**)"
]
for perm in cortex_perms:
    if perm not in settings["permissions"]["allow"]:
        settings["permissions"]["allow"].append(perm)

if "~/.claude/cortex" not in settings["permissions"].get("additionalDirectories", []):
    settings["permissions"]["additionalDirectories"].append("~/.claude/cortex")

# Define cortex hooks (v3.10: observe.py direct, session-start.py, injector.sh, session-learner.js)
cortex_hooks = {
    "SessionStart": [
        {
            "hooks": [{
                "type": "command",
                "command": "python3 ~/.claude/hooks/cortex/session-start.py",
                "timeout": 5000
            }]
        },
        {
            "matcher": "compact",
            "hooks": [{
                "type": "command",
                "command": "python3 ~/.claude/hooks/cortex/session-start.py",
                "timeout": 5000
            }]
        }
    ],
    "PreToolUse": [
        {
            "matcher": "*",
            "hooks": [
                {
                    "type": "command",
                    "command": "python3 ~/.claude/hooks/cortex/observe.py pre",
                    "timeout": 10000,
                    "async": True
                },
                {
                    "type": "command",
                    "command": "bash ~/.claude/hooks/cortex/injector.sh",
                    "timeout": 3000
                }
            ]
        }
    ],
    "PostToolUse": [
        {
            "matcher": "*",
            "hooks": [{
                "type": "command",
                "command": "python3 ~/.claude/hooks/cortex/observe.py post",
                "timeout": 10000,
                "async": True
            }]
        }
    ],
    "Stop": [
        {
            "hooks": [{
                "type": "command",
                "command": "node ~/.claude/hooks/cortex/session-learner.js",
                "timeout": 15000
            }]
        }
    ],
    "PreCompact": [
        {
            "hooks": [{
                "type": "command",
                "command": "python3 ~/.claude/hooks/cortex/precompact.py",
                "timeout": 8000
            }]
        }
    ]
}

# Merge cortex hooks with existing (remove old cortex hooks, keep others)
existing_hooks = settings.get("hooks", {})
for event, handlers in cortex_hooks.items():
    existing = existing_hooks.get(event, [])
    cleaned = [
        h for h in existing
        if not any(
            "hooks/cortex/" in str(hook.get("command", ""))
            for hook in h.get("hooks", [])
        )
    ]
    existing_hooks[event] = cleaned + handlers

settings["hooks"] = existing_hooks

# v3.19.0 — Cortex env vars (auto-disable noisy reflexes by default)
# macOS GUI apps don't read ~/.zshrc, so we set CORTEX_AGENT_DISABLE_REFLEXES
# in settings.json so the harness injects it to every hook subprocess.
# Users can opt-out by deleting this entry or setting it to "" / "0".
# See docs/AUTO-EVALUATION.md for rationale.
settings.setdefault("env", {})
if "CORTEX_AGENT_DISABLE_REFLEXES" not in settings["env"]:
    settings["env"]["CORTEX_AGENT_DISABLE_REFLEXES"] = "1"

# Atomic write via tmp+rename
import tempfile
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(settings_file), suffix='.tmp')
try:
    with os.fdopen(tmp_fd, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, settings_file)
except:
    os.unlink(tmp_path)
    raise
PYEOF
then
    print_ok "Hooks configured in settings.json"
else
    print_error "Failed to configure hooks. Check that settings.json is valid JSON."
fi

# Step 11: Update CLAUDE.md (append on fresh, replace on upgrade)
print_step "Updating CLAUDE.md..."
if [ -f "$CLAUDE_MD" ]; then
    # Backup CLAUDE.md before any modification
    cp "$CLAUDE_MD" "${CLAUDE_MD}.backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    if grep -q "## Cortex" "$CLAUDE_MD" 2>/dev/null; then
        # UPGRADE: replace existing Cortex section with latest
        if [ -n "$PYTHON_CMD" ]; then
            "$PYTHON_CMD" -c '
import re, sys, os, tempfile
claude_md = os.path.expanduser("~/.claude/CLAUDE.md")
section_file = sys.argv[1]
with open(claude_md) as f:
    content = f.read()
with open(section_file) as f:
    new_section = f.read()
# Remove old section (from ## Cortex to next ## or EOF)
content = re.sub(
    r"\n*## Cortex \(Learning System\)\n.*?(?=\n## |\Z)",
    "",
    content,
    flags=re.DOTALL
)
# Append new section
content = content.rstrip() + "\n\n" + new_section + "\n"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(claude_md), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    f.write(content)
os.replace(tmp, claude_md)
' "$SCRIPT_DIR/core/claudemd-section.md" 2>/dev/null
            print_ok "Cortex section updated in CLAUDE.md"
        else
            print_warn "Cortex section exists but Python not available to update it"
        fi
    else
        # FRESH: append
        echo "" >> "$CLAUDE_MD"
        cat "$SCRIPT_DIR/core/claudemd-section.md" >> "$CLAUDE_MD"
        print_ok "Cortex section appended to CLAUDE.md"
    fi
else
    cp "$SCRIPT_DIR/core/claudemd-section.md" "$CLAUDE_MD"
    print_ok "Created CLAUDE.md with Cortex section"
fi

# Step 12: Import backup (if provided)
if [ -n "$IMPORT_BACKUP" ]; then
    print_step "Importing backup..."
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf '$TEMP_DIR'" EXIT
    # Validate archive: reject entries with path traversal (../) or absolute paths
    if tar -tzf "$IMPORT_BACKUP" 2>/dev/null | grep -qE '(^/|\.\.)'; then
        print_error "Backup archive contains unsafe paths (../ or absolute). Aborting import."
    elif tar -xzf "$IMPORT_BACKUP" -C "$TEMP_DIR" 2>/dev/null; then
        # Copy laws (|| true: macOS cp -n returns 1 if target exists)
        [ -d "$TEMP_DIR/laws" ] && { cp -n "$TEMP_DIR/laws/"*.txt "$CORTEX_DIR/laws/" 2>/dev/null || true; }
        # Copy instincts (v2.0: global instead of personal)
        [ -d "$TEMP_DIR/instincts/personal" ] && { cp -n "$TEMP_DIR/instincts/personal/"*.yaml "$CORTEX_DIR/instincts/global/" 2>/dev/null || true; }
        [ -d "$TEMP_DIR/instincts/global" ] && { cp -n "$TEMP_DIR/instincts/global/"*.yaml "$CORTEX_DIR/instincts/global/" 2>/dev/null || true; }
        # Copy memory.json (backup has real user data, overwrite template)
        [ -f "$TEMP_DIR/memory.json" ] && cp "$TEMP_DIR/memory.json" "$CORTEX_DIR/memory.json" 2>/dev/null
        # Copy reflexes.json (backup has user customizations, overwrite default)
        [ -f "$TEMP_DIR/reflexes.json" ] && cp "$TEMP_DIR/reflexes.json" "$CORTEX_DIR/reflexes.json" 2>/dev/null
        # Copy projects registry
        [ -f "$TEMP_DIR/projects/registry.json" ] && { cp -n "$TEMP_DIR/projects/registry.json" "$CORTEX_DIR/projects/registry.json" 2>/dev/null || true; }
        # Copy project instincts
        for proj_dir in "$TEMP_DIR/projects"/*/instincts; do
            [ -d "$proj_dir" ] || continue
            proj_id=$(basename "$(dirname "$proj_dir")")
            mkdir -p "$CORTEX_DIR/projects/$proj_id/instincts"
            cp -n "$proj_dir/"*.yaml "$CORTEX_DIR/projects/$proj_id/instincts/" 2>/dev/null || true
            [ -d "$proj_dir/personal" ] && cp -n "$proj_dir/personal/"*.yaml "$CORTEX_DIR/projects/$proj_id/instincts/" 2>/dev/null || true
        done
        # Copy evolved content
        [ -d "$TEMP_DIR/evolved" ] && { cp -r -n "$TEMP_DIR/evolved/"* "$CORTEX_DIR/evolved/" 2>/dev/null || true; }
        # Copy daily summaries
        [ -d "$TEMP_DIR/daily-summaries" ] && { cp -n "$TEMP_DIR/daily-summaries/"*.md "$CORTEX_DIR/daily-summaries/" 2>/dev/null || true; }

        IMPORTED_LAWS=$(find "$CORTEX_DIR/laws" -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
        IMPORTED_INST=$(find "$CORTEX_DIR/instincts" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
        print_ok "Backup imported: ${IMPORTED_LAWS} laws, ${IMPORTED_INST} instincts"
    else
        print_error "Failed to extract backup. Continuing with fresh install."
    fi
    rm -rf "$TEMP_DIR"
fi

# Step 13: Onboarding (only for fresh installs, not updates)
if ! $HAS_CORTEX && [ -z "$IMPORT_BACKUP" ]; then
    print_step "Setting up initial configuration..."

    # Populate memory.json with install date
    "$PYTHON_CMD" -c '
import json, os, datetime
mem_path = os.path.expanduser("~/.claude/cortex/memory.json")
with open(mem_path) as f:
    mem = json.load(f)
mem["stats"]["installed"] = datetime.datetime.now().strftime("%Y-%m-%d")
import tempfile
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(mem_path), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(mem, f, indent=2)
os.replace(tmp, mem_path)
' 2>/dev/null || true

    # Copy seed laws
    mkdir -p "$CORTEX_DIR/laws"
    if [ -d "$SCRIPT_DIR/seeds/laws" ]; then
        for law in "$SCRIPT_DIR/seeds/laws/"*.txt; do
            [ -f "$law" ] && cp "$law" "$CORTEX_DIR/laws/"
        done
        SEED_LAWS=$(ls "$SCRIPT_DIR/seeds/laws/"*.txt 2>/dev/null | wc -l | tr -d ' ')
        print_ok "Seed laws installed: $SEED_LAWS"
    fi

    # Copy seed instincts
    mkdir -p "$CORTEX_DIR/instincts/global"
    if [ -d "$SCRIPT_DIR/seeds/instincts" ]; then
        for inst in "$SCRIPT_DIR/seeds/instincts/"*.yaml; do
            [ -f "$inst" ] && cp "$inst" "$CORTEX_DIR/instincts/global/"
        done
        SEED_INST=$(ls "$SCRIPT_DIR/seeds/instincts/"*.yaml 2>/dev/null | wc -l | tr -d ' ')
        print_ok "Seed instincts installed: $SEED_INST"
    fi
fi

# Step 14: Write version marker
echo "$NEW_VERSION" > "$CORTEX_DIR/version"

# Step 15: Summary
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  fs-cortex v${NEW_VERSION} installed!${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""
if $HAS_CORTEX; then
    if [ "$INSTALLED_VERSION" = "none" ]; then
        echo -e "  ${BOLD}Upgraded:${NC}  legacy → v${NEW_VERSION}"
    else
        echo -e "  ${BOLD}Upgraded:${NC}  v${INSTALLED_VERSION} → v${NEW_VERSION}"
    fi
else
    echo -e "  ${BOLD}Install:${NC}   Fresh install"
fi
echo -e "  ${BOLD}Data:${NC}      ~/.claude/cortex/"
echo -e "  ${BOLD}Skill:${NC}     ~/.claude/skills/cortex/SKILL.md"
echo -e "  ${BOLD}Commands:${NC}  $(ls "$SCRIPT_DIR/commands/"*.md 2>/dev/null | xargs -I{} basename {} .md | sed 's/^/\//' | tr '\n' ', ' | sed 's/,$//')"
echo -e "  ${BOLD}Hooks:${NC}     ~/.claude/hooks/cortex/"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Open Claude Code and work normally"
echo -e "  2. Laws inject automatically at session start"
echo -e "  3. Run ${BOLD}/cx-analyze${NC} when suggested to detect patterns"
echo ""
if [ -n "$IMPORT_BACKUP" ]; then
    echo -e "  ${YELLOW}Knowledge imported from backup.${NC}"
fi
echo ""
