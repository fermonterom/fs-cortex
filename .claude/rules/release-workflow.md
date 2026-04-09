# Release Workflow — Mandatory Pre-Push Checklist

## Rule: NEVER push to remote without version + changelog + README review

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
- `skills/cortex/SKILL.md` — header version only if major/minor bump
- `install.sh` — `NEW_VERSION="X.Y.Z"` near top of file
- `install.ps1` — `$NewVersion = "X.Y.Z"` near top of file

### 2b. Verify installer consistency

- `core/claudemd-section.md` lists ALL current commands
- `core/memory.template.json` version matches major release
- `README.md` install instructions are up to date

### 3. Write CHANGELOG entry

Follow [Keep a Changelog](https://keepachangelog.com/) format with these sections:
- **Security** — vulnerability fixes (always first)
- **Added** — new features
- **Changed** — changes to existing features
- **Fixed** — bug fixes
- **Removed** — removed features
- **Deprecated** — soon-to-be removed features

Each entry must be specific: file/command affected + what changed. No vague descriptions.

### 4. Update README.md if needed

Check if any of your changes affect:
- **Commands table** — new command added? Update count and table
- **Architecture section** — new hook, agent, or data directory?
- **Install/Update instructions** — file paths changed?
- **Security section** — new security measure?
- **Tests section** — new test suite?
- **Learning Pipeline diagram** — new step in the workflow?

If yes to any, update the corresponding README section. The README is the public face of the project.

### 5. Create git tag

After committing the version bump, create an annotated tag:

```bash
git tag -a vX.Y.Z -m "vX.Y.Z — Brief description of release"
```

Push tags with the code:

```bash
git push && git push --tags
```

### 6. Verify before push

```
git diff HEAD -- CHANGELOG.md  # Must show changes
bash tests/test_security.sh && bash tests/test_dream_cycle.sh  # Must pass
```

## Complete push sequence

```bash
# 1. Tests pass
bash tests/test_security.sh && bash tests/test_dream_cycle.sh

# 2. Commit with version bump
git add -A && git commit -m "chore(release): vX.Y.Z — description"

# 3. Tag
git tag -a vX.Y.Z -m "vX.Y.Z — description"

# 4. Push code + tags
git push && git push --tags
```

## What NOT to do

- NEVER push with only code changes and no version/changelog update
- NEVER use "chore: misc fixes" without itemizing in CHANGELOG
- NEVER skip tests before push
- NEVER bump version without a CHANGELOG entry explaining why
- NEVER forget to push tags after creating them
- NEVER leave README outdated when adding commands, hooks, or security features
