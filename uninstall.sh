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
echo "  - ~/.claude/cortex/ (data directory)"
echo "  - ~/.claude/skills/cortex/ (skill)"
echo "  - ~/.claude/hooks/cortex/ (hooks)"
echo "  - ~/.claude/commands/cx-*.md (commands)"
echo "  - Cortex hooks from settings.json"
echo "  - Cortex section from CLAUDE.md"
echo ""

read -rp "$(echo -e "${BOLD}Are you sure? This cannot be undone. [y/N]:${NC} ")" confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Cancelled."
    exit 0
fi

# Backup data first
read -rp "$(echo -e "${BOLD}Backup data before removing? [Y/n]:${NC} ")" backup
backup="${backup:-y}"
if [[ "$backup" =~ ^[Yy] ]]; then
    BACKUP="$CLAUDE_DIR/cortex.backup.$(date +%Y%m%d-%H%M%S)"
    if [ -d "$CORTEX_DIR" ]; then
        cp -r "$CORTEX_DIR" "$BACKUP" 2>/dev/null && echo -e "${GREEN}  Backed up to $BACKUP${NC}"
    fi
fi

# Remove data
[ -d "$CORTEX_DIR" ] && rm -rf "$CORTEX_DIR" && echo "  Removed ~/.claude/cortex/"
[ -d "$CLAUDE_DIR/skills/cortex" ] && rm -rf "$CLAUDE_DIR/skills/cortex" && echo "  Removed skill"
[ -d "$CLAUDE_DIR/hooks/cortex" ] && rm -rf "$CLAUDE_DIR/hooks/cortex" && echo "  Removed hooks"
rm -f "$CLAUDE_DIR/commands/cx-"*.md 2>/dev/null && echo "  Removed commands"

# Clean settings.json
PYTHON_CMD=""
command -v python3 >/dev/null 2>&1 && PYTHON_CMD="python3"
[ -z "$PYTHON_CMD" ] && command -v python >/dev/null 2>&1 && PYTHON_CMD="python"

if [ -n "$PYTHON_CMD" ] && [ -f "$CLAUDE_DIR/settings.json" ]; then
    "$PYTHON_CMD" -c "
import json
settings_file = '$CLAUDE_DIR/settings.json'
with open(settings_file) as f:
    s = json.load(f)

# Remove cortex hooks
hooks = s.get('hooks', {})
for event in list(hooks.keys()):
    hooks[event] = [
        h for h in hooks[event]
        if not any('cortex' in str(hook.get('command', '')) for hook in h.get('hooks', []))
    ]
    if not hooks[event]:
        del hooks[event]
s['hooks'] = hooks

# Remove cortex permissions
perms = s.get('permissions', {})
perms['allow'] = [p for p in perms.get('allow', []) if 'cortex' not in p]
perms['additionalDirectories'] = [d for d in perms.get('additionalDirectories', []) if 'cortex' not in d]

with open(settings_file, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
" && echo "  Cleaned settings.json"
fi

# Remove Cortex section from CLAUDE.md
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
    if grep -q "## Cortex" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
        # Use Python for reliable multi-line removal
        if [ -n "$PYTHON_CMD" ]; then
            "$PYTHON_CMD" -c "
import re
claude_md = '$CLAUDE_DIR/CLAUDE.md'
with open(claude_md) as f:
    content = f.read()
# Remove from '## Cortex' to the next '## ' heading or end of file
content = re.sub(r'\n*## Cortex \(Learning System\).*?(?=\n## (?!Cortex)|\Z)', '', content, flags=re.DOTALL)
# Clean trailing whitespace
content = content.rstrip() + '\n'
with open(claude_md, 'w') as f:
    f.write(content)
" && echo "  Removed Cortex section from CLAUDE.md"
        fi
    fi
fi

echo ""
echo -e "${GREEN}Cortex uninstalled.${NC}"
if [[ "$backup" =~ ^[Yy] ]]; then
    echo -e "Data backed up to: ${BOLD}$BACKUP${NC}"
fi
echo ""
