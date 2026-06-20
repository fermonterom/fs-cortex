# Auto-running `/cx-eod` on a schedule (macOS launchd)

`/cx-eod` is **idempotent**: it gathers the last 24 hours deterministically, so
running it several times a day regenerates the same day's summary file instead of
duplicating it. Each run is recorded under a `## Ejecuciones hoy` block, so you can
see it fired at, say, 15:02 / 19:01 / 22:03.

This directory contains an example launchd agent to run it automatically.

## Files

| File | Purpose |
|------|---------|
| `com.cortex.cx-eod.plist` | launchd agent template (placeholders for paths + hours) |
| `install-cx-eod-agent.sh` | helper that fills the template, copies it to `~/Library/LaunchAgents/`, and loads it |

## Install

```bash
bash examples/launchd/install-cx-eod-agent.sh
```

This finds your `claude` CLI, materializes the plist into
`~/Library/LaunchAgents/com.cortex.cx-eod.plist`, and loads it. Default schedule:
**15:00, 19:00, 22:00** every day. Edit `StartCalendarInterval` in the plist to
change the hours, then re-run the helper (it reloads safely).

## Uninstall

```bash
bash examples/launchd/install-cx-eod-agent.sh --uninstall
```

## Verify

```bash
launchctl list | grep com.cortex.cx-eod
# logs:
cat ~/.claude/cortex/log/cx-eod-launchd.out.log
```

## Linux

launchd is macOS-only. On Linux, schedule `claude -p "/cx-eod --auto"` with cron:

```cron
0 15,19,22 * * * /path/to/claude -p "/cx-eod --auto" >> ~/.claude/cortex/log/cx-eod-cron.log 2>&1
```

or an equivalent systemd timer.
