# Release Workflow — Mandatory Pre-Push Checklist

## Rule: NEVER push to remote without version + changelog

Before ANY `git push` to `main` or creating a PR that targets `main`, you MUST:

### 1. Determine version bump (Semantic Versioning)

- **patch** (x.y.Z): bug fixes, security patches, typos — no new features, no breaking changes
- **minor** (x.Y.0): new features, new commands, new modules — backward compatible
- **major** (X.0.0): breaking changes, architectural rewrites, incompatible API changes

Examples for this project:
- Adding secret scrubbing patterns → patch
- New `/cx-dream` command → minor
- Rewriting observer from bash to python → major

### 2. Update version in ALL locations

- `CHANGELOG.md` — new entry at top with `## [X.Y.Z] — YYYY-MM-DD`
- `skills/cortex/SKILL.md` — header `# Cortex vX.Y — Continuous Learning System`

### 3. Write CHANGELOG entry

Follow [Keep a Changelog](https://keepachangelog.com/) format with these sections:
- **Security** — vulnerability fixes (always first)
- **Added** — new features
- **Changed** — changes to existing features
- **Fixed** — bug fixes
- **Removed** — removed features
- **Deprecated** — soon-to-be removed features

Each entry must be specific: file/command affected + what changed. No vague descriptions.

### 4. Verify before push

```
git diff HEAD -- CHANGELOG.md  # Must show changes
git diff HEAD -- skills/cortex/SKILL.md  # Must show version if bumped major/minor
bash tests/test_security.sh && bash tests/test_dream_cycle.sh  # Must pass
```

## What NOT to do

- NEVER push with only code changes and no version/changelog update
- NEVER use "chore: misc fixes" without itemizing in CHANGELOG
- NEVER skip tests before push
- NEVER bump version without a CHANGELOG entry explaining why
