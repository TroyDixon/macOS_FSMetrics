# Collector integration

Phase 1 is implemented: real capacity collection, hourly raw-sample retention,
and four GET routes under `/api/v1`: `/health`, `/mounts`, `/mounts/{id}`, and
`/mounts/{id}/capacity`. The collector still uses the unchanged contract schema
version 1, serial SQLite writer, separate reader, and independent sampler queues.

The dummy sampler is removed. Existing `debug_samples` tables from Phase 0 are
left untouched, but no longer receive readings; new databases do not create them.

## Capacity collection

`capacity` runs immediately and every 5 seconds. `getfsstat(MNT_NOWAIT)` enumerates
mounts using the cached mount table. All real filesystems are included, including
hidden system volumes, read-only volumes, disk images, NFS, SMB, and other types.
Only the pseudo-filesystems `devfs`, `autofs`, `fdesc`, `volfs`, and `procfs` are
excluded; neither `MNT_DONTBROWSE` nor a filesystem allowlist filters real mounts.

Local mounts get `statfs` to refresh cached capacity and a packed `getattrlist`
request for used space, volume UUID, and volume name. The decoder checks returned
attribute flags, lengths, and reference bounds. SPACEUSED precedes NAME and UUID
in the packed buffer despite its larger flag value. The byte fixture in
`CapacityTests` records the observed layout. Apple's description of
[ATTR_VOL_SPACEUSED](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlist.2)
also distinguishes per-volume use from total minus free on space-sharing volumes.

Remote mounts use only cached numbers; neither `statfs`, `getattrlist`, nor
Foundation volume-resource lookups are called on them. A missing `MNT_LOCAL` flag
or a known network type (`nfs`, `smbfs`, `webdav`) selects this path. Their capacity
can be stale; the capacity sampler reports degraded with a diagnostic stating this.
It does not claim to detect whether the remote server is responding.

A failed local refresh skips that mount's new capacity row, preserving its prior
reading and timestamp. Unsupported volume attributes fall back to total minus
free on non-APFS filesystems. APFS never uses container usage as a substitute:
if per-volume used space is unavailable, its sample is skipped and health is
degraded. Other mounts still collect. An enumeration failure throws and retains
the previous inventory snapshot, which expires after 15 seconds.

Mount identity is `(mount_point, volume_uuid)` with a NULL-safe lookup; UUID-less
mounts therefore do not duplicate on every collection. A temporary attribute
failure preserves a previously known UUID for the same path/device/type.
Successful enumerations publish active IDs atomically after database writes.
Detached mounts vanish from inventory at the next successful enumeration;
dimension rows and time-series history remain. Mounted snapshot UUIDs are kept
as reported by getattrlist. A snapshot such as `/dev/disk3s1s1` can have a different
UUID from its base volume `/dev/disk3s1` on this Mac.

APFS volume-to-container mapping comes from IOKit and is grouped by actual
container UUID. For mounted snapshots, the synthesized BSD container name resolves
the mapping when the mounted UUID is absent from IOKit's volume list. BSD names
are used only for this current topology lookup, not stored as stable identity.
Minimal `containers` identity rows are created so `mounts.container_id` and
`shares_container_with` work. Device mapping, container-capacity sampling, and
the `/containers` endpoint remain later work; those unknown fields stay NULL.

## Six proposals for C to reconcile with the contract

These describe the implementation requested for Phase 1. They are proposals for
the shared API contract, not edits to `INTERFACE_CONTRACT.md`, which C owns.

1. **Per-volume used space and percentage.** `used_bytes` is ATTR_VOL_SPACEUSED
   where available, matching the used column in `df`. `used_pct` is
   `100 * used_bytes / (used_bytes + available_bytes)`, before df's display rounding.
   A zero denominator gives null. On APFS, `total_bytes`/free/available can describe
   shared container capacity, so used plus available need not equal total, and
   consumers must not sum shared free space across mounts.
2. **Inventory and freshness.** `/mounts` lists only the active IDs from the latest
   successful enumeration, with a 15-second expiry. Empty startup inventory is an
   empty collection, not old rows loaded from disk. Unknown mount metadata and
   a missing capacity reading are explicit nulls. `shares_container_with` contains
   the other active mount IDs in the same APFS container and is otherwise `[]`.
3. **Mount detail shape.** `/mounts/{id}` returns exactly one inventory object under
   `data`, plus `meta.generated_at`. An inactive/unknown ID returns `not_found` 404;
   malformed IDs return `bad_request` 400. The accepted ID form is `mount:<positive
   integer>`. It contains the same fields and capacity object as `/mounts`.
4. **Capacity series shape.** `/mounts/{id}/capacity` returns `series_id`, `step`,
   `from`, `to`, `timestamps`, and seven equal-length arrays: `total_bytes`,
   `free_bytes`, `available_bytes`, `used_bytes`, `inodes_total`, `inodes_free`,
   `used_pct`. Each nonempty bucket is an arithmetic mean; missing buckets and
   unavailable inode values are null. Known detached mounts still support history.
5. **Range rules and limits.** Samples are selected in `[from, to)`. `to` defaults
   to now and `from` to one hour before `to`; `step` defaults to 60 seconds. Epoch
   buckets start at `floor(ts / step) * step`; the first bucket can start before
   `from`, but only samples inside the requested range contribute. Require
   nonnegative integer epochs, `from < to`, integer step 1–86400, and at most
   10,000 buckets. Invalid or excessive requests return 400. Bucket percentages
   average sample percentages rather than recomputing a ratio of averages.
6. **Health detail rule.** The exact example envelope is retained: only `data`,
   containing `status`, `uptime_seconds`, `version`, `samplers`. Each sampler has
   `name`, `last_run`, `interval`, `status`; `detail` appears only when diagnostic
   text exists, as in the contract example. This clarifies the example's exception
   to the general never-omit-missing-data rule. Before first completion, last_run
   is null. Aggregate status prioritizes error, then degraded, then ok. Both
   `capacity` and `retention`, plus B's registered samplers, appear in health.

Inventory objects include `id`, `mount_point`, `device_node`, `fs_type`,
`volume_uuid`, `volume_name`, `container_id`, `device_id`, `is_remote`, `read_only`,
`capacity`, and `shares_container_with`. Capacity has `ts` and the same seven
numeric fields listed above. Per-mount NFS health enrichment remains B's later
integration work; Phase 1 does not invent NFS health measurements.

Example detail (illustrative numbers):

```json
{
  "data": {
    "id": "mount:1", "mount_point": "/Volumes/Test", "device_node": "/dev/disk10s1",
    "fs_type": "apfs", "volume_uuid": "example-volume-uuid", "volume_name": "Test",
    "container_id": "container:1", "device_id": null, "is_remote": false, "read_only": false,
    "capacity": {
      "ts": 1773360000, "total_bytes": 1000000000, "free_bytes": 600000000,
      "available_bytes": 600000000, "used_bytes": 150000000,
      "inodes_total": null, "inodes_free": null, "used_pct": 20.0
    },
    "shares_container_with": ["mount:2"]
  },
  "meta": {"generated_at": 1773360001}
}
```

Example series with an empty second bucket:

```json
{
  "data": {
    "series_id": "mount:1", "step": 60, "from": 1773360000, "to": 1773360120,
    "timestamps": [1773360000, 1773360060],
    "total_bytes": [1000000000.0, null], "free_bytes": [600000000.0, null],
    "available_bytes": [600000000.0, null], "used_bytes": [150000000.0, null],
    "inodes_total": [null, null], "inodes_free": [null, null], "used_pct": [20.0, null]
  },
  "meta": {"generated_at": 1773360120}
}
```

## Shared retention: handoff to B

A owns the `retention` sampler. It runs immediately at startup and hourly,
deleting rows strictly older than 24 hours from `capacity_samples`,
`container_capacity_samples`, `io_samples`, `user_io_samples`,
`process_io_samples`, `nfs_samples`, and `device_health_samples` in one transaction.
Rows exactly at the cutoff remain. This covers B's sample tables too: B should
not register another cleanup job and should not expect older raw samples to exist.
The hourly cadence means rows can be up to about 25 hours old between cleanups.

Dimensions, snapshots, scan results, alerts, and rollups are not raw samples and
are preserved. Thirty-day rollup retention accompanies later rollup work. Vacuum
is deferred because the contract's current auto_vacuum setting makes incremental
vacuum a no-op. No schema change was needed for Phase 1.

## Integration hooks

B owns `Sources/fsmond/Registration/TeamRegistration.swift`. Add samplers/routes there
and implementation files under `Sources/FSMonCore`; SwiftPM discovers new files
without edits to the package manifest, main, or core registration.

- `registerTeamSamplers(_:)`: `registry.register(YourSampler())`.
- `registerTeamRoutes(_:db:statuses:log:)`: GET/POST handlers receive `Request`
  with `parameters`, `query`, lowercase `headers`, and raw `body`.
- Use `try db.write { connection in ... }` for an atomic transaction. Throwing
  rolls it back. Use `try db.read { connection in ... }` for HTTP reads.
- Connection `execute(_:bindings:)` and `query(_:bindings:)` use `SQLValue`
  (`integer`, `real`, `text`, `blob`, `null`). Bind all external values.
- Do not retain a connection beyond its closure, nest database calls inside those
  closures, or open a transaction inside `db.write`.
- Samplers get an aligned epoch-second storage key in `ctx.ts` and raw monotonic
  time in `ctx.monotonicNanos`. Use monotonic deltas for rates and latency; wall
  time can jump. Return `.ok`, `.degraded(detail)`, or throw. Use
  `statuses.snapshot()` when implementing health. Each sampler runs immediately
  at startup, then at interval boundaries plus 50 ms. `ctx.ts` is read from the
  wall clock on every tick, so it tracks real time after system sleep; it never
  repeats or goes backwards (ticks are skipped if the clock steps back).
- Routes use `try Response.json(.object(...))`; missing values must be `.null`.
  Use `Response.error` for expected API errors; thrown handler errors become
  a generic `internal` 500 response, with the actual error logged.
- Registration happens at startup. Routes may execute concurrently. Each sampler
  has its own serial queue; a busy sampler skips ticks without accumulating work.
- `Scheduler.stop()` drains in-flight collection; `HTTPServer.stop()` drains
  handlers. Call both before `Database.close()`, which checkpoints/truncates WAL.
  Stop/close must be called outside those workers and database closures.

The transport accepts GET, POST, and OPTIONS, Content-Length bodies up to 64 KiB,
headers up to 16 KiB, up to 128 connected clients, and a 10-second connection
lifetime. It closes after one response. Transfer-Encoding and Expect are rejected.
CORS allows all origins and GET/POST/OPTIONS with Content-Type. Long scans should
return a job ID promptly and run work outside the request handler.

## Configuration and local verification

`make build` builds release; `make test` runs XCTest; `make run` starts the daemon
at 127.0.0.1:8080 using `./data/fsmon.db`. Ctrl-C or SIGTERM drains and closes it.
`fsmond --help` lists options. Optional `--config path` files accept one unquoted
`key = value` per line and full-line `#` comments. Supported keys are `db`, `port`,
`bind` (IPv4/IPv6 literal), and `log-level`. CLI flags override file values,
regardless of argument order. Relative database paths resolve from the working
directory. Unknown keys/options and invalid values are errors.

While `make run` is active, use:

```sh
sqlite3 data/fsmon.db 'PRAGMA journal_mode; SELECT count(*), max(ts) FROM capacity_samples;' '.tables'
curl -i http://127.0.0.1:8080/api/v1/health
curl -s http://127.0.0.1:8080/api/v1/mounts
curl -i http://127.0.0.1:8080/api/v1/nope
```

The sqlite shell `.tables` command is a separate argument, not SQL inside the
preceding statement. Expect WAL, a growing count, all 16 contract tables, real
mount readings, and a JSON 404 with CORS headers for `/nope`. After shutdown, the WAL is
removed or zero-length and the database passes `PRAGMA integrity_check`.

With the daemon running on localhost:8080, `python3 scripts/verify_capacity.py`
compares local readings with df/diskutil, creates and attaches its own 256 MiB
APFS image, writes 100 MB, verifies the reading rises within 5 seconds, and checks
that it disappears after detach. It also exercises detail/history and null gaps.
It removes only its own temporary files after detaching. If detach fails, it
preserves the temporary directory instead of traversing a mounted filesystem.

Run `make build` as your normal user before `sudo make install`. Installation
checks for that release binary, boots out an existing service when present,
installs the binary and plist, and bootstraps a root system daemon. This keeps
root-owned files out of `.build` and permits reinstalling. `sudo make uninstall`
boots it out and removes those two files, retaining `/var/db/fsmond`. `make clean`
removes `.build` and the local `data` directory. Installation/uninstallation are
not part of Phase 0's executed verification.

For a frontend on another machine, pass `--bind 0.0.0.0` and allow the port
through the host firewall. This exposes every route to the reachable network.
The API has no authentication, including planned write routes such as
`POST /api/v1/scans`, so use that binding only on a trusted hackathon network.

## Contract questions for C before later phases

These are review items, not changes to INTERFACE_CONTRACT.md:

1. Device uniqueness on `(bsd_name, serial)` does not enforce identity on
   `(serial, model)` and permits repeated NULL serials. Plan a code-side identity
   lookup; discuss an index consistent with the identity rule.
2. Mount uniqueness on `(mount_point, volume_uuid)` permits repeated NULL UUIDs.
   Code-side lookup is needed for those filesystems.
3. Incremental vacuum requires `auto_vacuum = INCREMENTAL` before creating tables.
   Current DDL leaves it disabled. Approve this before migration/retention work;
   existing Phase 0 databases would need recreation or an explicit migration.
4. Foreign keys and busy timeout must be enabled on every connection. Both
   connections in this wrapper do so; any independently opened connection must too.
5. Reconcile the chosen per-volume `used_bytes` behavior with the shared contract
   as proposed above; APFS used plus available does not generally equal total.
6. Approve the Phase 1 detail/series shapes above; define overview, containers, and devices response shapes;
   clarify ownership of `/devices`, which is missing from the ownership table.
7. Deployment is a root LaunchDaemon for cross-user process I/O. As noted in the
   supplied plan, root does not bypass TCC; protected tree scans need Full Disk
   Access. Coordinate with B/C and the demo setup.

The contract's draft signoff status is preserved. This implementation follows the
explicitly requested scope and does not imply team approval of contract changes.

## Phase 0 verification on 2026-09-12

- `make build`: release build passed with Swift 6.3.3.
- `make test`: 16 XCTest tests passed, including schema reopen and ordered upgrade,
  migration rollback, value binding, transaction rollback, FK enforcement,
  read-only access, WAL read/write overlap, config precedence, exact JSON number
  encoding, router matching/404, framing rejection, and immediate/aligned scheduler
  timing, isolation, skipped ticks, status reporting, and stop behavior.
- Contract SQL and Schema.ddl source matched byte for byte.
- Live `make run`: the first sample was written during startup, the latest eight
  timestamps were consecutive seconds, and no duplicate timestamp existed;
  WAL mode and all 16 contract tables plus debug_samples were present.
- Live curl: 404, application/json, contract not_found envelope, and CORS headers.
- Ctrl-C: drain/shutdown log completed, WAL absent or empty, integrity_check ok.
- LaunchDaemon plist passed `plutil -lint`; service installation was not run.

## Phase 1 verification on 2026-09-12

- `make test`: all 28 tests passed. New coverage includes the packed attribute
  buffer, fresh local versus cached remote reads, NULL UUID identity, multiple
  mount paths, APFS snapshot container resolution, per-volume used semantics,
  detach/history, health shape, range validation, averaging/null gaps, and the
  retention cutoff across all seven raw tables.
- `make build`: release build passed. The contract and its schema DDL were not
  edited; version remains 1.
- Live collector: 14 real mounts on this Mac, healthy capacity and retention
  statuses. Root used bytes matched df exactly at 17,088,528,384. Data used bytes
  differed from df by about 2.3 MB while that live volume was changing; UUID
  matched diskutil, and diskutil CapacityInUse was consistent with that reading.
- Temporary APFS image: appeared after 0.33 s; used space rose from 20,480 to
  100,028,416 bytes within the script's strict 5-second assertion after a
  100,000,000-byte write. df reported exactly 100,028,416 used bytes. Mount detail,
  column-series shape, null gaps, and UUID comparison passed.
- Detached image disappeared after 4.67 s; its detail returned 404 and its
  retained capacity history remained readable. Image and payload were removed
  after detach. The reusable live test is `scripts/verify_capacity.py`.
- Ctrl-C completed shutdown and WAL checkpoint; SQLite integrity_check was ok
  and foreign_key_check reported no violations. LaunchDaemon installation was
  not performed. Remote no-path-call behavior was tested with injected NFS/SMB
  mounts; no live remote server was mounted for this verification.
