# Future Work

Scoped as concrete next PRs, roughly in the order we'd tackle them.

## 1. Real per-user quota enforcement, not just monitoring
Today, "quotas" are soft thresholds we enforce ourselves by watching UID
byte totals. A deeper version would:
- Ship a small `launchd` daemon that can actually deny writes past a
  threshold (via a FUSE-mounted APFS-backed volume, or by integrating with
  macOS's Open Directory / role account groups to apply per-group storage
  caps).
- Compare against how HFS+ and ZFS expose kernel-level quotas, and evaluate
  whether an APFS role-account-based emulation gets close enough for a
  production deployment.

## 2. Deeper pNFS layout stats
macOS's NFS client supports pNFS but doesn't expose per-layout-type
statistics (file/block/object layouts) to userland tools the way Linux's
`nfsstat` extensions or `nfs4_getfacl` tooling can. This would require
either:
- A kernel extension / DriverKit extension to read layout state directly, or
- Cross-referencing server-side pNFS metadata (if the file server exposes
  it) rather than relying on the client alone.

## 3. Trend-based health instead of point-in-time pass/fail
`health.smart_ok` today is a boolean snapshot. A meaningful upgrade:
- Track NVMe wear-leveling count / percentage-used-reserve over time and
  alert on *trend*, not just failure state — the same way cloud providers
  predict drive failure before SMART actually flips to failing.
- Correlate performance degradation (throughput trending down) with
  capacity trending up, since near-full APFS containers measurably slow
  down on some workloads.

## 4. Signed distribution
The native client is done: the Flask + Chart.js dashboard was replaced by the
SwiftUI menu-bar app and dashboard in `Sources/FSMetricsApp/`, which read the
SQLite store directly. What remains is distribution:
- `Scripts/bundle.sh` only ad-hoc signs `FSMetrics.app`. Signing with a
  Developer ID and notarizing it would let admins install without Gatekeeper
  overrides. See `docs/REQUIREMENTS_FEASIBILITY.md` §5I for how bundling and
  signing affect notifications and autostart (today's fallbacks are AppleScript
  and a LaunchAgent).

## 5. Retention & rollups
The SQLite `metric` table currently grows unbounded. At real polling intervals
over weeks/months this needs:
- A rollup job that compacts old high-resolution samples into hourly/daily
  aggregates (min/max/avg), similar to RRDtool or Prometheus's downsampling,
  keeping raw resolution only for a recent window (e.g. 7 days).

## 6. Per-process I/O attribution
Not collected today: `fs_usage` requires root and produces a high volume of
output, and Endpoint Security needs an Apple-granted entitlement (see
`docs/REQUIREMENTS_FEASIBILITY.md` §2G). A real deployment would:
- Run `fs_usage` as a privileged helper, parse it properly (its text format shifts
  across macOS versions), and attribute GB/s to specific processes/users —
  which would make the "nefarious user" story much sharper: not just "this
  user's total grew fast" but "this specific process on this user's session
  is currently writing at 400 MB/s."

## 7. Multi-host fleet view
Currently one collector writes to one local SQLite file. For an
organization running several Mac Studios/Minis as AI infra nodes, the
dashboard should aggregate across hosts — either by having each collector
push to a shared Postgres/TimescaleDB instance, or by having the dashboard
poll each host's local SQLite over a lightweight internal API.
