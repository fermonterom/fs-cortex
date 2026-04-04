#!/bin/bash
# fs-cortex uninstaller
# Usage: bash uninstall.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${RED}${BOLD}  fs-cortex — Uninstaller${NC}"
echo ""

CLAUDE_DIR="$HOME/.claude"
CORTEX_DIR="$CLAUDE_DIR/cortex"

# Check if installed
if [ ! -d "$CORTEX_DIR" ] && [ ! -d "$CLAUDE_DIR/skills/cortex" ]; then
    echo "Cortex is not installed."
    exit 0
fi

# Show what will be removed
echo "This will remove:"
echo "  - ~/.claude/skills/cortex/ (skill)"
echo "  - ~/.claude/hooks/cortex/ (hooks)"
echo "  - ~/.claude/commands/cx-*.md (commands)"
echo "  - Cortex hooks from settings.json"
echo "  - Cortex section from CLAUDE.md"
echo ""
echo "Your learned data (~/.claude/cortex/) will be preserved by default."
echo ""

read -rp "$(echo -e "${BOLD}Are you sure? [y/N]:${NC} ")" confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Cancelled."
    exit 0
fi

# Backup knowledge data as portable archive
echo ""
echo -e "${YELLOW}Your learned knowledge (laws, instincts, reflexes) can be exported${NC}"
echo -e "${YELLOW}as a portable .tar.gz to import on another machine.${NC}"
read -rp "$(echo -e "${BOLD}Create portable backup before uninstalling? [Y/n]:${NC} ")" backup
backup="${backup:-y}"
BACKUP_FILE=""
if [[ "$backup" =~ ^[Yy] ]]; then
    BACKUP_FILE="$HOME/cortex-backup-$(date +%Y-%m-%d).tar.gz"
    if [ -d "$CORTEX_DIR" ]; then
        # Build list of items to backup (only knowledge, not raw observations)
        BACKUP_ITEMS=()
        for item in laws instincts memory.json reflexes.json evolved daily-summaries exports; do
            [ -e "$CORTEX_DIR/$item" ] && BACKUP_ITEMS+=("$item")
        done
        [ -f "$CORTEX_DIR/projects/registry.json" ] && BACKUP_ITEMS+=("projects/registry.json")
        # Include project instincts (not observations)
        for proj_inst in "$CORTEX_DIR"/projects/*/instincts; do
            [ -d "$proj_inst" ] || continue
            proj_id=$(basename "$(dirname "$proj_inst")")
            BACKUP_ITEMS+=("projects/$proj_id/instincts")
        done
        # Create backup in a single tar command
        if [ "${#BACKUP_ITEMS[@]}" -gt 0 ]; then
            if tar -czf "$BACKUP_FILE" -C "$CORTEX_DIR" "${BACKUP_ITEMS[@]}" 2>/dev/null; then
                echo -e "${GREEN}  Portable backup: $BACKUP_FILE${NC}"
                echo -e "  Import on new machine with: ${BOLD}/cx-restore $BACKUP_FILE${NC}"
            else
                echo -e "${RED}  ⚠ Backup failed! Check disk space and permissions.${NC}"
                echo -e "${RED}  Consider running /cx-backup from Claude Code before deleting data.${NC}"
                BACKUP_FILE=""
            fi
        else
            echo -e "${YELLOW}  ⚠ No data to backup${NC}"
            BACKUP_FILE=""
        fi
    fi
fi

# Remove cortex data directory
echo ""
read -rp "$(echo -e "${BOLD}Also delete learned data (laws, instincts, observations)? [y/N]:${NC} ")" delete_data
if [[ "$delete_data" =~ ^[Yy] ]]; then
    [ -d "$CORTEX_DIR" ] && rm -rf "$CORTEX_DIR" && echo "  Removed ~/.claude/cortex/"
else
    echo -e "  ${YELLOW}Keeping ~/.claude/cortex/ (data preserved)${NC}"
fi
[ -d "$CLAUDE_DIR/skills/cortex" ] && rm -rf "$CLAUDE_DIR/skills/cortex" && echo "  Removed skill"
[ -d "$CLAUDE_DIR/hooks/cortex" ] && rm -rf "$CLAUDE_DIR/hooks/cortex" && echo "  Removed hooks"
rm -f "$CLAUDE_DIR/commands/cx-"*.md 2>/dev/null && echo "  Removed commands"

# Clean settings.json
PYTHON_CMD=""
command -v python3 >/dev/null 2>&1 && PYTHON_CMD="python3"
[ -z "$PYTHON_CMD" ] && command -v python >/dev/null 2>&1 && PYTHON_CMD="python"

if [ -n "$PYTHON_CMD" ] && [ -f "$CLAUDE_DIR/settings.json" ]; then
    # Backup settings before modifying
    cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.backup.$(date +%Y%m%d-%H%M%S)"
    export _CX_SETTINGS_FILE="$CLAUDE_DIR/settings.json"
    "$PYTHON_CMD" << 'PYEOF'
import json, os

settings_file = os.environ["_CX_SETTINGS_FILE"]
with open(settings_file) as f:
    s = json.load(f)

# Remove cortex hooks
hooks = s.get("hooks", {})
for event in list(hooks.keys()):
    hooks[event] = [
        h for h in hooks[event]
        if not any("cortex" in str(hook.get("command", "")) for hook in h.get("hooks", []))
    ]
    if not hooks[event]:
        del hooks[event]
s["hooks"] = hooks

# Remove cortex permissions
perms = s.get("permissions", {})
perms["allow"] = [p for p in perms.get("allow", []) if "cortex" not in p]
perms["additionalDirectories"] = [d for d in perms.get("additionalDirectories", []) if "cortex" not in d]

with open(settings_file, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PYEOF
    [ $? -eq 0 ] && echo "  Cleaned settings.json"
fi

# Remove Cortex section from CLAUDE.md
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
    if grep -q "## Cortex" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
        if [ -n "$PYTHON_CMD" ]; then
            export _CX_CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
            "$PYTHON_CMD" << 'PYEOF'
import re, os

claude_md = os.environ["_CX_CLAUDE_MD"]
with open(claude_md) as f:
    content = f.read()
content = re.sub(r'\n*## Cortex[^\n]*\n.*?(?=\n## (?!Cortex)|\Z)', '', content, flags=re.DOTALL)
content = content.rstrip() + '\n'
with open(claude_md, 'w') as f:
    f.write(content)
PYEOF
            [ $? -eq 0 ] && echo "  Removed Cortex section from CLAUDE.md"
        fi
    fi
fi

echo ""
echo -e "${GREEN}Cortex uninstalled.${NC}"
if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    echo -e "Portable backup: ${BOLD}$BACKUP_FILE${NC}"
    echo -e "To restore: install Cortex on new machine, then run ${BOLD}/cx-restore $BACKUP_FILE${NC}"
fi
echo ""
