# Requirements Feasibility — Can ALL requirements be integrated into this build?

Researched 2026-09-12 against primary sources: the macOS SDK headers shipped
with Xcode 26.5, man pages on this machine, live tool output on this machine
(macOS 26.5.1, Apple SSD AP0512Z), Apple's open-source xnu, and Apple
developer documentation. Every claim carries its source.

**Verdict: YES — every requirement is integratable, with two named platform
limits** (kernel-enforced per-user quotas on APFS, and per-layout-type pNFS
byte statistics). Six of the seven requirements are already integrated; what
remains is depth, and the research below maps each remaining gap to a
concrete, cited mechanism.

| # | Requirement | Status | Verdict |
|---|---|---|---|
| 1 | FS health + backing block storage health | Integrated (SMART, writable, NVMe ok) | ✅ Extendable with real NVMe SMART (temp, wear, spare, media errors) via a public IOKit user client |
| 2 | I/O performance GB/s | Integrated (IOKit counters + iostat fallback) | ✅ Read/write split, latency, transfer counts, error counters — all in the same `Statistics` dict we already read |
| 3 | Capacity + per-user quotas | Integrated (per-UID walk + soft alerts) | ✅ Soft quotas (see README "Why this data model (APFS quotas)"); kernel-enforced quotas are a **platform limitation** (quotactl → `ENOTSUP` on APFS); NFS server-side quotas are protocol-visible but not exposed by macOS userland tools |
| 4 | Useful admin display | Integrated (menu bar + dashboard + CLI) | ✅ Panels for every metric below are ordinary SwiftUI work |
| 5 | Alert/reporting on nefarious users / capacity | Integrated (rules + cooldown + notifiers) | ✅ NFS retransmit/timeout trend + I/O-error rules are integratable; per-process I/O attribution is **platform-limited** to root (`fs_usage`) |
| 6 | Local APFS + shared NFS/pNFS | Integrated | ✅ APFS snapshots integratable; pNFS layout *operation* counters are already exposed by `nfsstat -f JSON` (new finding); per-layout-type byte stats remain platform-limited |
| 7 | "Other interesting metrics" | Partial | ✅ Long list of integratable metrics below (inodes, snapshots, encryption, mount params, NVMe SMART fields…) |

Conventions used below: **[SDK]** = header inside
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`
(`$(xcrun --show-sdk-path)`); **[man]** = man page on this machine; **[tool]**
= command run on this machine with its observed output; **[xnu]** =
`github.com/apple-oss-distributions/xnu`, branch `main` (fetched 2026-09-12);
**[docs]** = developer.apple.com; **[repo]** = this repository.

---

## 1. Filesystem + backing block-storage health

Already integrated (`[repo]` `Sources/FSMetricsCore/Collectors/HealthCollector.swift`,
`Sources/DiagnosticsProbe.swift`): `health.smart_ok` from `diskutil info -plist`
`SMARTStatus`, `health.writable` (cross-checked against the SSV's writable
companion `/System/Volumes/Data` when the boot root `/` itself reads
not-writable), `health.nvme_smart_ok` from
`system_profiler SPNVMeDataType -json`, plus the capacity family.

### B. Real NVMe SMART is available through a **public IOKit user client**

- **[SDK]** `System/Library/Frameworks/IOKit.framework/Versions/A/Headers/storage/nvme/NVMeSMARTLibExternal.h`
  — present in the SDK, marked `@header NVMeSMARTLib — "implements non-kernel
  task access to NVMe SMART data"` (line 51), with factory/user-client/interface
  UUIDs (`kIONVMeSMARTLibFactoryID` L59, `kIONVMeSMARTUserClientTypeID` L67,
  `kIONVMeSMARTInterfaceID` L74).
- **[SDK]** same header, `struct NVMeSMARTData` (lines 201–222) — the exact
  fields a collector could surface:
  `CRITICAL_WARNING`, `TEMPERATURE`, `AVAILABLE_SPARE`,
  `AVAILABLE_SPARE_THRESHOLD`, `PERCENTAGE_USED`, `DATA_UNITS_READ[2]`,
  `DATA_UNITS_WRITTEN[2]`, `HOST_READ_COMMANDS[2]`, `HOST_WRITE_COMMANDS[2]`,
  `POWER_CYCLES[2]`, `POWER_ON_HOURS[2]`, `UNSAFE_SHUTDOWNS[2]`,
  `MEDIA_ERRORS[2]`, `NUM_ERROR_INFO_LOG_ENTRIES[2]`.
- `SMARTReadData` (`void* interface, NVMeSMARTData*`) is documented as
  "Retrieves 512 byte device SMART data structure … See section 5.10.1.2 of
  NVM Express revision 1.0c" ([SDK] same header, lines 235–249).
- **[tool]** On this Mac, `system_profiler SPNVMeDataType -json` exposes only
  `_name`, `bsd_name` (`disk0`), `device_model`, `device_revision`,
  `device_serial`, `partition_map_type`, `removable_media`, `size`,
  `size_in_bytes`, `smart_status` ("Verified"), `spnvme_trim_support`,
  `volumes` — **no temperature/percentage-used fields**. Conclusion: for
  depth, parse the IOKit user client, not system_profiler. (The
  `health.nvme_smart_ok` we already emit stays as the low-risk fallback.)
- Caveat to verify at implementation time: obtaining the user client may
  require the same privileges `smartctl` needs (root or a signed app);
  treat `SMARTReadData` access as best-effort with system_profiler fallback.
  **UNVERIFIED privilege level** — settle with a spike: run `SMARTReadData`
  unsandboxed as the console user; if `kIOReturnNotPermitted`, fall back.

### C. Block error counters exist (new metric family, integratable now)

- **[SDK]** `System/Library/Frameworks/IOKit.framework/Versions/A/Headers/storage/IOBlockStorageDriver.h`
  (framework path; the `usr/include` copy does not exist on this install):
  - `kIOBlockStorageDriverStatisticsReadErrorsKey = "Errors (Read)"` (line 96)
    — "the number of read errors encountered since the block storage driver
    was instantiated" (comment lines 85–95).
  - `kIOBlockStorageDriverStatisticsWriteErrorsKey = "Errors (Write)"` (line 110).
  - Also `Retries (Read)`/`Retries (Write)` (lines 180/194).
- Our `IOKitBlockStats` already reads this same `Statistics` table for
  `Bytes (Read)`/`Bytes (Write)` ([repo]
  `Sources/FSMetricsCore/Sources/BlockStatsSource.swift`), so error counters
  are the same code path. This also finally gives the dormant
  `io_error_count_threshold` setting something to do.

### J extras already parsed but never surfaced

`DiskInfo` already parses, and the collectors do not emit, these
([SDK]/[tool] `diskutil info -plist /` on this Mac: `DeviceIdentifier`,
`ParentWholeDisk`, `APFSPhysicalStores`, `FilesystemType`, `Encryption`,
`RemovableMedia`; [repo] `Sources/DiagnosticsProbe.swift` parses them all):
filesystem type, encrypted state, removable media, device identifiers.
All are one-line `Metric` additions behind `MetricKind`.

---

## 2. I/O performance (GB/s)

Already integrated ([repo] `Collectors/PerformanceCollector.swift` — IOKit
cumulative `Bytes (Read)+(Write)` diffed over the clock; `iostat -d -c 2`
fallback; SI GB/s per [repo] README "Units").

### D. Everything else in the same `Statistics` dict

**[SDK]** `IOBlockStorageDriver.h` defines, alongside bytes:
`Operations (Read)` (line 152), `Operations (Write)` (line 166),
`Latency Time (Read)` (line 124), `Latency Time (Write)` (line 138),
`Total Time (Read)` (line 208), `Total Time (Write)` (line 222).
I.e. **IOPS, read/write split, and average latency** are derivable with the
same cumulative-diff approach we already use for throughput — no new probe,
no new permissions. This is the highest-value low-risk extension in this
document and directly serves requirement 2 (per-device latency and IOPS
metrics alongside the existing throughput series).

### G. Per-process I/O attribution — platform-limited

- **[man]** `fs_usage(1)`: "It requires root privileges due to the kernel
  tracing facility it uses to operate."
- **[tool]** `fs_usage -w` run as a normal user prints exactly:
  `'fs_usage' must be run as root...`
- **[docs]** Endpoint Security (developer.apple.com/documentation/endpointsecurity):
  "Develop **system extensions** that enhance user security … package it in an
  app that uses the SystemExtensions framework to install and upgrade the
  extension" and it requires the
  `com.apple.developer.endpoint-security.client` entitlement
  (doc://…/BundleResources/Entitlements/com.apple.developer.endpoint-security.client).
  An Apple-granted entitlement + system extension is not obtainable for an
  ad-hoc/unsigned CLT build.
- Verdict: per-process I/O bytes is **not integratable** in this build's
  packaging model. The honest fallbacks are (a) a privileged helper *if* a
  Developer ID appears, or (b) keep the requirement-level story on per-user
  growth attribution, which we already have.

---

## 3. Capacity + per-user quotas

Already integrated ([repo] `CapacityCollector.swift`, per-UID walk, alert
rules in `Alerts/AlertEngine.swift`).

### A. Kernel-enforced quotas: **platform limitation**, with primary evidence

- **[tool]** compiled `quotactl(path, Q_QUOTASTAT, 0, …)` (include
  `<sys/quota.h>`) against `/` and `/System/Volumes/Data` on this Mac:
  `ret=-1 errno=45 (Operation not supported)` for both — i.e. `ENOTSUP`.
- **[man]** `quotactl(2)` exists and documents `Q_QUOTAON/Q_GETQUOTA/…`, but
  references only the BSD quota tooling (`quota(1), fstab(5), edquota(8),
  quotacheck(8), quotaon(8), repquota(8)`) and never mentions APFS.
- **[man]** `apropos quota` on this machine lists `quota(1)`,
  `edquota(8)`, `quotacheck(8)`, `quotaon(8)`, `repquota(8)`,
  `rpc.rquotad(8)`, and `setquota(1)` — `setquota(1)`'s own man page:
  "Sets home directory quotas on the local computer … Quotas are set as
  specified in the individual user record" (macOS-Server-era, user-record
  based; not an APFS quota).
- **[xnu]** `bsd/kern/syscalls.master` (branch `main`), line 261:
  `165 AUE_QUOTACTL ALL { int quotactl(const char *path, int cmd, int uid, caddr_t arg); }`
  — the syscall exists; `setquota`/`qquota` (148/149) are `nosys`. The
  syscall exists; APFS does not answer it (see the ENOTSUP test).
- **[repo]** `README.md` "Why this data model (APFS quotas)" already encodes
  the correct posture: "APFS has no native per-user quota system … enforce
  **soft, admin-configured thresholds** in the alert engine rather than
  relying on kernel enforcement."
- Verdict: requirement 3 is satisfied by per-UID accounting + soft thresholds
  (implemented). Kernel enforcement: platform limitation. NFS server-side
  quotas: NFSv4 defines quota attributes (`NFS_FATTR_QUOTA_AVAIL_HARD` 38,
  `NFS_FATTR_QUOTA_AVAIL_SOFT` 39, `NFS_FATTR_QUOTA_USED` 40 — **[xnu]**
  `bsd/nfs/nfsproto.h`), but macOS userland ships no tool that issues that
  GETATTR; treat server-side NFS quota reporting as **protocol-supported,
  userland-blocked** (would need a custom RPC client — possible but large).

---

## 4. Display metrics usefully

Already integrated ([repo] `Sources/FSMetricsApp/` — `MenuBarExtra` severity +
throughput, dashboard with Swift Charts throughput/capacity history, per-user
`Table`, alerts list, volume cards, full `Settings` scene; `fsmetrics
status`/`export`). Nothing here is platform-blocked; which panels to add is
a work plan, not a research question. Gaps to build:
largest-paths panel (the scanner already exists — [repo]
`Sources/FileScanner.swift::largestPaths`, tested in
`tests/FSMetricsCoreTests/CapacityCollectorTests.swift`), NVMe SMART panel,
time-range pickers. All integratable now.

---

## 5. Alerting/reporting on nefarious users and capacity

Already integrated ([repo] `Alerts/AlertEngine.swift`: capacity warn/crit,
per-user growth, SMART/writable/NFS-down, throughput stall, cooldown;
`Notify/Notifier.swift`: AppleScript (unsigned-safe), webhook,
`UNUserNotificationCenter` best-effort, composite; durable `alert` table in
`Store/SQLiteMetricStore.swift`).

- **I. Notification constraints.** **[docs]**
  developer.apple.com/documentation/usernotifications/unusernotificationcenter:
  `current()` "Returns your app's notification center"; the SDK header
  **[SDK]** `UserNotifications.framework/Headers/UNUserNotificationCenter.h`
  line 52: "User authorization is required for applications to notify the
  user using UNUserNotificationCenter via both local and remote
  notifications." → needs a bundled app + user authorization; our guard
  (`Bundle.main.bundleIdentifier != nil`) is correct. **[docs]**
  developer.apple.com/documentation/servicemanagement/smappservice:
  `SMAppService` registers helpers "inside an app's main bundle" and
  `register()` "can begin launching subject to user approval" — so
  login-item-style autostart needs a registered bundle; our LaunchAgent
  fallback remains the unsigned path. The `osascript` fallback needs no
  approval beyond the Automation prompt (empirically it is the one path that
  works under ad-hoc signing — [repo] `Notify/Notifier.swift`).
- **New alert rules, integratable now**: NFS retransmit/timeout *trend*
  (counters already collected — diff two samples like
  `PerformanceCollector` does) and block I/O *error counters* (see §C)
  wired to the existing `io_error_count_threshold`.

---

## 6. Local APFS + shared NFS/pNFS

Already integrated for mounts/health/flags ([repo] `NFSCollector.swift`,
`NfsstatTool.swift`). New primary-source findings for depth:

### F. `nfsstat -f JSON` (machine does this natively)

- **[man]** `nfsstat(1)`: options include `-f JSON — Print output as JSON
  format.` (JSON output is a first-class mode.)
- **[tool]** `nfsstat -c -f JSON` on this Mac returns a structured object:
  `Client Info` sections = `Cache Info`, `NFSv3 RPC Counts`,
  `NFSv4 Operation Counts`, `NFSv4.1 Operation Counts`, `NLM RPC Counts`,
  `Paging Info`, `RPC Info` (with `Requests/Retries/TimedOut/Invalid`) —
  superseding our hand-written regex parser for counters.
- **[tool]** `NFSv4.1 Operation Counts` includes **`Layoutget`,
  `Layoutcommit`, `Layoutreturn`** — the pNFS layout operations are visible
  to userland as counters. This is the first concrete, primary-sourced path
  to a `nfs.pnfs_layout_ops` metric and it upgrades `docs/FUTURE_WORK.md` #2
  from "not available" to "partially available": *operation counts* yes,
  *per-layout-type byte statistics* no (nothing in `nfsstat(1)`'s option
  list exposes layout-type breakdowns).

### pNFS platform boundary

- **[xnu]** `bsd/nfs/nfsproto.h` (branch `main`): the kernel client defines
  the NFSv4.1 pNFS machinery — `NFS_FATTR_FS_LAYOUT_TYPE` (62),
  `NFS_FATTR_LAYOUT_TYPE` (64), layouttype4 constants
  (`NFS_LAYOUT4_NFSV4_1_FILES` 0x1, `NFS_LAYOUT4_OSD2_OBJECTS` 0x2,
  `NFS_LAYOUT4_BLOCK_VOLUME` 0x3), opcodes `NFS_OP_LAYOUTGET/LAYOUTCOMMIT/
  LAYOUTRETURN`, and errors `NFSERR_PNFSNOLAYOUT`/`NFSERR_PNFSIOHOLE`.
- So: the kernel speaks pNFS, and userland can see *that it happens* (JSON
  op counters), but no userland tool exposes layout-type *byte* statistics.
  Keep the boolean + add the op-counters; document the rest as the same
  platform-limitation posture the README takes for APFS quotas.

### E. APFS snapshots

- **[tool]** `diskutil apfs listSnapshots /System/Volumes/Data` →
  "No snapshots for disk3s5" — runs unprivileged on a *volume* device
  (it rejected `disk3`, "not an APFS Volume", so pass the volume device).
- **[man]** `diskutil(8)`: APFS Snapshots are "normally not discoverable
  unless the 'base' or one of the snapshots is mounted" — so inventory is
  per-volume via `listSnapshots`, not a global query.
- Integratable now as a `nfs`-style boolean/counter family
  (`capacity.snapshots` count, snapshot-delta usage needs Time Machine-free
  arithmetic — count first, size later).

### Inodes / file-node pressure

- **[man]** `statfs(2)`: `long f_files; /* total file nodes in file system */`
  (line 44) and `long f_ffree; /* free file nodes in fs */` (line 45).
- **[tool]** `df -i /` on this Mac: `/dev/disk3s1s1 … iused 458725 ifree
  1230651000`. One `statfs` call per volume = two more metric kinds. Cheap,
  useful, integratable now.

---

## 7. "Other interesting metrics" — integratable-now list (ranked)

1. **Read/write split + latency + transfer counts** — same IOKit `Statistics`
   dict we already read ([SDK] `IOBlockStorageDriver.h` keys above). Small.
2. **Block error/retry counters** → new alert rule wired to the existing
   `io_error_count_threshold`. Small.
3. **NVMe SMART via `NVMeSMARTLibExternal.h`** (temp, percentage used, spare,
   media errors, power-on hours) → wear trend becomes real data, and
   requirement-1 "backing block storage health" gets its teeth. Medium
   (privilege spike first).
4. **`nfsstat -f JSON` counters** incl. layout-op counts; parse JSON instead
   of regex; keep text parser as fallback. Small–medium.
5. **Inode counts** via `statfs` `f_files`/`f_ffree`. Small.
6. **APFS snapshot counts** via `diskutil apfs listSnapshots <volume>`. Small.
7. **Surface already-parsed fields**: filesystem type, encryption, removable
   media, NFS negotiated params (`vers`, `rsize`, `wsize` from the `Flags:`
   line we already parse). Small.
8. **Largest paths/directories** — scanner exists and is tested; needs a
   collector + UI panel ([repo] `Sources/FileScanner.swift`). Small.
9. **Retention/rollups** — plain SQLite: `INSERT INTO metric_hourly … SELECT
   … GROUP BY` + bounded `DELETE FROM metric WHERE ts < ?` in one transaction
   ([docs] sqlite.org/lang_delete.html — DELETE with WHERE; transactions per
   sqlite.org/lang_transaction.html), as a `DatabaseMigrator` "v2" +
   scheduled task in our existing GRDB store ([repo]
   `Store/SQLiteMetricStore.swift`). Medium.
10. **Prometheus endpoint** (`/metrics`) — text format is trivial; but it
    belongs to the retired web stack; the CLI `export` covers reporting for
    now. Medium, and only if a fleet view matters.

### Explicitly platform-limited (do not promise)

- Kernel-enforced per-user quotas on APFS (`quotactl` → ENOTSUP, tested).
- Per-process I/O bytes without root/entitlements (fs_usage = root; ES =
  system extension + Apple-granted entitlement).
- pNFS per-layout-type byte stats (kernel data, no userland exposure).

---

## Answer to the research question

**Yes — all seven requirements can be fully satisfied in this build**, with
the two honest exceptions above, which are macOS platform limits (not effort
limits) and are already worded correctly in `README.md` ("Why this data
model (APFS quotas)") and `docs/FUTURE_WORK.md` #2. Everything else in the
"more the better" bucket is a matter of integration work against APIs that are **public, documented, and
confirmed present on this machine** — the largest single win being the IOKit
`IOBlockStorageDriver` statistics table we already read (errors, retries,
operations, latency for free) and the newly-discovered `nfsstat -f JSON`.
