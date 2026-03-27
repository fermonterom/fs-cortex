---
name: cx-gotcha
description: Capture an error-to-fix pattern as a high-priority gotcha instinct
command: true
---

# /cx-gotcha

## What it does

Captures an error-to-fix pattern as a gotcha instinct. Gotchas are high-priority instincts that prevent repeating the same mistakes.

## Usage

```
/cx-gotcha                              # Auto-detect from current session
/cx-gotcha "useSearchParams needs Suspense boundary"  # Manual description
/cx-gotcha --list                       # List gotchas for current project
/cx-gotcha --list --global              # List all global gotchas
/cx-gotcha --severity high              # Force severity when capturing
```

## Implementation

### Step 1: Detect the Error

**Auto-detect mode** (no argument):
- Scan the current conversation for the most recent error/failure pattern
- Look for: error messages, stack traces, failed commands, build failures
- Identify what went wrong and when

**Manual mode** (with description):
- Use the provided description as the error summary
- Ask for additional context if needed: "What was the fix?"

### Step 2: Detect the Fix

- What resolved the error?
- What was the root cause (not just the symptom)?
- How can it be prevented in the future?

### Step 3: Generate Gotcha Instinct

```yaml
---
id: gotcha-[descriptive-name-kebab-case]
trigger: "[when this error/situation occurs]"
confidence: 0.75
domain: "[detected domain]"
type: gotcha
source: "manual-capture"
scope: project
severity: [low|medium|high|critical]
created: "YYYY-MM-DDTHH:MM:SSZ"
---

# Gotcha: [Descriptive Title]

## Problem
[What goes wrong and when — the error message or symptom]

## Root Cause
[Why it happens — the real cause, not the symptom]

## Fix
[How to resolve it — step by step, with code if applicable]

## Prevention
[How to avoid it in the future]

## Evidence
- Captured: [date]
- Project: [name]
- Context: [framework, version, relevant config]
```

### Step 4: Save

Detect current project (git remote hash or cwd).

- Project detected: write to `~/.claude/cortex/projects/<hash>/instincts/personal/`
- No project: write to `~/.claude/cortex/instincts/personal/`

If a similar gotcha already exists (same error pattern, Jaccard >= 0.70 on trigger keywords):
- Update existing: bump confidence by 0.05
- Merge any new information into the fix/prevention sections

### Step 5: Cross-Reference

Check if this gotcha pattern exists in other projects:
- Scan all project instinct directories for type: gotcha
- Compare trigger keywords

If found in 2+ projects with average confidence >= 0.75:
- Auto-promote: copy to `~/.claude/cortex/instincts/personal/` with scope: global
- Inform user: "This gotcha was found in N projects. Promoted to global."

### Step 6: Display

```
================================================================
  GOTCHA CAPTURED — Cortex
================================================================

  ID:         gotcha-suspense-boundary-searchparams
  Severity:   high
  Domain:     web-development
  Confidence: 0.75

  Problem:
  useSearchParams() crashes without Suspense boundary in Next.js 14+

  Fix:
  Wrap component using useSearchParams in <Suspense fallback={...}>

  Saved: ~/.claude/cortex/projects/[hash]/instincts/personal/gotcha-suspense-*.yaml

================================================================
```

## Gotcha Severity Levels

| Level | Meaning | Examples |
|-------|---------|----------|
| **critical** | Data loss, security breach, production outage | DB migration destroys data, env leak |
| **high** | Build failure, blocking bug | Type error breaks build, auth loop |
| **medium** | Incorrect behavior, not immediately obvious | Wrong cache, stale data, race condition |
| **low** | Minor annoyance, suboptimal output | Lint warning, cosmetic issue |

## Listing Gotchas

With `--list`, display:

```
================================================================
  GOTCHAS — project: [name] (N gotchas)
================================================================

  SEV   ID                                CONF   DOMAIN
  ---   --                                ----   ------
  !!    gotcha-prisma-json-stringify       0.90   database
  !!    gotcha-next-cache-corruption       0.85   web-development
  !     gotcha-vercel-sitemap-ping         0.70   deployment
  .     gotcha-overlay-network-deploy      0.65   deployment

  Severity: !! = critical/high  ! = medium  . = low

================================================================
```

## Edge cases

- **No errors in session**: "No errors found in this session. Describe the error manually: /cx-gotcha 'description'"
- **Error without resolution**: capture with severity "low" and confidence 0.30 (needs more evidence)
- **Duplicate gotcha**: update existing instead of creating new, bump confidence
- **Hooks not active**: /cx-gotcha works without hooks — analyzes the current session directly

## What NOT to do

- Do not capture non-errors as gotchas (use /cx-learn for general patterns)
- Do not set confidence above 0.80 on first capture
- Do not auto-promote on first occurrence — require 2+ projects
