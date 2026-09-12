# macOS AI File System Metrics

**TTU HackWesTex 2026 — Developer Challenge submission**

A native-tooling suite for monitoring and reporting on macOS-hosted file
systems (local APFS and shared NFS/pNFS) — the kind of storage backing local
AI infrastructure (OpenClaw, Exo, and similar) where terabytes of data sit at
rest with no admin-facing tooling built for macOS.

The product is a SwiftPM package with three parts: `FSMetricsCore` (collectors,
store, alerting), `FSMetricsApp` (SwiftUI menu-bar app + dashboard), and the
`fsmetrics` CLI.

## What it does

| Requirement from the prompt | Where it's implemented |
|---|---|
| Filesystem + backing block storage health | `Sources/FSMetricsCore/Collectors/HealthCollector.swift` (native capacity/writability; `diskutil` SMART status; `system_profiler SPNVMeDataType` controller health) |
| I/O performance (GB/s) | `Sources/FSMetricsCore/Collectors/PerformanceCollector.swift` (IOKit block-storage counters, `iostat` fallback → GB/s, transfers/sec) |
| Capacity + per-user quotas | `Sources/FSMetricsCore/Collectors/CapacityCollector.swift` + `Sources/FSMetricsCore/Sources/FileScanner.swift` (per-UID byte attribution via filesystem walk, since APFS has no native quota system) |
| Local (APFS) + shared (NFS/pNFS) volumes | `HealthCollector.swift` + `Sources/FSMetricsCore/Collectors/NFSCollector.swift` (mount health, pNFS detection, client retransmits/timeouts) |
| Admin-facing display | `Sources/FSMetricsApp/` — SwiftUI `MenuBarExtra` + dashboard window (Swift Charts) |
| Alerting on nefarious users / capacity | `Sources/FSMetricsCore/Alerts/AlertEngine.swift` — capacity thresholds + per-user growth-rate rule (with cooldown) |
| "Other interesting metrics" | Largest paths per volume, NFS client timeout/retransmit counts, throughput staleness detection |

## Architecture

```
  FSMetrics.app (SwiftUI MenuBarExtra + Dashboard)   fsmetrics CLI
                    \                                 (collect/status)
                     └──────────────┬──────────────────────┘
                                    ▼
                              FSMetricsCore
      collectors ──▶ SQLiteMetricStore ──▶ AlertEngine ──▶ Notifier
   Health/Perf/Capacity/NFS     GRDB        thresholds +    osascript /
                                    │       growth rule     webhook
                                    ▼
              ~/Library/Application Support/FSMetrics/metrics.sqlite
```

Collectors depend on injected ports (`VolumeSource`, `FileScanner`,
`CommandRunning`, `DiagnosticsProbe`, `BlockStatsSource`, `NFSTool`), so every
collector is testable at its interface with fixtures instead of shelling out.

Every collector writes into **one normalized table** —
`metric(ts, kind, host, volume, uid, username, value, unit)` — and alerts go
to `alert(ts, host, volume, severity, category, message, uid)`, so the
dashboard and alert engine never need to know which collector produced a
given number. This is the contract that lets the collectors, the store, the
alert engine, and both front ends evolve independently. See
`Sources/FSMetricsCore/Store/SQLiteMetricStore.swift` for the schema.

## Why this data model (APFS quotas)

APFS has no native per-user quota system the way ZFS or HFS+ (with
`quotacheck`) does. So "per-user quotas" here means: we attribute bytes to
the owning UID ourselves via a filesystem walk (`FileManager` with
`.ownerAccountIDKey`), store that as a time series, and enforce **soft,
admin-configured thresholds** in the alert engine rather than relying on
kernel enforcement. This is also exactly the same approach macOS's own
`du`/Finder "Get Info" size calculations use under the hood — just
aggregated by owner instead of by directory.

## Build & run

Requires macOS 15+ and the Swift 6 toolchain that ships with the Command Line
Tools — no Xcode required. The first `swift build` fetches GRDB.swift, so it
needs network access.

```bash
git clone <this-repo>
cd macos-fs-metrics

swift build
swift test

# One collection cycle against this Mac's real volumes:
swift run fsmetrics collect --once

# Latest per-volume summary:
swift run fsmetrics status

# Hand-assemble and ad-hoc sign the SwiftUI app, then launch it:
Scripts/bundle.sh
open build/FSMetrics.app

# Optional: start the collector at login and keep it alive (LaunchAgent):
Scripts/install-agent.sh
```

`Scripts/bundle.sh` builds `build/FSMetrics.app` with `LSUIElement = true`
(menu-bar only) and an ad-hoc signature (`codesign --sign -`), and places the
`fsmetrics` CLI at `build/FSMetrics.app/Contents/Resources/fsmetrics` so the
LaunchAgent can use the bundled copy. (It lives in `Resources`, not `MacOS`:
a case-insensitive filesystem would otherwise collide with the app's
`MacOS/FSMetrics` executable.) `Scripts/install-agent.sh` prefers a
bundled CLI (`/Applications/FSMetrics.app` first, then `build/FSMetrics.app`)
and falls back to the SwiftPM release build.

### Launching the UI

`FSMetricsApp` is a **menu-bar-only** SwiftUI app (`LSUIElement = true`): it has
no Dock icon and deliberately does not open a window at launch. After
`open build/FSMetrics.app`, look for its icon in the macOS menu bar.

```bash
# 1. Build + ad-hoc sign the bundle (release):
Scripts/bundle.sh

# 2. Launch it:
open build/FSMetrics.app
```

If nothing appears, verify the bundle; if you copied the `.app` from another
machine, also clear the quarantine flag:

```bash
codesign --verify --verbose build/FSMetrics.app
xattr -dr com.apple.quarantine build/FSMetrics.app   # only for downloaded copies
```

Once the menu-bar icon is visible, click it:

1. **Status** — the icon's symbol and label show the worst current severity and
   the latest `perf.throughput_gbps`; the dropdown also shows the age of the
   last capacity scan.
2. **Open Dashboard** — opens the main window: throughput (1 h) and capacity
   history (6 h) charts with volume pickers, volume summary cards, the per-user
   usage table, and recent alerts. The window is suppressed at launch and can
   be closed and reopened from the menu.
3. **Collect Now** — runs a full collection cycle immediately (including the
   per-user capacity walk) instead of waiting for the poll interval.
4. **Settings…** — volumes (path, kind, label, `watch_users`, `scan_paths`),
   poll and capacity-scan intervals, host label, all alert thresholds, webhook
   URL, and database path. Saving writes
   `~/Library/Application Support/FSMetrics/settings.json` and applies to
   subsequent cycles.
5. **Quit** — stops the app (and its background collection loop).

The app reads and writes the same database as the CLI
(`~/Library/Application Support/FSMetrics/metrics.sqlite`), so `fsmetrics
status`/`export` reflect whatever the UI last collected. To keep the app in
your Applications folder:

```bash
cp -R build/FSMetrics.app /Applications/
open /Applications/FSMetrics.app
```

For UI development without assembling a bundle, `swift run FSMetricsApp` works
too — but without an `Info.plist` it is not menu-bar-only (it gets a Dock icon)
and native notifications are skipped, so use `Scripts/bundle.sh` for the real
thing. Grant Full Disk Access to whichever binary collects — see
[Permissions](#permissions-full-disk-access).

Confirm a cycle wrote rows:

```bash
sqlite3 "$HOME/Library/Application Support/FSMetrics/metrics.sqlite" \
  'select kind, count(*) from metric group by kind;'
```

## Configuration

`config.example.json` is the Swift replacement for `config.yaml`. Keys are
snake_case and map 1:1 onto `Settings` in
`Sources/FSMetricsCore/Config/Settings.swift`. Copy it to the default
location and edit:

```bash
mkdir -p "$HOME/Library/Application Support/FSMetrics"
cp config.example.json "$HOME/Library/Application Support/FSMetrics/settings.json"
```

`fsmetrics collect --config <path>` can point at any config file. If
`settings.json` is absent, built-in defaults are used (root APFS volume,
database in Application Support).

The example ships only the root APFS volume (`/`, `watch_users: true`,
`scan_paths: ["/Users"]`) because every configured volume must actually be
mounted. To watch an NFS/pNFS mount, add a second entry (this is not in
`config.example.json` — JSON has no comments, and a configured-but-absent NFS
mount raises a mount-down alert, so add it once the mount exists):

```json
{
  "path": "/Volumes/Research",
  "kind": "nfs",
  "label": "Research (NFS/pNFS)",
  "watch_users": true,
  "scan_paths": ["/Volumes/Research"]
}
```

`kind` is one of `apfs`, `nfs`, `smb`, `other`. `watch_users: true` enables
the per-UID walk over `scan_paths` (leave it off for very large or slow
mounts). `thresholds` holds the capacity warn/critical percentages, the
per-user growth window/threshold, the throughput-stall window, and `cooldown`
for duplicate-alert suppression. `webhook_url` is an optional Slack-compatible
endpoint. `simulate` is accepted for config compatibility but no synthetic
collector is implemented yet — it currently has no effect.

## Permissions (Full Disk Access)

Reading per-user usage under `/Users` and some block-device health data
(SMART/NVMe via `diskutil` / `system_profiler`) is gated by macOS TCC. Grant
Full Disk Access in **System Settings → Privacy & Security → Full Disk
Access** to the process that collects:

- the terminal application you run `swift run fsmetrics ...` from, and/or
- `build/FSMetrics.app/Contents/Resources/fsmetrics` for bundled or
  LaunchAgent runs (use the `+` button to add the executable; granting the
  whole `FSMetrics.app` also covers the SwiftUI app).

Without the grant, the affected collectors degrade gracefully — they emit no
metric instead of failing the cycle.

## Units

- `perf.throughput_gbps` is **SI GB/s**: bytes/second ÷ 1e9.
- macOS `iostat` reports MB/s; the fallback parser treats those numbers as
  MiB/s and converts with `× 1_048_576 / 1e9` before reporting GB/s.
- `perf.kb_per_transfer` is KiB/transfer (`iostat`'s KB/transfer).
- Capacity values are raw bytes, percentages are 0–100, and NFS counters are
  counts.

## Data sources used (macOS-native, no third-party agents)

Native APIs first; CLI probes only where macOS exposes no clean API:

- `FileManager.mountedVolumeURLs` + `statfs` — mounted volumes and filesystem type
- `URL.resourceValues` / `statfs` — capacity, free space, read-only state
- `FileManager` enumerator with `.ownerAccountIDKey` — per-UID byte attribution and bounded top-N largest paths
- IOKit `IOBlockStorageDriver` statistics — cumulative block-storage counters diffed into throughput
- `diskutil info -plist <volume>` — SMART status, filesystem type, encryption state
- `system_profiler SPNVMeDataType -json` — internal Apple Silicon NVMe controller health
- `iostat -d -c 2 <disk>` — fallback I/O throughput (KiB/transfer, transfers/sec, MiB/s → GB/s)
- `nfsstat -m` / `nfsstat -c` — per-mount NFS/pNFS configuration, pNFS flag, client timeouts/retransmits
- `getpwuid` — UID → username

pNFS layout-type statistics are not available to userland on macOS; the
collector reports the pNFS flag and client counters only.

## Alerting logic ("nefarious users" + capacity)

`AlertEngine` runs after every poll cycle and is pure (`evaluate` returns
events; the service persists them and dispatches notifications):

1. **Capacity thresholds** — warn at 80% used, critical at 95% (configurable).
2. **Per-user growth-rate rule** — if any user's attributed bytes grow by
   more than a configured amount (default 5 GB) within a configured window
   (default 10 minutes), fire a warning naming that user. This is
   deliberately framed as *rate of change*, not just *total size*, since a
   researcher legitimately storing 4 TB of data is normal, but anyone
   suddenly writing tens of GB in a few minutes — malicious or a runaway
   training/checkpoint job — is worth a human look.
3. **Health rules** — SMART not-OK, volume not writable, NFS mount down.
4. **Throughput-stall detection** — no I/O samples inside a configured
   window usually means the collector or the underlying mount is stuck.
5. **Cooldown/dedup** — an identical alert (same rule + volume + uid) within
   the cooldown window is suppressed, fixing the Python behavior where the
   same alert re-fired every poll and inflated the table.

Alerts are written to the durable `alert` table and optionally POSTed to a
Slack-compatible webhook and/or delivered as notifications.

## Repository layout

```
Package.swift
Sources/
  FSMetricsCore/            # library
    Metric.swift            # Metric, MetricKind, Unit, Sample, AlertEvent
    MetricStore.swift       # store protocols (the seam)
    Clock.swift
    Config/Settings.swift   # Codable settings (config.example.json)
    Store/SQLiteMetricStore.swift
    Store/InMemoryMetricStore.swift
    Sources/                # ports: CommandRunning, VolumeSource, FileScanner,
                            # DiagnosticsProbe, BlockStatsSource, NFSTool
    Collectors/             # Health, Performance, Capacity, NFS
    Alerts/AlertEngine.swift
    Notify/Notifier.swift
    Service/CollectorService.swift
  FSMetricsApp/             # SwiftUI menu-bar app + dashboard
  fsmetrics/                # CLI: collect / status / export
Tests/FSMetricsCoreTests/   # Swift Testing suites + Fixtures/
Scripts/
  bundle.sh                 # assemble + ad-hoc sign FSMetrics.app
  install-agent.sh          # LaunchAgent autostart
config.example.json
docs/FUTURE_WORK.md
docs/SWIFT_TRANSLATION_PLAN.md
```

## Module split

Three independently-testable tracks share one contract (the `metric`/`alert`
tables in `MetricStore`):

- **Health & performance** (`HealthCollector`, `PerformanceCollector` and
  their ports) — SMART/block health + GB/s throughput.
- **Capacity, quotas & shared volumes** (`CapacityCollector`, `FileScanner`,
  `NFSCollector`) — per-user usage attribution + NFS/pNFS support.
- **Store, dashboard & alerting** (`SQLiteMetricStore`, `AlertEngine`,
  `FSMetricsApp`) — the data contract, the admin UI, and the decoding layer.

`CollectorService` is the thin integration point that only has to be touched
once everyone's collectors exist.

## Future work

See `docs/FUTURE_WORK.md` (written during the Python implementation) and
`docs/SWIFT_TRANSLATION_PLAN.md` (§1 non-goals, P6). Highlights:

- Kernel-enforced per-user quotas (soft thresholds remain monitoring-only).
- Per-process I/O attribution via `fs_usage`.
- Multi-host fleet aggregation.
- Historical rollups/retention for the SQLite store (currently unbounded).
- SMART/NVMe wear-leveling trend lines instead of a point-in-time pass/fail.
- Deeper pNFS layout-type stats (not exposed to userland on macOS today).
- Distribution/notarization once a Developer ID signing identity exists.
