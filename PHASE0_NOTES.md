# Phase 0 review notes

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
- Samplers get epoch seconds in `ctx.ts`, and return `.ok`, `.degraded(detail)`,
  or throw. Use `statuses.snapshot()` when implementing health. Before first
  collection, status is degraded with a null lastRun and an explanatory detail.
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

`sudo make install` installs the release binary and plist and bootstraps a root
system daemon. `sudo make uninstall` boots it out and removes those two files,
retaining `/var/db/fsmond`. Installation is for a fresh service; boot out an
already installed service before reinstalling. `make clean` removes `.build`
and the local `data` directory. Installation/uninstallation are not part of
Phase 0's executed verification.

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
- `make test`: 12 XCTest tests passed, including schema reopen, value binding,
  transaction rollback, FK enforcement, read-only access, WAL read/write overlap,
  config precedence, router matching/404, framing rejection, and scheduler
  isolation, skipped ticks, status reporting, and stop behavior.
- Contract SQL and Schema.ddl source matched byte for byte.
- Live `make run`: sample count increased from 10 to 66, with one sample per
  second; WAL mode and all 16 contract tables plus debug_samples were present.
- Live curl: 404, application/json, contract not_found envelope, and CORS headers.
- Ctrl-C: drain/shutdown log completed, WAL absent or empty, integrity_check ok.
- LaunchDaemon plist passed `plutil -lint`; service installation was not run.
