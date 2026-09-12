# Collector integration

Implemented: Swift package, contract schema version 1, SQLite writer/read connection,
independent sampler scheduling and status storage, dummy sampler, HTTP transport and
router, config, signal shutdown, Make targets, and a root LaunchDaemon plist.

Phase 0 intentionally registers no API routes. `/api/v1/nope` and `/api/v1/health`
return the contract `not_found` envelope until real endpoints are added in Phase 1.
`debug_samples` is created by DummySampler, not by the contract schema.

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
  at startup, then at interval boundaries plus 50 ms.
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
sqlite3 data/fsmon.db 'PRAGMA journal_mode; SELECT count(*), max(ts) FROM debug_samples;' '.tables'
curl -i http://127.0.0.1:8080/api/v1/nope
```

The sqlite shell `.tables` command is a separate argument, not SQL inside the
preceding statement. Expect WAL, a growing count, all 16 contract tables plus
`debug_samples`, and a JSON 404 with CORS headers. After shutdown, the WAL is
removed or zero-length and the database passes `PRAGMA integrity_check`.

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
5. Define APFS `used_bytes` before capacity implementation: the plan's machine
   probes report container-wide statfs blocks/free, while the API example assumes
   used plus available equals total.
6. Define overview, mount detail/capacity, containers, and devices response shapes;
   clarify ownership of `/devices`, which is missing from the ownership table.
7. Deployment is a root LaunchDaemon for cross-user process I/O. As noted in the
   supplied plan, root does not bypass TCC; protected tree scans need Full Disk
   Access. Coordinate with B/C and the demo setup.

The contract's draft signoff status is preserved. This implementation follows the
explicitly requested Phase 0 scope and does not imply team approval of changes.

## Verified on 2026-09-12

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
