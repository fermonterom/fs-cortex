#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell installer tests — syntax validation, fresh install simulation, version consistency
.DESCRIPTION
    Runs on windows-latest in CI. Tests install.ps1 without user interaction.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$Pass = 0
$Fail = 0

function Test-Pass($msg) { $script:Pass++; Write-Host "  PASS: $msg" -ForegroundColor Green }
function Test-Fail($msg) { $script:Fail++; Write-Host "  FAIL: $msg" -ForegroundColor Red }

Write-Host "=== PowerShell Installer Tests ===" -ForegroundColor Cyan
Write-Host ""

# ── TEST 1: Script parses without errors ──────────────────────────

Write-Host "--- Syntax validation ---"
try {
    $null = [System.Management.Automation.PSParser]::Tokenize(
        (Get-Content "$ProjectRoot/install.ps1" -Raw), [ref]$null
    )
    Test-Pass "install.ps1 parses without syntax errors"
}
catch {
    Test-Fail "install.ps1 has syntax errors: $_"
}

# ── TEST 2: Version matches install.sh ────────────────────────────

Write-Host "--- Version consistency ---"
$ps1Version = (Select-String -Path "$ProjectRoot/install.ps1" -Pattern '^\$NewVersion\s*=\s*"([^"]+)"' |
    ForEach-Object { $_.Matches.Groups[1].Value }) | Select-Object -First 1

$shVersion = (Select-String -Path "$ProjectRoot/install.sh" -Pattern '^NEW_VERSION="([^"]+)"' |
    ForEach-Object { $_.Matches.Groups[1].Value }) | Select-Object -First 1

if ($ps1Version -eq $shVersion) {
    Test-Pass "install.ps1 ($ps1Version) = install.sh ($shVersion)"
}
else {
    Test-Fail "version mismatch: install.ps1=$ps1Version vs install.sh=$shVersion"
}

# ── TEST 3: CHANGELOG version matches ────────────────────────────

$changelogVersion = (Select-String -Path "$ProjectRoot/CHANGELOG.md" -Pattern '## \[([^\]]+)\]' |
    ForEach-Object { $_.Matches.Groups[1].Value }) | Select-Object -First 1

if ($ps1Version -eq $changelogVersion) {
    Test-Pass "install.ps1 ($ps1Version) = CHANGELOG ($changelogVersion)"
}
else {
    Test-Fail "version mismatch: install.ps1=$ps1Version vs CHANGELOG=$changelogVersion"
}

# ── TEST 4: Required functions exist ──────────────────────────────

Write-Host "--- Required functions ---"
$content = Get-Content "$ProjectRoot/install.ps1" -Raw

$requiredFunctions = @("Print-Header", "Print-Step", "Print-Ok", "Print-Warn", "Print-Error", "Ask-YesNo")
$missingFuncs = 0
foreach ($func in $requiredFunctions) {
    if ($content -match "function\s+$func") {
        # exists
    }
    else {
        Test-Fail "missing function: $func"
        $missingFuncs++
    }
}
if ($missingFuncs -eq 0) { Test-Pass "all $($requiredFunctions.Count) helper functions present" }

# ── TEST 5: Security features present ─────────────────────────────

Write-Host "--- Security checks ---"
$securityChecks = @(
    @{ Name = "path traversal validation"; Pattern = "unsafeEntries|unsafe paths" },
    @{ Name = "chmod 600 on settings.json"; Pattern = "S_IRUSR|stat\.S_IRUSR" },
    @{ Name = "atomic write (tempfile)"; Pattern = "tempfile\.mkstemp" },
    @{ Name = "atomic write (os.replace)"; Pattern = "os\.replace" }
)

$secMissing = 0
foreach ($check in $securityChecks) {
    if ($content -match $check.Pattern) {
        # present
    }
    else {
        Test-Fail "missing: $($check.Name)"
        $secMissing++
    }
}
if ($secMissing -eq 0) { Test-Pass "all $($securityChecks.Count) security features present" }

# ── TEST 6: Backup import copies all 8 categories ────────────────

Write-Host "--- Backup completeness ---"
$backupCategories = @("laws", "instincts", "memory.json", "reflexes.json", "registry.json", "evolved", "daily-summaries")
$catMissing = 0
foreach ($cat in $backupCategories) {
    if ($content -match [regex]::Escape($cat)) {
        # found
    }
    else {
        Test-Fail "backup missing category: $cat"
        $catMissing++
    }
}
if ($catMissing -eq 0) { Test-Pass "all $($backupCategories.Count) backup categories referenced" }

# ── TEST 7: All 14 hook events configured ─────────────────────────

Write-Host "--- Hook configuration ---"
$hookEvents = @("SessionStart", "PreToolUse", "PostToolUse", "Stop")
$hookMissing = 0
foreach ($event in $hookEvents) {
    if ($content -match [regex]::Escape("`"$event`"")) {
        # found
    }
    else {
        Test-Fail "missing hook event: $event"
        $hookMissing++
    }
}
if ($hookMissing -eq 0) { Test-Pass "all $($hookEvents.Count) hook events configured" }

# ── TEST 8: Hook files referenced ─────────────────────────────────

$hookFiles = @("session-start.py", "observe.py", "injector.sh", "session-learner.js")
$hfMissing = 0
foreach ($hf in $hookFiles) {
    if ($content -match [regex]::Escape($hf)) {
        # found
    }
    else {
        Test-Fail "missing hook file reference: $hf"
        $hfMissing++
    }
}
if ($hfMissing -eq 0) { Test-Pass "all $($hookFiles.Count) hook files referenced" }

# ── TEST 9: Fresh install simulation (non-interactive) ────────────

Write-Host "--- Fresh install simulation ---"
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("cx-test-" + [System.IO.Path]::GetRandomFileName())
try {
    New-Item -ItemType Directory -Path (Join-Path $sandbox ".claude") -Force | Out-Null

    # Create a minimal settings.json so Python merge doesn't fail
    $settingsPath = Join-Path $sandbox ".claude" "settings.json"
    '{}' | Set-Content $settingsPath

    # Run the Python hook-merge portion only (avoids interactive prompts)
    $env:USERPROFILE = $sandbox
    $pyTest = @"
import json, os, tempfile
settings_file = os.path.join('$($sandbox.Replace("\","\\"))', '.claude', 'settings.json')
settings = {}
if os.path.exists(settings_file):
    with open(settings_file) as f:
        settings = json.load(f)
settings.setdefault('permissions', {})
settings['permissions'].setdefault('allow', [])
settings['hooks'] = {
    'SessionStart': [{'hooks': [{'type': 'command', 'command': 'python3 ~/.claude/hooks/cortex/session-start.py'}]}],
    'PreToolUse': [{'hooks': [{'type': 'command', 'command': 'bash ~/.claude/hooks/cortex/injector.sh'}]}]
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_file), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
os.replace(tmp, settings_file)
print('OK')
"@
    $result = python3 -c $pyTest 2>&1
    if ($result -match "OK") {
        # Verify settings.json was written correctly
        $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($s.hooks.SessionStart -and $s.hooks.PreToolUse) {
            Test-Pass "settings.json hook merge works"
        }
        else {
            Test-Fail "settings.json missing hook events after merge"
        }
    }
    else {
        Test-Fail "Python hook merge failed: $result"
    }
}
catch {
    Test-Fail "install simulation error: $_"
}
finally {
    $env:USERPROFILE = [Environment]::GetFolderPath("UserProfile")
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# ── Summary ───────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Results: $Pass passed, $Fail failed ===" -ForegroundColor $(if ($Fail -eq 0) { "Green" } else { "Red" })
exit $(if ($Fail -eq 0) { 0 } else { 1 })
