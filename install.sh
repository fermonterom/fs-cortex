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

if [ -d "$CORTEX_DIR" ]; then
    HAS_CORTEX=true
    # Check if there's actual learned data
    LAW_COUNT=$(find "$CORTEX_DIR/laws" -maxdepth 1 -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
    INSTINCT_COUNT=$(find "$CORTEX_DIR/instincts" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
    print_warn "Existing cortex installation detected (${LAW_COUNT} laws, ${INSTINCT_COUNT} instincts)"
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
    if [ -n "$IMPORT_BACKUP" ] && [ ! -f "$IMPORT_BACKUP" ]; then
        print_error "File not found: $IMPORT_BACKUP"
        IMPORT_BACKUP=""
    fi
fi

# Step 4: Create directory structure
print_step "Creating directory structure..."
mkdir -p "$CORTEX_DIR"/{laws/archive,instincts/{personal,inherited},projects,evolved/{skills,commands,agents},exports,daily-summaries}
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
if [ ! -f "$CORTEX_DIR/catalog.json" ]; then
    cp "$SCRIPT_DIR/core/catalog.default.json" "$CORTEX_DIR/catalog.json"
    print_ok "Created catalog.json"
else
    print_warn "catalog.json exists, preserving user data"
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

# Step 8: Install hooks
print_step "Installing hooks..."
mkdir -p "$HOOKS_DIR"
for hook in "$SCRIPT_DIR/hooks/"*.sh; do
    [ -f "$hook" ] && cp "$hook" "$HOOKS_DIR/" && chmod +x "$HOOKS_DIR/$(basename "$hook")"
done
print_ok "Hooks installed to ~/.claude/hooks/cortex/"

# Step 9: Install seed instinct (only if not already present)
print_step "Installing seed instinct..."
if [ -f "$CORTEX_DIR/instincts/personal/read-instructions-before-executing.yaml" ]; then
    print_warn "Seed instinct already exists, preserving"
elif [ -f "$SCRIPT_DIR/rules/seed.md" ]; then
    cp "$SCRIPT_DIR/rules/seed.md" "$CORTEX_DIR/instincts/personal/read-instructions-before-executing.yaml"
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

# Define cortex hooks
cortex_hooks = {
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
            "matcher": "Bash",
            "hooks": [{
                "type": "command",
                "command": "bash ~/.claude/hooks/cortex/git-guard.sh",
                "timeout": 5000
            }]
        },
        {
            "matcher": "*",
            "hooks": [{
                "type": "command",
                "command": "bash ~/.claude/hooks/cortex/reflex-engine.sh",
                "timeout": 500
            }]
        },
        {
            "matcher": "*",
            "hooks": [{
                "type": "command",
                "command": "bash ~/.claude/hooks/cortex/observe.sh pre",
                "timeout": 10000,
                "async": True
            }]
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
    ]
}

# Merge cortex hooks with existing (remove old cortex hooks, keep others)
existing_hooks = settings.get("hooks", {})
for event, handlers in cortex_hooks.items():
    existing = existing_hooks.get(event, [])
    cleaned = [
        h for h in existing
        if not any(
            "cortex" in str(hook.get("command", ""))
            for hook in h.get("hooks", [])
        )
    ]
    existing_hooks[event] = cleaned + handlers

settings["hooks"] = existing_hooks

# Write
with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
then
    print_ok "Hooks configured in settings.json"
else
    print_error "Failed to configure hooks. Check that settings.json is valid JSON."
fi

# Step 11: Append to CLAUDE.md
print_step "Updating CLAUDE.md..."
if [ -f "$CLAUDE_MD" ]; then
    if ! grep -q "## Cortex" "$CLAUDE_MD" 2>/dev/null; then
        echo "" >> "$CLAUDE_MD"
        cat "$SCRIPT_DIR/core/claudemd-section.md" >> "$CLAUDE_MD"
        print_ok "Cortex section appended to CLAUDE.md"
    else
        print_warn "Cortex section already exists in CLAUDE.md"
    fi
else
    cp "$SCRIPT_DIR/core/claudemd-section.md" "$CLAUDE_MD"
    print_ok "Created CLAUDE.md with Cortex section"
fi

# Step 12: Import backup (if provided)
if [ -n "$IMPORT_BACKUP" ]; then
    print_step "Importing backup..."
    TEMP_DIR=$(mktemp -d)
    if tar -xzf "$IMPORT_BACKUP" -C "$TEMP_DIR" 2>/dev/null; then
        # Copy laws (|| true: macOS cp -n returns 1 if target exists)
        [ -d "$TEMP_DIR/laws" ] && { cp -n "$TEMP_DIR/laws/"*.txt "$CORTEX_DIR/laws/" 2>/dev/null || true; }
        # Copy instincts
        [ -d "$TEMP_DIR/instincts/personal" ] && { cp -n "$TEMP_DIR/instincts/personal/"*.yaml "$CORTEX_DIR/instincts/personal/" 2>/dev/null || true; }
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
            mkdir -p "$CORTEX_DIR/projects/$proj_id/instincts/personal"
            cp -n "$proj_dir/personal/"*.yaml "$CORTEX_DIR/projects/$proj_id/instincts/personal/" 2>/dev/null || true
        done
        # Copy evolved content
        [ -d "$TEMP_DIR/evolved" ] && { cp -r -n "$TEMP_DIR/evolved/"* "$CORTEX_DIR/evolved/" 2>/dev/null || true; }
        # Copy daily summaries
        [ -d "$TEMP_DIR/daily-summaries" ] && { cp -n "$TEMP_DIR/daily-summaries/"*.md "$CORTEX_DIR/daily-summaries/" 2>/dev/null || true; }

        IMPORTED_LAWS=$(find "$CORTEX_DIR/laws" -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
        IMPORTED_INST=$(find "$CORTEX_DIR/instincts/personal" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
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
with open(mem_path, "w") as f:
    json.dump(mem, f, indent=2)
' 2>/dev/null || true

    # Create seed law
    mkdir -p "$CORTEX_DIR/laws"
    echo "Always read documentation and instructions before executing any skill or command." > "$CORTEX_DIR/laws/read-first.txt"
    print_ok "Seed law created"
fi

# Step 14: Summary
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Installation complete!${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Data:${NC}      ~/.claude/cortex/"
echo -e "  ${BOLD}Skill:${NC}     ~/.claude/skills/cortex/SKILL.md"
echo -e "  ${BOLD}Commands:${NC}  $(ls "$SCRIPT_DIR/commands/"*.md 2>/dev/null | xargs -I{} basename {} .md | sed 's/^/\//' | tr '\n' ', ' | sed 's/,$//')"
echo -e "  ${BOLD}Hooks:${NC}     ~/.claude/hooks/cortex/"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Open Claude Code and work normally"
echo -e "  2. Laws inject automatically at session start"
echo -e "  3. Run ${BOLD}/cx-learn${NC} when suggested to crystallize patterns"
echo ""
if [ -n "$IMPORT_BACKUP" ]; then
    echo -e "  ${YELLOW}Knowledge imported from backup.${NC}"
fi
echo ""
