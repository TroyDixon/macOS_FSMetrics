# macOS AI File System Metrics

**TTU HackWesTex 2026 — Developer Challenge submission**

Monitors file systems on macOS (local APFS and shared NFS/pNFS) — the kind of
storage behind local AI setups where terabytes sit at rest with no
admin-facing tooling built for macOS.

## What it does

- Checks filesystem and drive health (capacity, writability, SMART / NVMe status)
- Measures I/O performance in GB/s
- Tracks capacity and per-user storage usage
- Watches local (APFS) and shared (NFS/pNFS) volumes
- Shows everything in a menu-bar app with a dashboard
- Alerts on full volumes, failing drives, and rapid per-user growth
- Surfaces largest paths, NFS timeouts/retransmits, and stalled I/O

## What you get

- A menu-bar app with a dashboard (charts, volume cards, per-user table, recent alerts)
- A CLI for collecting, checking status, and exporting (`collect`, `status`, `export`)
- A shared store both front ends read and write

## Build & run

Requires macOS 15+ and the Swift 6 toolchain from the Command Line Tools.
The first build fetches dependencies, so it needs network access.

```bash
git clone <this-repo>
cd macos-fs-metrics

swift build
swift test

# One collection cycle:
swift run fsmetrics collect --once

# Latest per-volume summary:
swift run fsmetrics status

# Build and launch the app:
Scripts/bundle.sh
open build/FSMetrics.app

# Optional: run the collector at login:
Scripts/install-agent.sh
```

## Using the app

The app lives in the menu bar (no Dock icon, no window at launch).

- **Status** — icon shows worst current severity and latest throughput
- **Open Dashboard** — throughput and capacity charts, volume cards, per-user usage, recent alerts
- **Collect Now** — runs a collection cycle immediately
- **Settings…** — volumes, scan intervals, thresholds, webhook URL, database path
- **Quit** — stops the app and background collection

The app and CLI share the same database, so `fsmetrics status` reflects what
the UI last collected. To keep it in Applications:

```bash
cp -R build/FSMetrics.app /Applications/
open /Applications/FSMetrics.app
```

For quick UI work, `swift run FSMetricsApp` also works but shows a Dock icon
and skips notifications — use `Scripts/bundle.sh` for the real thing.

Confirm data is being written:

```bash
sqlite3 "$HOME/Library/Application Support/FSMetrics/metrics.sqlite" \
  'select kind, count(*) from metric group by kind;'
```

## Configuration

Copy the example config and edit it:

```bash
mkdir -p "$HOME/Library/Application Support/FSMetrics"
cp config.example.json "$HOME/Library/Application Support/FSMetrics/settings.json"
```

Only list volumes that are actually mounted. To watch an NFS mount, add an
entry for it once the mount exists:

```json
{
  "path": "/Volumes/Research",
  "kind": "nfs",
  "label": "Research (NFS/pNFS)",
  "watch_users": true,
  "scan_paths": ["/Volumes/Research"]
}
```

You can set capacity warn/critical levels, per-user growth limits, stall
detection, alert cooldowns, and an optional Slack-compatible webhook URL.

## Alerts

- Capacity warnings when a volume fills past configured levels
- Per-user growth warnings when someone writes a lot in a short window
- Drive and mount warnings (SMART failures, read-only volumes, NFS mounts down)
- Stall warnings when I/O samples stop arriving
- Duplicate alerts are suppressed for a cooldown period

Alerts are saved locally and can also post to a webhook and show as
notifications.

## Permissions

Reading per-user usage under `/Users` and some drive-health details needs
Full Disk Access. Grant it in **System Settings → Privacy & Security → Full
Disk Access** to your terminal (for CLI runs) and/or the bundled app.

Without it, the affected checks are skipped gracefully.

## Repository layout

```
Package.swift
Sources/
  FSMetricsCore/   # collectors, store, alerting
  FSMetricsApp/    # menu-bar app + dashboard
  fsmetrics/       # CLI
Tests/
Scripts/
  bundle.sh        # assemble + sign FSMetrics.app
  install-agent.sh # autostart at login
config.example.json
docs/
```

## Future work

See `docs/FUTURE_WORK.md`. Highlights: kernel-enforced quotas,
per-process I/O attribution, multi-host aggregation, retention/rollups,
wear-level trend lines, deeper pNFS stats, and signed distribution.
