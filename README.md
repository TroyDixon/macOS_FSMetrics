# macOS_FSMetrics

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
- Surfaces NFS timeouts/retransmits, and stalled I/O

## What you get

- A menu-bar app with a dashboard (charts, volume cards, per-user table, recent alerts)
- A CLI for collecting, checking status, and exporting (`collect`, `status`, `export`)
- A shared store both front ends read and write

## Build & run

Requires macOS 15+ and the Swift 6 toolchain from the Command Line Tools.
The first build fetches dependencies, so it needs network access.

### Prereqs

```bash
xcode-select --install
git --version   # git ships with the Command Line Tools
```

```bash
git clone https://github.com/TroyDixon/macOS_FSMetrics.git
cd macOS_FSMetrics

# Dependencies 
swift build
swift test

# Build and launch the app:
Scripts/bundle.sh
open build/FSMetrics.app
```

### Demo quick start

`Scripts/demo.sh` wraps the above into a two-command demo flow. It installs
the app to `/Applications`, seeds chart history, and — critically — gets Full
Disk Access granted *before* the first collection cycle, so the Documents /
Desktop / Downloads / Pictures permission popups never appear.

```bash
# Once, before the demo (a few minutes: release build + 8 seeded cycles):
Scripts/demo.sh --setup

# ...grant Full Disk Access when the pane opens and setup pauses, then:

# On demo day (<1s, never rebuilds — rebuilding would revoke the grant):
Scripts/demo.sh
```

After `--setup` pauses, add `/Applications/FSMetrics.app` in the opened Full
Disk Access pane (Cmd+Shift+G to type the path) and toggle it on; with
`--with-agent`, also add
`/Applications/FSMetrics.app/Contents/Resources/fsmetrics`. `--verify`
confirms per-user metrics are flowing.

Useful flags: `--seed N` (collection cycles used to seed chart history),
`--with-agent` (also install the LaunchAgent), and `--reset-settings`
(restore `config.example.json` defaults, backing up the previous settings).

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
  "user_quota_bytes": 0,
  "scan_paths": ["/Volumes/Research"]
}
```

You can set capacity warn/critical levels, per-user growth limits, a
per-volume per-user quota (0 disables), stall detection, and alert cooldowns.

## Alerts

- Capacity warnings when a volume fills past configured levels
- Per-user growth warnings when someone writes a lot in a short window
- Per-user quota warnings when a user's total crosses a volume's configured limit (`user_quota_bytes`, 0 disables the rule)
- Drive and mount warnings (SMART failures, unexpected read-only volumes, NFS mounts down)
- Stall warnings when I/O samples stop arriving
- Duplicate alerts are suppressed for a cooldown period
- Each alert row has a **View activity** button that reveals the relevant folder (a user's home for growth alerts, the volume otherwise) in Finder

Alerts are saved locally and can also post to a webhook and show as
notifications.

## Future work

See `docs/FUTURE_WORK.md`. Highlights: kernel-enforced quotas,
per-process I/O attribution, multi-host aggregation, retention/rollups,
wear-level trend lines, deeper pNFS stats, and signed distribution.

## License

MIT — see [`LICENSE`](LICENSE).
