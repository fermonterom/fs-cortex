# Auto-running cx-eod on a schedule (macOS launchd / cron)

cx-eod's `--auto` path is **fully deterministic**: the gather script composes and
writes the daily summary itself, with **no model call**. So you automate it by
calling the script directly — **not** `claude -p`. That means **zero model quota**,
no auth token, and no API-key risk.

`--auto` is also **idempotent**: it gathers the last 24 hours, so running it several
times a day regenerates the same day's summary instead of duplicating it. Each run
is recorded under a `## Ejecuciones hoy` block (e.g. 15:02 / 19:01 / 22:03).

## The command

```bash
bash ~/.claude/cortex/core/_cx-eod-gather.sh --write
```

Writes `~/.claude/cortex/daily-summaries/<date>.md`. `hooks/session-start.py`
reinjects it (Quick Resume + For tomorrow) next session.

## Option A — cron (simplest, portable)

```cron
0 15,19,22 * * * bash ~/.claude/cortex/core/_cx-eod-gather.sh --write >> ~/.claude/cortex/log/cx-eod-cron.log 2>&1
```

Edit with `crontab -e`. Runs against your local data whenever the machine is on.

## Option B — launchd (macOS native)

| File | Purpose |
|------|---------|
| `com.cortex.cx-eod.plist` | launchd agent template (placeholders for HOME + hours) |
| `install-cx-eod-agent.sh` | helper that fills the template, copies it to `~/Library/LaunchAgents/`, and loads it |

```bash
bash examples/launchd/install-cx-eod-agent.sh
```

Default schedule: **15:00, 19:00, 22:00** every day. Edit `StartCalendarInterval`
in the plist to change the hours, then re-run the helper (it reloads safely).

Uninstall:

```bash
bash examples/launchd/install-cx-eod-agent.sh --uninstall
```

Verify:

```bash
launchctl list | grep com.cortex.cx-eod
cat ~/.claude/cortex/log/cx-eod-launchd.out.log
```

## Why not `claude -p`?

A headless `claude -p "/cx-eod --auto"` would spend your subscription's model
quota (and silently fall back to paid API if `ANTHROPIC_API_KEY` is in the cron
environment) just to turn deterministic JSON into markdown. Since the script does
that itself, the scheduler never needs a model. Reserve the interactive `/cx-eod`
(which does use the model, in your already-paid session) for when you want a
judgment-composed summary.
