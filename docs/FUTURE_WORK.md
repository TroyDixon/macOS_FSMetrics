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

## 4. Native macOS client
The current dashboard is a Flask + Chart.js web app, chosen for demo speed
and judge accessibility (runs anywhere, zero install beyond Python). A
production version for this audience (macOS-only AI infra admins) would
likely be:
- A SwiftUI menu-bar app that polls the same SQLite store directly (no HTTP
  hop needed on localhost), with native notification-center alerts instead
  of/alongside the webhook.

## 5. Retention & rollups
The `metrics` table currently grows unbounded. At real polling intervals
over weeks/months this needs:
- A rollup job that compacts old high-resolution samples into hourly/daily
  aggregates (min/max/avg), similar to RRDtool or Prometheus's downsampling,
  keeping raw resolution only for a recent window (e.g. 7 days).

## 6. Per-process I/O attribution
`performance.collect_fs_usage_sample()` is wired up but off by default
(requires root, high volume of output). A real deployment would:
- Run it as a privileged helper, parse it properly (its text format shifts
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
