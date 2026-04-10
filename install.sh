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
NEW_VERSION="3.6.2"

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
mkdir -p "$CORTEX_DIR"/{laws/archive,instincts/{global,archive},projects,evolved/{skills,commands,rules},exports,daily-summaries,log}
chmod 700 "$CORTEX_DIR"
print_ok "Created ~/.claude/cortex/"

# Step 5: Copy core files (preserve existing data on reinstall)
print_step "Installing core files..."
if [ ! -f "$CORTEX_DIR/memory.json" ]; then
    cp "$SCRIPT_DIR/core/memory.template.json" "$CORTEX_DIR/memory.json"
    print_ok "Created memory.json"
else
    print_warn "memory.json exists, preserving user data"
fi
if [ ! -f "$CORTEX_DIR/reflexes.json" ]; then
    cp "$SCRIPT_DIR/core/reflexes.default.json" "$CORTEX_DIR/reflexes.json"
    print_ok "Created reflexes.json"
else
    print_warn "reflexes.json exists, preserving user data"
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

# Step 8: Install hooks (v2.0: observe.sh, session-start.sh, injector.sh, session-learner.js)
print_step "Installing hooks..."
mkdir -p "$HOOKS_DIR"
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
if [ -d "$SCRIPT_DIR/.git" ] || git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_HOOKS_DIR=$(git -C "$SCRIPT_DIR" rev-parse --git-dir 2>/dev/null)/hooks
    if [ -f "$SCRIPT_DIR/githooks/pre-push" ]; then
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

# Define cortex hooks (v2.0: 4 hooks — observe, session-start, injector, session-learner)
cortex_hooks = {
    # SessionStart fires once at normal session start. The "compact" matcher fires
    # specifically when /compact is used (context wipe). Both entries are needed
    # because they are separate events in Claude Code's hook system — the global
    # SessionStart does NOT fire on /compact. The compact entry re-injects laws
    # and context after the context window is cleared.
    "SessionStart": [
        {
            "hooks": [{
                "type": "command",
                "command": "bash ~/.claude/hooks/cortex/session-start.sh",
                "timeout": 5000
            }]
        },
        {
            "matcher": "compact",
            "hooks": [{
                "type": "command",
                "command": "bash ~/.claude/hooks/cortex/session-start.sh",
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
                    "command": "bash ~/.claude/hooks/cortex/observe.sh pre",
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
                "command": "bash ~/.claude/hooks/cortex/observe.sh post",
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

    # Populate memory.json with user input
    echo ""
    echo -e "${BOLD}Quick setup (press Enter to skip any):${NC}"
    read -rp "  Your name: " USER_NAME
    read -rp "  Your role: " USER_ROLE
    read -rp "  Language (en/es/...): " USER_LANG
    USER_LANG="${USER_LANG:-en}"

    export CX_USER_NAME="$USER_NAME"
    export CX_USER_ROLE="$USER_ROLE"
    export CX_USER_LANG="$USER_LANG"

    "$PYTHON_CMD" -c '
import json, os, datetime
mem_path = os.path.expanduser("~/.claude/cortex/memory.json")
with open(mem_path) as f:
    mem = json.load(f)
mem["identity"]["name"] = os.environ.get("CX_USER_NAME", "")
mem["identity"]["role"] = os.environ.get("CX_USER_ROLE", "")
mem["identity"]["language"] = os.environ.get("CX_USER_LANG", "en")
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
