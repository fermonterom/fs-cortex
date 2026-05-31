#Requires -Version 5.1
<#
.SYNOPSIS
    fs-cortex installer for Windows
.DESCRIPTION
    Installs or upgrades fs-cortex — Continuous Learning for Claude Code.
    Detects existing installations and preserves all user data.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$CortexDir = Join-Path $ClaudeDir "cortex"
$SkillsDir = Join-Path $ClaudeDir "skills"
$CommandsDir = Join-Path $ClaudeDir "commands"
$HooksDir = Join-Path (Join-Path $ClaudeDir "hooks") "cortex"
$SettingsFile = Join-Path $ClaudeDir "settings.json"
$ClaudeMd = Join-Path $ClaudeDir "CLAUDE.md"
$NewVersion = "3.34.0"

# v3.25.1 — explicit downgrade flag (parity with install.sh).
# A behind-remote repo would silently rewind hooks otherwise.
$AllowDowngrade = ($args -contains '--allow-downgrade') -or ($args -contains '-AllowDowngrade')

function Test-VersionLessThan {
    param([string]$A, [string]$B)
    try {
        return [version]$A -lt [version]$B
    } catch {
        # Non-semver fallback: string compare
        return $A -lt $B
    }
}

# --- Helpers ---

function Print-Header {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  fs-cortex - Continuous Learning for Claude Code" -ForegroundColor White
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Print-Step($msg)  { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Blue }
function Print-Ok($msg)    { Write-Host "  + $msg" -ForegroundColor Green }
function Print-Warn($msg)  { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Print-Error($msg) { Write-Host "  x $msg" -ForegroundColor Red }

function Ask-YesNo($prompt, $default = "y") {
    $suffix = @{ $true = "[Y/n]"; $false = "[y/N]" }[$default -eq "y"]
    $answer = Read-Host "$prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
    return $answer -match "^[Yy]"
}

# --- Start ---
Print-Header

# Step 1: Prerequisites
Print-Step "Checking prerequisites..."

if (-not (Test-Path $ClaudeDir)) {
    Print-Error "~/.claude/ not found. Is Claude Code installed?"
    exit 1
}
Print-Ok "Claude Code directory found"

# Check Python
$PythonCmd = $null
if (Get-Command python3 -ErrorAction SilentlyContinue) { $PythonCmd = "python3" }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $PythonCmd = "python" }
if (-not $PythonCmd) {
    Print-Error "Python 3 not found. Required for observation hooks."
    exit 1
}
Print-Ok "Python found: $PythonCmd"

# Check Node
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Print-Error "Node.js not found. Required on Windows for injector.js and session-learner.js."
    exit 1
}
else { Print-Ok "Node.js found" }

# Step 2: Check for existing installations
Print-Step "Checking for existing installations..."

$HasCortex = $false
$InstalledVersion = "none"

if (Test-Path $CortexDir) {
    $HasCortex = $true
    $versionFile = Join-Path $CortexDir "version"
    if (Test-Path $versionFile) {
        $InstalledVersion = (Get-Content $versionFile -Raw).Trim()
    }
    $lawCount = (Get-ChildItem ([IO.Path]::Combine($CortexDir, "laws", "*.txt")) -ErrorAction SilentlyContinue | Measure-Object).Count
    $instinctCount = (Get-ChildItem (Join-Path $CortexDir "instincts") -Filter "*.yaml" -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count

    if ($InstalledVersion -eq "none") {
        Print-Warn "Legacy cortex installation detected ($lawCount laws, $instinctCount instincts)"
        Print-Step "Upgrading to v$NewVersion"
    }
    elseif (Test-VersionLessThan $NewVersion $InstalledVersion) {
        Write-Host ""
        Write-Host "DOWNGRADE BLOCKED" -ForegroundColor Red
        Write-Host "  Installed: v$InstalledVersion" -ForegroundColor Red
        Write-Host "  This installer ships: v$NewVersion" -ForegroundColor Red
        Write-Host ""
        Write-Host "Likely cause: this repository copy is behind the remote." -ForegroundColor Yellow
        Write-Host "Try:" -ForegroundColor Yellow
        Write-Host "  cd $ScriptDir; git pull origin main" -ForegroundColor Yellow
        Write-Host "  powershell -ExecutionPolicy Bypass -File install.ps1" -ForegroundColor Yellow
        Write-Host ""
        if ($AllowDowngrade) {
            Write-Host "--allow-downgrade was passed — proceeding anyway." -ForegroundColor Yellow
            Print-Step "Downgrading from v$InstalledVersion -> v$NewVersion"
            Print-Ok "$lawCount laws, $instinctCount instincts (preserved)"
        } else {
            Write-Host "If this is intentional, re-run with --allow-downgrade." -ForegroundColor Red
            Write-Host ""
            exit 1
        }
    }
    elseif ($InstalledVersion -eq $NewVersion) {
        Print-Step "fs-cortex v$InstalledVersion already installed -- refreshing files"
        Print-Ok "$lawCount laws, $instinctCount instincts (preserved)"
    }
    else {
        Print-Step "Detected fs-cortex v$InstalledVersion -> upgrading to v$NewVersion"
        Print-Ok "$lawCount laws, $instinctCount instincts (preserved)"
    }
    Write-Host "  Existing data will be preserved. Only hooks, commands, and skill will be updated." -ForegroundColor Yellow
    if (-not (Ask-YesNo "Update cortex installation?")) {
        Write-Host "Installation cancelled."
        exit 0
    }
}

# Step 3: Check for backup to import
$ImportBackup = ""
if (-not $HasCortex) {
    Write-Host ""
    Write-Host "Do you have a backup from a previous Cortex installation?" -ForegroundColor White
    Write-Host "  (Created with /cx-backup - a .tar.gz file)"
    $ImportBackup = Read-Host "  Path to backup (or Enter to skip)"
    if ($ImportBackup -and -not (Test-Path $ImportBackup)) {
        Print-Warn "Not a valid file: $ImportBackup - skipping backup import"
        $ImportBackup = ""
    }
}

# Step 4: Create directory structure
Print-Step "Creating directory structure..."
$dirs = @(
    "laws/archive", "instincts/global", "instincts/archive",
    "projects", "evolved/skills", "evolved/commands", "evolved/rules", "evolved/agents",
    "exports", "daily-summaries", "log"
)
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Path (Join-Path $CortexDir $d) -Force | Out-Null
}
Print-Ok "Created ~/.claude/cortex/"

# Create knowledge-log.md (append-only event log) — only if not already present
$knowledgeLog = Join-Path $CortexDir "knowledge-log.md"
if (-not (Test-Path $knowledgeLog)) {
    New-Item -ItemType File -Path $knowledgeLog -Force | Out-Null
    Print-Ok "Created knowledge-log.md (event log)"
}

# Step 5: Copy core files (preserve existing data on reinstall)
Print-Step "Installing core files..."
$memoryDest = Join-Path $CortexDir "memory.json"
if (-not (Test-Path $memoryDest)) {
    Copy-Item ([IO.Path]::Combine($ScriptDir, "core", "memory.template.json")) $memoryDest
    Print-Ok "Created memory.json"
}
else {
    Print-Warn "memory.json exists, preserving user data"
    # Migrate memory.json: remove dead identity block, update version (v3.12.0+)
    try {
        $memJson = Get-Content $memoryDest -Raw | ConvertFrom-Json
        $changed = $false
        if ($memJson.PSObject.Properties.Name -contains 'identity') {
            $memJson.PSObject.Properties.Remove('identity')
            $changed = $true
        }
        $curVer = ($memJson.version -split '\.') | ForEach-Object { [int]$_ }
        if ($curVer.Count -lt 3 -or $curVer[0] -lt 3 -or ($curVer[0] -eq 3 -and $curVer[1] -lt 12)) {
            $memJson.version = '3.12.0'
            $changed = $true
        }
        if ($changed) {
            $tmpPath = "$memoryDest.tmp.$PID"
            $memJson | ConvertTo-Json -Depth 10 | Set-Content $tmpPath -Encoding UTF8
            Move-Item $tmpPath $memoryDest -Force
            Write-Host "  Migrated memory.json (removed identity, updated version)"
        }
    } catch {
        Write-Warning "  memory.json migration skipped: $($_.Exception.Message)"
    }
}

$reflexesDest = Join-Path $CortexDir "reflexes.json"
if (-not (Test-Path $reflexesDest)) {
    Copy-Item ([IO.Path]::Combine($ScriptDir, "core", "reflexes.default.json")) $reflexesDest
    Print-Ok "Created reflexes.json"
}
else {
    Print-Warn "reflexes.json exists, preserving user data"
    # Migrate reflexes: add new + update matcher/condition/action (v3.10.6+)
    # Preserves user runtime data: fireCount, lastFired, enabled
    try {
        $userReflexes = Get-Content $reflexesDest -Raw | ConvertFrom-Json
        $defaultReflexes = Get-Content ([IO.Path]::Combine($ScriptDir, "core", "reflexes.default.json")) -Raw | ConvertFrom-Json
        $userById = @{}
        foreach ($u in $userReflexes.reflexes) { $userById[$u.id] = $u }
        $added = 0; $updated = 0
        foreach ($d in $defaultReflexes.reflexes) {
            if (-not $userById.ContainsKey($d.id)) {
                $userReflexes.reflexes += $d
                $added++
            } else {
                $u = $userById[$d.id]
                $changed = $false
                foreach ($field in @("matcher", "condition", "action", "severity")) {
                    if ($d.PSObject.Properties[$field] -and $u.$field -ne $d.$field) {
                        $u.$field = $d.$field
                        $changed = $true
                    }
                }
                # v3.23.5+ propagate evaluator.* (matcher fix needs both — parity with install.sh:210)
                if ($d.PSObject.Properties['evaluator'] -and $d.evaluator -is [PSCustomObject]) {
                    if (-not $u.PSObject.Properties['evaluator'] -or -not ($u.evaluator -is [PSCustomObject])) {
                        $u | Add-Member -NotePropertyName 'evaluator' -NotePropertyValue $d.evaluator -Force
                        $changed = $true
                    } else {
                        $uEval = $u.evaluator
                        foreach ($sub in @('type', 'anti_pattern', 'expected_tool', 'anti_tool',
                                           'precondition_tool', 'match_field', 'lookback',
                                           'window', 'error_pattern')) {
                            if (-not $d.evaluator.PSObject.Properties[$sub]) { continue }
                            $newVal = $d.evaluator.$sub
                            $hasOld = [bool]$uEval.PSObject.Properties[$sub]
                            $oldVal = if ($hasOld) { $uEval.$sub } else { $null }
                            if (-not $hasOld -or $oldVal -ne $newVal) {
                                if ($hasOld) {
                                    $uEval.$sub = $newVal
                                } else {
                                    $uEval | Add-Member -NotePropertyName $sub -NotePropertyValue $newVal -Force
                                }
                                $changed = $true
                            }
                        }
                    }
                }
                if ($changed) { $updated++ }
            }
        }
        if ($added -gt 0 -or $updated -gt 0) {
            $userReflexes | ConvertTo-Json -Depth 10 | Set-Content $reflexesDest -Encoding UTF8
            $parts = @()
            if ($added -gt 0) { $parts += "$added new" }
            if ($updated -gt 0) { $parts += "$updated updated" }
            Write-Host "  Reflexes migrated: $($parts -join ', ')"
        }
    } catch { Write-Warning "  Reflex migration skipped: $_" }
}
Print-Ok "Core files ready"

# Step 6: Install skill
Print-Step "Installing cortex skill..."
$skillDest = Join-Path $SkillsDir "cortex"
$agentsDest = Join-Path $skillDest "agents"
New-Item -ItemType Directory -Path $agentsDest -Force | Out-Null
Copy-Item ([IO.Path]::Combine($ScriptDir, "skills", "cortex", "SKILL.md")) (Join-Path $skillDest "SKILL.md") -Force
Get-ChildItem ([IO.Path]::Combine($ScriptDir, "agents", "*.md")) -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName $agentsDest -Force
}
Print-Ok "Skill installed to ~/.claude/skills/cortex/"

# Step 7: Install commands
Print-Step "Installing commands..."
New-Item -ItemType Directory -Path $CommandsDir -Force | Out-Null
$cmdFiles = Get-ChildItem ([IO.Path]::Combine($ScriptDir, "commands", "*.md")) -ErrorAction SilentlyContinue
foreach ($cmd in $cmdFiles) {
    Copy-Item $cmd.FullName $CommandsDir -Force
}
$cmdNames = ($cmdFiles | ForEach-Object { $_.BaseName }) -join ", "
Print-Ok "Commands installed: $cmdNames"

# Step 8: Install hooks
Print-Step "Installing hooks..."
New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null

# Remove legacy shell hooks replaced by Python in v3.10.0
foreach ($legacy in @("session-start.sh", "observe.sh")) {
    $legacyPath = Join-Path $HooksDir $legacy
    if (Test-Path $legacyPath) {
        Write-Host "  Removing legacy hook: $legacy"
        Remove-Item $legacyPath -Force
    }
}

# Shell and JS hooks
foreach ($ext in @("*.sh", "*.js", "*.py")) {
    Get-ChildItem ([IO.Path]::Combine($ScriptDir, "hooks", $ext)) -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName $HooksDir -Force
    }
}
Print-Ok "Hooks installed to ~/.claude/hooks/cortex/"

# Step 8a: Install Python lib modules
$libSrc = [IO.Path]::Combine($ScriptDir, "hooks", "lib")
if (Test-Path $libSrc) {
    $libDest = Join-Path $HooksDir "lib"
    New-Item -ItemType Directory -Path $libDest -Force | Out-Null
    foreach ($libExt in @("*.py", "*.js")) {
        Get-ChildItem (Join-Path $libSrc $libExt) -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName $libDest -Force
        }
    }
    Print-Ok "Lib modules installed to ~/.claude/hooks/cortex/lib/"
}

# Step 9: Install seed instinct (only if not already present)
Print-Step "Installing seed instinct..."
$seedDest = [IO.Path]::Combine($CortexDir, "instincts", "global", "read-instructions-before-executing.yaml")
$seedSrc = [IO.Path]::Combine($ScriptDir, "rules", "seed.md")
if (Test-Path $seedDest) {
    Print-Warn "Seed instinct already exists, preserving"
}
elseif (Test-Path $seedSrc) {
    Copy-Item $seedSrc $seedDest
    Print-Ok "Seed instinct installed"
}
else { Print-Warn "Seed rule not found, skipping" }

# Step 10: Configure settings.json
Print-Step "Configuring hooks in settings.json..."

if (Test-Path $SettingsFile) {
    $backupFile = "$SettingsFile.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $SettingsFile $backupFile
    Print-Ok "Backup: $backupFile"
}

# Use Python to safely merge hooks (same logic as install.sh)
$pyMerge = @'
import json, os, tempfile

settings_file = os.path.join(os.environ.get("USERPROFILE", ""), ".claude", "settings.json")

settings = {}
if os.path.exists(settings_file):
    with open(settings_file) as f:
        settings = json.load(f)

settings.setdefault("permissions", {})
settings["permissions"].setdefault("allow", [])
settings["permissions"].setdefault("additionalDirectories", [])

cortex_perms = ["Read(~/.claude/cortex/**)", "Edit(~/.claude/cortex/**)"]
for perm in cortex_perms:
    if perm not in settings["permissions"]["allow"]:
        settings["permissions"]["allow"].append(perm)

if "~/.claude/cortex" not in settings["permissions"].get("additionalDirectories", []):
    settings["permissions"]["additionalDirectories"].append("~/.claude/cortex")

cortex_hooks = {
    "SessionStart": [
        {"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/cortex/session-start.py", "timeout": 5000}]},
        {"matcher": "compact", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/cortex/session-start.py", "timeout": 5000}]}
    ],
    "PreToolUse": [
        {"matcher": "*", "hooks": [
            {"type": "command", "command": "python3 ~/.claude/hooks/cortex/observe.py pre", "timeout": 10000, "async": True},
            {"type": "command", "command": "node ~/.claude/hooks/cortex/injector.js", "timeout": 3000}
        ]}
    ],
    "PostToolUse": [
        {"matcher": "*", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/cortex/observe.py post", "timeout": 10000, "async": True}]}
    ],
    "Stop": [
        {"hooks": [{"type": "command", "command": "node ~/.claude/hooks/cortex/session-learner.js", "timeout": 15000}]}
    ],
    "PreCompact": [
        {"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/cortex/precompact.py", "timeout": 8000}]}
    ]
}

existing_hooks = settings.get("hooks", {})
for event, handlers in cortex_hooks.items():
    existing = existing_hooks.get(event, [])
    cleaned = [h for h in existing if not any("hooks/cortex/" in str(hook.get("command", "")) for hook in h.get("hooks", []))]
    existing_hooks[event] = cleaned + handlers

settings["hooks"] = existing_hooks

# v3.19.0 — Cortex env vars (auto-disable noisy reflexes by default)
# Windows GUI apps don't inherit shell env, so we set
# CORTEX_AGENT_DISABLE_REFLEXES in settings.json so the harness injects it
# to every hook subprocess. Users can opt-out by deleting this entry or
# setting it to "" / "0". See docs/AUTO-EVALUATION.md for rationale.
settings.setdefault("env", {})
if "CORTEX_AGENT_DISABLE_REFLEXES" not in settings["env"]:
    settings["env"]["CORTEX_AGENT_DISABLE_REFLEXES"] = "1"

fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(settings_file), suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    import stat
    os.chmod(tmp_path, stat.S_IRUSR | stat.S_IWUSR)
    os.replace(tmp_path, settings_file)
except:
    os.unlink(tmp_path)
    raise
'@

try {
    & $PythonCmd -c $pyMerge
    Print-Ok "Hooks configured in settings.json"
}
catch {
    Print-Error "Failed to configure hooks. Check that settings.json is valid JSON."
    Print-Error "  Inner error: $($_.Exception.Message)"
    exit 1
}

# Step 11: Update CLAUDE.md
Print-Step "Updating CLAUDE.md..."
$sectionFile = [IO.Path]::Combine($ScriptDir, "core", "claudemd-section.md")

if (Test-Path $ClaudeMd) {
    # Backup CLAUDE.md before any modification
    $claudeBackup = "$ClaudeMd.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $ClaudeMd $claudeBackup -ErrorAction SilentlyContinue

    $content = Get-Content $ClaudeMd -Raw
    if ($content -match "## Cortex") {
        # UPGRADE: replace existing section
        $pyReplace = @"
import re, os, tempfile, sys
claude_md = os.path.join(os.environ.get('USERPROFILE', ''), '.claude', 'CLAUDE.md')
section_file = sys.argv[1]
with open(claude_md) as f:
    content = f.read()
with open(section_file) as f:
    new_section = f.read()
content = re.sub(r'\n*## Cortex \(Learning System\)\n.*?(?=\n## |\Z)', '', content, flags=re.DOTALL)
content = content.rstrip() + '\n\n' + new_section + '\n'
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(claude_md), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(content)
os.replace(tmp, claude_md)
"@
        & $PythonCmd -c $pyReplace $sectionFile
        Print-Ok "Cortex section updated in CLAUDE.md"
    }
    else {
        # FRESH: append
        Add-Content $ClaudeMd "`n"
        Get-Content $sectionFile | Add-Content $ClaudeMd
        Print-Ok "Cortex section appended to CLAUDE.md"
    }
}
else {
    Copy-Item $sectionFile $ClaudeMd
    Print-Ok "Created CLAUDE.md with Cortex section"
}

# Step 12: Import backup (if provided)
if ($ImportBackup) {
    Print-Step "Importing backup..."
    Print-Warn "Backup import on Windows requires tar (available in Windows 10+)"
    try {
        # Validate archive: reject entries with path traversal or absolute paths
        $unsafeEntries = tar -tzf $ImportBackup 2>$null | Where-Object { $_ -match '(^\\/|\\.\\.[\\/])' }
        if ($unsafeEntries) {
            Print-Error "Backup archive contains unsafe paths (../ or absolute). Aborting import."
            return
        }
        $tempDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
        tar -xzf $ImportBackup -C $tempDir.FullName 2>$null
        # Copy laws
        $lawsDir = Join-Path $tempDir.FullName "laws"
        if (Test-Path $lawsDir) {
            Get-ChildItem "$lawsDir/*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
                $dest = [IO.Path]::Combine($CortexDir, "laws", $_.Name)
                if (-not (Test-Path $dest)) { Copy-Item $_.FullName $dest }
            }
        }
        # Copy instincts
        foreach ($instDir in @("instincts/personal", "instincts/global")) {
            $src = Join-Path $tempDir.FullName $instDir
            if (Test-Path $src) {
                Get-ChildItem "$src/*.yaml" -ErrorAction SilentlyContinue | ForEach-Object {
                    $dest = [IO.Path]::Combine($CortexDir, "instincts", "global", $_.Name)
                    if (-not (Test-Path $dest)) { Copy-Item $_.FullName $dest }
                }
            }
        }
        # Copy memory.json (config + stats)
        $memSrc = Join-Path $tempDir.FullName "memory.json"
        if (Test-Path $memSrc) {
            $memDest = Join-Path $CortexDir "memory.json"
            if (-not (Test-Path $memDest)) { Copy-Item $memSrc $memDest }
        }
        # Copy reflexes.json (user customizations)
        $refSrc = Join-Path $tempDir.FullName "reflexes.json"
        if (Test-Path $refSrc) {
            $refDest = Join-Path $CortexDir "reflexes.json"
            if (-not (Test-Path $refDest)) { Copy-Item $refSrc $refDest }
        }
        # Copy projects registry
        $regSrc = [IO.Path]::Combine($tempDir.FullName, "projects", "registry.json")
        if (Test-Path $regSrc) {
            $regDir = Join-Path $CortexDir "projects"
            if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
            Copy-Item $regSrc (Join-Path $regDir "registry.json") -Force
        }
        # Copy project-scoped instincts
        $projInstDir = Join-Path $tempDir.FullName "projects"
        if (Test-Path $projInstDir) {
            Get-ChildItem $projInstDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $projInstSrc = Join-Path $_.FullName "instincts"
                if (Test-Path $projInstSrc) {
                    $projDest = [IO.Path]::Combine($CortexDir, "projects", $_.Name, "instincts")
                    if (-not (Test-Path $projDest)) { New-Item -ItemType Directory -Path $projDest -Force | Out-Null }
                    Copy-Item "$projInstSrc/*" $projDest -Force -ErrorAction SilentlyContinue
                }
            }
        }
        # Copy evolved content
        $evolvedSrc = Join-Path $tempDir.FullName "evolved"
        if (Test-Path $evolvedSrc) {
            $evolvedDest = Join-Path $CortexDir "evolved"
            if (-not (Test-Path $evolvedDest)) { New-Item -ItemType Directory -Path $evolvedDest -Force | Out-Null }
            Copy-Item "$evolvedSrc/*" $evolvedDest -Force -ErrorAction SilentlyContinue
        }
        # Copy daily summaries
        $dailySrc = Join-Path $tempDir.FullName "daily-summaries"
        if (Test-Path $dailySrc) {
            $dailyDest = Join-Path $CortexDir "daily-summaries"
            if (-not (Test-Path $dailyDest)) { New-Item -ItemType Directory -Path $dailyDest -Force | Out-Null }
            Copy-Item "$dailySrc/*" $dailyDest -Force -ErrorAction SilentlyContinue
        }
        Print-Ok "Backup imported (all 8 categories)"
        Remove-Item $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Print-Error "Failed to extract backup. Continuing with fresh install."
    }
}

# Step 13: Onboarding (only for fresh installs)
if (-not $HasCortex -and -not $ImportBackup) {
    Print-Step "Setting up initial configuration..."

    # Populate memory.json with install date
    & $PythonCmd -c @'
import json, os, datetime
mem_path = os.path.join(os.environ.get("USERPROFILE", ""), ".claude", "cortex", "memory.json")
with open(mem_path) as f:
    mem = json.load(f)
mem["stats"]["installed"] = datetime.datetime.now().strftime("%Y-%m-%d")
import tempfile
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(mem_path), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(mem, f, indent=2)
os.replace(tmp, mem_path)
'@ 2>$null

    # Copy seed laws
    $seedLawsDir = [IO.Path]::Combine($ScriptDir, "seeds", "laws")
    if (Test-Path $seedLawsDir) {
        Get-ChildItem "$seedLawsDir/*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $CortexDir "laws") -Force
        }
        $seedLawCount = (Get-ChildItem "$seedLawsDir/*.txt" -ErrorAction SilentlyContinue | Measure-Object).Count
        Print-Ok "Seed laws installed: $seedLawCount"
    }

    # Copy seed instincts
    $seedInstDir = [IO.Path]::Combine($ScriptDir, "seeds", "instincts")
    if (Test-Path $seedInstDir) {
        Get-ChildItem "$seedInstDir/*.yaml" -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName ([IO.Path]::Combine($CortexDir, "instincts", "global")) -Force
        }
        $seedInstCount = (Get-ChildItem "$seedInstDir/*.yaml" -ErrorAction SilentlyContinue | Measure-Object).Count
        Print-Ok "Seed instincts installed: $seedInstCount"
    }
}

# Step 14: Write version marker
Set-Content (Join-Path $CortexDir "version") $NewVersion

# Step 15: Summary
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  fs-cortex v$NewVersion installed!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
if ($HasCortex) {
    if ($InstalledVersion -eq "none") {
        Write-Host "  Upgraded:  legacy -> v$NewVersion" -ForegroundColor White
    }
    else {
        Write-Host "  Upgraded:  v$InstalledVersion -> v$NewVersion" -ForegroundColor White
    }
}
else {
    Write-Host "  Install:   Fresh install" -ForegroundColor White
}
Write-Host "  Data:      ~/.claude/cortex/"
Write-Host "  Skill:     ~/.claude/skills/cortex/SKILL.md"
$cmdList = (Get-ChildItem ([IO.Path]::Combine($ScriptDir, "commands", "*.md")) | ForEach-Object { "/$($_.BaseName)" }) -join ", "
Write-Host "  Commands:  $cmdList"
Write-Host "  Hooks:     ~/.claude/hooks/cortex/"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "  1. Open Claude Code and work normally"
Write-Host "  2. Laws inject automatically at session start"
Write-Host "  3. Run /cx-analyze when suggested to detect patterns"
Write-Host ""
if ($ImportBackup) {
    Write-Host "  Knowledge imported from backup." -ForegroundColor Yellow
}
Write-Host ""
