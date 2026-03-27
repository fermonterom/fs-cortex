#!/bin/bash
# Migrate sinapsis data to cortex
# Can be run standalone or called from install.sh

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

HOMUNCULUS="$HOME/.claude/homunculus"
CORTEX="$HOME/.claude/cortex"
SINAPSIS_SKILL="$HOME/.claude/skills/sinapsis"

print_ok() { echo -e "${GREEN}  ✓${NC} $1"; }
print_warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
print_error() { echo -e "${RED}  ✗${NC} $1"; }

# Find Python
PYTHON_CMD=""
command -v python3 >/dev/null 2>&1 && PYTHON_CMD="python3"
[ -z "$PYTHON_CMD" ] && command -v python >/dev/null 2>&1 && PYTHON_CMD="python"

if [ -z "$PYTHON_CMD" ]; then
    print_error "Python 3 not found. Required for migration."
    exit 1
fi

# Verify source exists
if [ ! -d "$HOMUNCULUS" ] && [ ! -d "$SINAPSIS_SKILL" ]; then
    print_warn "No sinapsis installation found. Nothing to migrate."
    exit 0
fi

# Verify cortex directory exists
if [ ! -d "$CORTEX" ]; then
    print_error "Cortex directory not found at $CORTEX. Run install.sh first."
    exit 1
fi

INSTINCTS_MIGRATED=0
LAWS_GENERATED=0
OBS_SIZE="0"
BACKUP_DATE=$(date +%Y%m%d-%H%M%S)

echo -e "${BOLD}  Migrating sinapsis -> cortex...${NC}"

# 1. Migrate identity.json -> memory.json
if [ -f "$HOMUNCULUS/identity.json" ] && [ -f "$CORTEX/memory.json" ]; then
    "$PYTHON_CMD" << 'PYEOF'
import json, os, datetime

homunculus = os.path.expanduser("~/.claude/homunculus")
cortex = os.path.expanduser("~/.claude/cortex")

with open(os.path.join(homunculus, "identity.json")) as f:
    identity = json.load(f)
with open(os.path.join(cortex, "memory.json")) as f:
    memory = json.load(f)

memory["identity"]["name"] = identity.get("name", "")
memory["identity"]["role"] = identity.get("role", "")
memory["identity"]["language"] = identity.get("language", "en")
memory["identity"]["location"] = identity.get("location", "")
memory["stats"]["installed"] = datetime.datetime.now().strftime("%Y-%m-%d")

with open(os.path.join(cortex, "memory.json"), "w") as f:
    json.dump(memory, f, indent=2)
    f.write("\n")
PYEOF
    if [ $? -eq 0 ]; then
        print_ok "Identity migrated to memory.json"
    else
        print_warn "Could not migrate identity (non-critical)"
    fi
fi

# 2. Migrate projects.json -> projects/registry.json
if [ -f "$HOMUNCULUS/projects.json" ]; then
    mkdir -p "$CORTEX/projects"
    cp "$HOMUNCULUS/projects.json" "$CORTEX/projects/registry.json"
    print_ok "Projects registry migrated"
fi

# 3. Migrate global instincts
if [ -d "$HOMUNCULUS/instincts/personal" ]; then
    count=$(ls "$HOMUNCULUS/instincts/personal/"*.yaml 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
        mkdir -p "$CORTEX/instincts/personal"
        cp "$HOMUNCULUS/instincts/personal/"*.yaml "$CORTEX/instincts/personal/" 2>/dev/null
        INSTINCTS_MIGRATED=$count
        print_ok "Migrated $count global instincts"
    fi
fi

if [ -d "$HOMUNCULUS/instincts/inherited" ]; then
    count=$(ls "$HOMUNCULUS/instincts/inherited/"*.yaml 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
        mkdir -p "$CORTEX/instincts/inherited"
        cp "$HOMUNCULUS/instincts/inherited/"*.yaml "$CORTEX/instincts/inherited/" 2>/dev/null
        print_ok "Migrated $count inherited instincts"
    fi
fi

# 4. Migrate per-project data (observations, project instincts, evolved)
if [ -d "$HOMUNCULUS/projects" ]; then
    for proj_dir in "$HOMUNCULUS/projects"/*/; do
        [ -d "$proj_dir" ] || continue
        proj_id=$(basename "$proj_dir")
        # Skip if it's not a hash directory (at least 8 chars)
        [ ${#proj_id} -lt 8 ] && continue

        dest="$CORTEX/projects/$proj_id"
        mkdir -p "$dest"/{instincts/{personal,inherited},observations.archive,evolved/{skills,commands,agents}}

        # Copy observations
        [ -f "$proj_dir/observations.jsonl" ] && cp "$proj_dir/observations.jsonl" "$dest/"
        # Copy observation archives
        [ -d "$proj_dir/observations.archive" ] && cp "$proj_dir/observations.archive/"*.jsonl "$dest/observations.archive/" 2>/dev/null
        # Copy project instincts
        [ -d "$proj_dir/instincts/personal" ] && cp "$proj_dir/instincts/personal/"*.yaml "$dest/instincts/personal/" 2>/dev/null
        [ -d "$proj_dir/instincts/inherited" ] && cp "$proj_dir/instincts/inherited/"*.yaml "$dest/instincts/inherited/" 2>/dev/null
        # Copy evolved artifacts
        [ -d "$proj_dir/evolved/skills" ] && cp "$proj_dir/evolved/skills/"* "$dest/evolved/skills/" 2>/dev/null
        [ -d "$proj_dir/evolved/commands" ] && cp "$proj_dir/evolved/commands/"* "$dest/evolved/commands/" 2>/dev/null
        [ -d "$proj_dir/evolved/agents" ] && cp "$proj_dir/evolved/agents/"* "$dest/evolved/agents/" 2>/dev/null
    done
    OBS_SIZE=$(du -sh "$CORTEX/projects" 2>/dev/null | cut -f1)
    print_ok "Project data migrated ($OBS_SIZE)"
fi

# 5. Migrate global evolved content
if [ -d "$HOMUNCULUS/evolved" ]; then
    mkdir -p "$CORTEX/evolved"/{skills,commands,agents}
    [ -d "$HOMUNCULUS/evolved/skills" ] && cp "$HOMUNCULUS/evolved/skills/"* "$CORTEX/evolved/skills/" 2>/dev/null
    [ -d "$HOMUNCULUS/evolved/commands" ] && cp "$HOMUNCULUS/evolved/commands/"* "$CORTEX/evolved/commands/" 2>/dev/null
    [ -d "$HOMUNCULUS/evolved/agents" ] && cp "$HOMUNCULUS/evolved/agents/"* "$CORTEX/evolved/agents/" 2>/dev/null
    print_ok "Evolved content migrated"
fi

# 6. Migrate exports
if [ -d "$HOMUNCULUS/exports" ]; then
    mkdir -p "$CORTEX/exports"
    cp "$HOMUNCULUS/exports/"* "$CORTEX/exports/" 2>/dev/null
    print_ok "Exports migrated"
fi

# 7. Auto-generate Laws from high-confidence instincts
LAWS_GENERATED=$("$PYTHON_CMD" << 'PYEOF'
import os, re, glob

cortex = os.path.expanduser("~/.claude/cortex")
instinct_dir = os.path.join(cortex, "instincts", "personal")
laws_dir = os.path.join(cortex, "laws")
laws_count = 0

os.makedirs(laws_dir, exist_ok=True)

for yaml_file in glob.glob(os.path.join(instinct_dir, "*.yaml")):
    with open(yaml_file) as f:
        content = f.read()

    # Extract confidence from YAML frontmatter
    conf_match = re.search(r'confidence:\s*([\d.]+)', content)
    if not conf_match:
        continue
    confidence = float(conf_match.group(1))

    if confidence < 0.90:
        continue

    # Extract id and action
    id_match = re.search(r'id:\s*(.+)', content)
    action_match = re.search(r'## Action\s*\n(.+?)(?:\n\n|\n##)', content, re.DOTALL)

    if not id_match:
        continue

    instinct_id = id_match.group(1).strip()
    action = ""
    if action_match:
        action = action_match.group(1).strip().split('\n')[0]  # First line only
    else:
        # Fallback: use trigger
        trigger_match = re.search(r'trigger:\s*"?(.+?)"?\s*$', content, re.MULTILINE)
        if trigger_match:
            action = trigger_match.group(1).strip()

    if action:
        law_file = os.path.join(laws_dir, f"{instinct_id}.txt")
        if not os.path.exists(law_file):
            with open(law_file, "w") as f:
                f.write(action + "\n")
            laws_count += 1

print(laws_count)
PYEOF
)
LAWS_GENERATED="${LAWS_GENERATED:-0}"
print_ok "Generated $LAWS_GENERATED laws from high-confidence instincts"

# 8. Backup old homunculus data
if [ -d "$HOMUNCULUS" ]; then
    mv "$HOMUNCULUS" "$HOME/.claude/homunculus.backup.$BACKUP_DATE"
    print_ok "Backed up homunculus -> homunculus.backup.$BACKUP_DATE"
fi

# 9. Remove old sinapsis skill
if [ -d "$SINAPSIS_SKILL" ]; then
    mv "$SINAPSIS_SKILL" "$HOME/.claude/skills/sinapsis.backup.$BACKUP_DATE"
    print_ok "Backed up sinapsis skill -> sinapsis.backup.$BACKUP_DATE"
fi

# 10. Remove old sinapsis commands
OLD_COMMANDS=(
    analyze.md
    instinct-status.md
    evolve.md
    promote.md
    dna.md
    gotcha.md
    eod.md
    audit.md
    watchdog.md
    journal.md
    instinct-export.md
    instinct-import.md
    instinct-cloud.md
    projects.md
    auto-schedule.md
    skill-create.md
)
removed=0
for cmd in "${OLD_COMMANDS[@]}"; do
    if [ -f "$HOME/.claude/commands/$cmd" ]; then
        rm "$HOME/.claude/commands/$cmd"
        ((removed++)) || true
    fi
done
[ $removed -gt 0 ] && print_ok "Removed $removed old sinapsis commands"

# 11. Remove old daily-startup.sh hook
if [ -f "$HOME/.claude/hooks/daily-startup.sh" ]; then
    mv "$HOME/.claude/hooks/daily-startup.sh" "$HOME/.claude/hooks/daily-startup.sh.backup.$BACKUP_DATE"
    print_ok "Backed up daily-startup.sh"
fi

# 12. Remove old git-workflow-guard.sh hook (replaced by cortex git-guard.sh)
if [ -f "$HOME/.claude/hooks/git-workflow-guard.sh" ]; then
    mv "$HOME/.claude/hooks/git-workflow-guard.sh" "$HOME/.claude/hooks/git-workflow-guard.sh.backup.$BACKUP_DATE"
    print_ok "Backed up git-workflow-guard.sh"
fi

# Summary
echo ""
echo -e "${BOLD}  Migration complete:${NC}"
echo "  - Instincts: $INSTINCTS_MIGRATED"
echo "  - Laws: $LAWS_GENERATED"
echo "  - Observations: $OBS_SIZE"
echo "  - Old data backed up with suffix .$BACKUP_DATE"
echo ""
