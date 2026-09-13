# Operating the dashboard

Short version: the menu-bar app is the dashboard, and it collects its own
data. Open it, leave it running, and glance at the icon.

## What runs what

- **The app** (`FSMetrics.app`) starts the collector and draws the
  dashboard. It lives in the menu bar — no Dock icon, no window on launch.
- **The CLI** (`fsmetrics collect`, bundled at
  `/Applications/FSMetrics.app/Contents/Resources/fsmetrics`) is the same
  collector for headless machines, e.g. a Mac mini running as an AI/storage
  node with nobody logged in.
- Both write the same SQLite file (`db_path` in settings), so the dashboard
  shows data from either one.

Use one or the other. Running the menu-bar app and the LaunchAgent at the
same time means two collectors writing the same database.

## First run

1. Grant Full Disk Access to FSMetrics or user scans will come back empty:
   System Settings → Privacy & Security → Full Disk Access.
2. Check settings (menu bar icon → Settings…) match your setup: volumes,
   scan paths, intervals, thresholds, optional webhook.
3. Hit **Collect Now**, then **Open Dashboard**.

## Day to day

- Menu bar icon shows worst current severity and latest throughput.
- The dashboard has throughput/IOPS/average I/O size charts, capacity over
  time, volume health cards, per-user usage, and recent alerts. The volume
  picker at the top scopes every panel.
- Alerts cover capacity, per-user growth, per-user quota, SMART/read-only/NFS
  problems, and stalled I/O. Duplicates are suppressed during a cooldown.
  **View activity** opens the relevant folder in Finder.
- Alert rows are local. Nothing leaves the machine unless you set a webhook.
- Change intervals and thresholds any time in Settings; they apply on the
  next cycle.

## Headless

```bash
# One cycle
fsmetrics collect --once

# Continuous (Ctrl-C to stop)
fsmetrics collect
```

To start at login and keep it alive, run `Scripts/install-agent.sh`. It needs
a logged-in desktop session (it uses `launchctl bootstrap gui/$UID`), so
don't run it over SSH. It prints the uninstall command when it finishes.

## Peeking from the CLI

```bash
fsmetrics status              # latest per-volume summary + recent alerts
fsmetrics export --since 48   # JSON series + alerts for the last 48h
```

Both accept `--config <path>` if you keep settings somewhere non-default.

## Quick troubleshooting

- **Dashboard empty** — run Collect Now or `fsmetrics collect --once`, and
  confirm `db_path` in Settings is where the collector writes.
- **Per-user table empty** — Full Disk Access is off, or the volume has
  `watch_users` off / unhelpful `scan_paths`.
- **Throughput says "no samples"** — `iostat` needs two reads to produce a
  delta; give it a poll interval.
- **Too many or too few alerts** — tune thresholds and cooldown in Settings.

Files: config at
`~/Library/Application Support/FSMetrics/settings.json`, database next to it
(`metrics.sqlite` by default).
