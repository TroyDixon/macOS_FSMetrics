# Interface Contract — macOS File System Metrics

**Status:** Draft for team review. Nothing is built until all three sign off.

This document defines the boundary between the Swift collector daemon and the web
frontend. Person A and Person B build *to* this. Person C builds *against* this.
If the two halves are written against the same contract, integration is a
configuration change instead of a rewrite.

---

## 0. Conventions

These apply everywhere. Disagreements here cause the most painful bugs, so settle
them first.

| Concern | Decision |
|---|---|
| Timestamps | INTEGER, Unix epoch **seconds**, UTC. Never strings, never local time. |
| Sizes | Bytes. Always. Never KB/MB/GB in the API — the frontend formats. |
| Rates | Bytes per second, as REAL. Computed by the collector, not the frontend. |
| Latency | Milliseconds, as REAL. (IOKit reports nanoseconds — collector converts.) |
| Percentages | 0.0–100.0 as REAL, not 0.0–1.0. |
| IDs | Opaque strings in the API. Integer primary keys in SQLite. |
| Missing data | JSON `null`. Never `0`, never `-1`, never omitted. |
| Time ranges | `?from=<epoch>&to=<epoch>`. Both optional. Default: last 1 hour. |
| Downsampling | `?step=<seconds>`. Server-side bucket averaging. Default 60. |

**Why rates are computed collector-side:** IOKit gives cumulative counters that
reset on reboot and on device re-enumeration. Only the collector can see two
consecutive samples and detect a reset. If the frontend differences the counters
it will draw a huge negative spike every reboot.

---

## 1. SQLite Schema

Single file, WAL mode. Dimension tables hold stable identity; `*_samples` tables
hold time series.

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------
-- Dimension tables: stable identity for things we sample
-- ---------------------------------------------------------------

-- Physical / logical block devices.
-- NOTE: BSD names (disk4) are NOT stable across replug. Match on
-- (serial, model) when present, fall back to bsd_name.
CREATE TABLE devices (
    id            INTEGER PRIMARY KEY,
    bsd_name      TEXT NOT NULL,            -- 'disk0'
    model         TEXT,                     -- 'APPLE SSD AP1024Z'
    serial        TEXT,
    protocol      TEXT,                     -- 'PCI-Express', 'USB', 'Thunderbolt'
    is_internal   INTEGER NOT NULL DEFAULT 0,
    is_removable  INTEGER NOT NULL DEFAULT 0,
    size_bytes    INTEGER,
    first_seen    INTEGER NOT NULL,
    last_seen     INTEGER NOT NULL,
    UNIQUE (bsd_name, serial)
);

-- APFS containers. Volumes inside a container SHARE free space,
-- so per-volume "free" is meaningless alone. This table is why.
CREATE TABLE containers (
    id              INTEGER PRIMARY KEY,
    container_uuid  TEXT NOT NULL UNIQUE,
    bsd_name        TEXT,                   -- 'disk3'
    device_id       INTEGER REFERENCES devices(id),
    size_bytes      INTEGER,
    first_seen      INTEGER NOT NULL,
    last_seen       INTEGER NOT NULL
);

-- Mounted filesystems.
CREATE TABLE mounts (
    id            INTEGER PRIMARY KEY,
    mount_point   TEXT NOT NULL,            -- '/System/Volumes/Data'
    device_node   TEXT,                     -- '/dev/disk3s5' or 'nas:/export/case'
    fs_type       TEXT NOT NULL,            -- 'apfs' | 'nfs' | 'smbfs' | 'hfs'
    volume_uuid   TEXT,
    volume_name   TEXT,
    container_id  INTEGER REFERENCES containers(id),
    device_id     INTEGER REFERENCES devices(id),
    is_remote     INTEGER NOT NULL DEFAULT 0,
    read_only     INTEGER NOT NULL DEFAULT 0,
    first_seen    INTEGER NOT NULL,
    last_seen     INTEGER NOT NULL,         -- stale last_seen => unmounted
    UNIQUE (mount_point, volume_uuid)
);

CREATE TABLE users (
    uid           INTEGER PRIMARY KEY,
    username      TEXT,
    full_name     TEXT,
    quota_bytes   INTEGER,                  -- NULL = no soft quota configured
    first_seen    INTEGER NOT NULL,
    last_seen     INTEGER NOT NULL
);

-- ---------------------------------------------------------------
-- Time series
-- ---------------------------------------------------------------

CREATE TABLE capacity_samples (
    ts              INTEGER NOT NULL,
    mount_id        INTEGER NOT NULL REFERENCES mounts(id),
    total_bytes     INTEGER NOT NULL,
    free_bytes      INTEGER NOT NULL,
    available_bytes INTEGER NOT NULL,       -- free minus root reserve; use THIS for %
    used_bytes      INTEGER NOT NULL,
    inodes_total    INTEGER,
    inodes_free     INTEGER,
    PRIMARY KEY (ts, mount_id)
) WITHOUT ROWID;

-- Container-level free space. The honest number for APFS.
CREATE TABLE container_capacity_samples (
    ts              INTEGER NOT NULL,
    container_id    INTEGER NOT NULL REFERENCES containers(id),
    total_bytes     INTEGER NOT NULL,
    free_bytes      INTEGER NOT NULL,
    snapshot_bytes  INTEGER,                -- space held by snapshots: looks free, isn't
    PRIMARY KEY (ts, container_id)
) WITHOUT ROWID;

-- Block device throughput + latency. Source: IOBlockStorageDriver Statistics.
-- Collector stores BOTH raw counters and computed rates.
CREATE TABLE io_samples (
    ts                  INTEGER NOT NULL,
    device_id           INTEGER NOT NULL REFERENCES devices(id),
    read_bytes_total    INTEGER NOT NULL,   -- cumulative counter
    write_bytes_total   INTEGER NOT NULL,
    read_ops_total      INTEGER NOT NULL,
    write_ops_total     INTEGER NOT NULL,
    read_bytes_per_sec  REAL,               -- NULL on first sample / after reset
    write_bytes_per_sec REAL,
    read_ops_per_sec    REAL,
    write_ops_per_sec   REAL,
    read_latency_ms     REAL,               -- avg over interval
    write_latency_ms    REAL,
    counter_reset       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (ts, device_id)
) WITHOUT ROWID;

-- Per-user I/O, aggregated from proc_pid_rusage across that user's processes.
CREATE TABLE user_io_samples (
    ts                  INTEGER NOT NULL,
    uid                 INTEGER NOT NULL REFERENCES users(uid),
    read_bytes_per_sec  REAL NOT NULL,
    write_bytes_per_sec REAL NOT NULL,
    process_count       INTEGER NOT NULL,
    PRIMARY KEY (ts, uid)
) WITHOUT ROWID;

-- Top-N processes only. Do NOT store every PID every interval.
CREATE TABLE process_io_samples (
    ts                  INTEGER NOT NULL,
    pid                 INTEGER NOT NULL,
    uid                 INTEGER NOT NULL,
    name                TEXT,
    read_bytes_per_sec  REAL NOT NULL,
    write_bytes_per_sec REAL NOT NULL,
    PRIMARY KEY (ts, pid)
) WITHOUT ROWID;

CREATE TABLE nfs_samples (
    ts               INTEGER NOT NULL,
    mount_id         INTEGER NOT NULL REFERENCES mounts(id),
    rpc_requests     INTEGER,
    rpc_retrans      INTEGER,
    rpc_timeouts     INTEGER,
    retrans_rate_pct REAL,                  -- the actual health signal
    avg_rtt_ms       REAL,
    is_responding    INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (ts, mount_id)
) WITHOUT ROWID;

CREATE TABLE device_health_samples (
    ts                     INTEGER NOT NULL,
    device_id              INTEGER NOT NULL REFERENCES devices(id),
    smart_status           TEXT,            -- 'ok' | 'failing' | 'unsupported' | 'unknown'
    percentage_used        INTEGER,         -- NVMe wear indicator, 0-100+
    temperature_c          REAL,
    power_on_hours         INTEGER,
    unsafe_shutdowns       INTEGER,
    media_errors           INTEGER,
    data_units_written     INTEGER,
    source                 TEXT,            -- 'nvme-ioreg' | 'smartctl' | 'none'
    PRIMARY KEY (ts, device_id)
) WITHOUT ROWID;

CREATE TABLE snapshots (
    id            INTEGER PRIMARY KEY,
    mount_id      INTEGER NOT NULL REFERENCES mounts(id),
    name          TEXT NOT NULL,
    created_at    INTEGER,
    size_bytes    INTEGER,                  -- often unavailable; NULL is fine
    discovered_at INTEGER NOT NULL,
    UNIQUE (mount_id, name)
);

-- ---------------------------------------------------------------
-- Tree scans (on-demand, expensive)
-- ---------------------------------------------------------------

CREATE TABLE tree_scans (
    id                INTEGER PRIMARY KEY,
    mount_id          INTEGER REFERENCES mounts(id),
    root_path         TEXT NOT NULL,
    started_at        INTEGER NOT NULL,
    finished_at       INTEGER,
    status            TEXT NOT NULL,        -- 'running' | 'complete' | 'failed'
    file_count        INTEGER,
    dir_count         INTEGER,
    logical_bytes     INTEGER,              -- sum of file sizes
    allocated_bytes   INTEGER,              -- sum of st_blocks*512; clones make this smaller
    error             TEXT
);

CREATE TABLE tree_scan_entries (
    scan_id           INTEGER NOT NULL REFERENCES tree_scans(id),
    path              TEXT NOT NULL,
    is_dir            INTEGER NOT NULL,
    uid               INTEGER,
    logical_bytes     INTEGER NOT NULL,
    allocated_bytes   INTEGER NOT NULL,
    mtime             INTEGER,
    PRIMARY KEY (scan_id, path)
) WITHOUT ROWID;

-- ---------------------------------------------------------------
-- Alerting
-- ---------------------------------------------------------------

CREATE TABLE alert_events (
    id             INTEGER PRIMARY KEY,
    rule_id        TEXT NOT NULL,           -- from rules config file
    severity       TEXT NOT NULL,           -- 'info' | 'warning' | 'critical'
    subject_type   TEXT NOT NULL,           -- 'mount' | 'device' | 'user' | 'container'
    subject_id     TEXT NOT NULL,
    subject_label  TEXT,                    -- '/Volumes/CaseFiles', 'jdoe'
    message        TEXT NOT NULL,
    value          REAL,                    -- what tripped it
    threshold      REAL,
    opened_at      INTEGER NOT NULL,
    resolved_at    INTEGER,                 -- NULL = still active
    acked_at       INTEGER
);

CREATE INDEX idx_alert_active ON alert_events(resolved_at, opened_at DESC);

-- ---------------------------------------------------------------
-- Rollups — written by a periodic job, read by long time-range queries
-- ---------------------------------------------------------------

CREATE TABLE io_rollup_5m (
    bucket_ts            INTEGER NOT NULL,
    device_id            INTEGER NOT NULL REFERENCES devices(id),
    avg_read_bps         REAL,
    avg_write_bps        REAL,
    peak_read_bps        REAL,
    peak_write_bps       REAL,
    avg_read_latency_ms  REAL,
    avg_write_latency_ms REAL,
    sample_count         INTEGER NOT NULL,
    PRIMARY KEY (bucket_ts, device_id)
) WITHOUT ROWID;

CREATE INDEX idx_io_ts      ON io_samples(ts);
CREATE INDEX idx_cap_ts     ON capacity_samples(ts);
CREATE INDEX idx_user_io_ts ON user_io_samples(ts);
```

**Retention:** raw samples 24h, 5m rollups 30d. A nightly `DELETE` plus
`PRAGMA incremental_vacuum` is sufficient.

---

## 2. HTTP API

Base path `/api/v1`. All responses `application/json`.

### Response envelope

Collections:

```json
{
  "data": [ ... ],
  "meta": { "count": 4, "generated_at": 1773360000 }
}
```

Time series — column-oriented, because it is roughly 3x smaller over the wire
and charting libraries want arrays anyway:

```json
{
  "data": {
    "series_id": "device:1",
    "step": 60,
    "from": 1773356400,
    "to": 1773360000,
    "timestamps":   [1773356400, 1773356460],
    "read_bytes_per_sec":  [1048576.0, 2097152.0],
    "write_bytes_per_sec": [524288.0, null]
  },
  "meta": { "generated_at": 1773360000 }
}
```

`null` inside a series means no data for that bucket. Frontend must render gaps,
not zeros — a gap and an idle disk look very different to a sysadmin.

Errors:

```json
{ "error": { "code": "not_found", "message": "No mount with id 'mount:99'" } }
```

Codes: `not_found`, `bad_request`, `collector_unavailable`, `internal`.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/health` | Daemon liveness + per-sampler status |
| GET | `/api/v1/overview` | Everything the landing page needs, one call |
| GET | `/api/v1/mounts` | Mount inventory + latest capacity |
| GET | `/api/v1/mounts/{id}` | Single mount detail |
| GET | `/api/v1/mounts/{id}/capacity` | Capacity time series |
| GET | `/api/v1/containers` | APFS containers + shared free space |
| GET | `/api/v1/devices` | Block devices + latest health |
| GET | `/api/v1/devices/{id}/io` | Throughput + latency time series |
| GET | `/api/v1/users` | Per-user I/O + quota status |
| GET | `/api/v1/users/{uid}/io` | Per-user time series |
| GET | `/api/v1/processes/top` | Top N processes by I/O right now |
| GET | `/api/v1/nfs` | NFS mount health |
| GET | `/api/v1/snapshots` | Snapshot inventory |
| GET | `/api/v1/alerts` | `?state=active\|all&severity=` |
| POST | `/api/v1/alerts/{id}/ack` | Acknowledge |
| GET | `/api/v1/scans` | Tree scan list |
| POST | `/api/v1/scans` | Start scan, body `{"root_path": "..."}` |
| GET | `/api/v1/scans/{id}` | Status + totals |
| GET | `/api/v1/scans/{id}/top` | `?limit=50&by=allocated` |
| GET | `/metrics` | Prometheus text format |

### Key response shapes

`GET /api/v1/health`

```json
{
  "data": {
    "status": "ok",
    "uptime_seconds": 3821,
    "version": "0.1.0",
    "samplers": [
      { "name": "block_io",  "last_run": 1773360000, "interval": 1,   "status": "ok" },
      { "name": "capacity",  "last_run": 1773359995, "interval": 5,   "status": "ok" },
      { "name": "user_io",   "last_run": 1773359998, "interval": 5,   "status": "ok" },
      { "name": "nfs",       "last_run": 1773359970, "interval": 30,  "status": "ok" },
      { "name": "smart",     "last_run": 1773359700, "interval": 300, "status": "degraded",
        "detail": "smartctl not installed; internal NVMe via ioreg only" }
    ]
  }
}
```

`GET /api/v1/mounts`

```json
{
  "data": [
    {
      "id": "mount:1",
      "mount_point": "/System/Volumes/Data",
      "device_node": "/dev/disk3s5",
      "fs_type": "apfs",
      "volume_name": "Macintosh HD - Data",
      "container_id": "container:1",
      "device_id": "device:1",
      "is_remote": false,
      "read_only": false,
      "capacity": {
        "ts": 1773360000,
        "total_bytes": 994662584320,
        "used_bytes": 812000000000,
        "available_bytes": 182662584320,
        "used_pct": 81.6
      },
      "shares_container_with": ["mount:2", "mount:3"]
    },
    {
      "id": "mount:4",
      "mount_point": "/Volumes/CaseFiles",
      "device_node": "nas01:/export/casefiles",
      "fs_type": "nfs",
      "is_remote": true,
      "capacity": { "ts": 1773360000, "total_bytes": 8796093022208,
                    "used_bytes": 7476883570000, "available_bytes": 1319209452208,
                    "used_pct": 85.0 },
      "nfs": { "retrans_rate_pct": 0.4, "avg_rtt_ms": 1.8, "is_responding": true }
    }
  ],
  "meta": { "count": 2, "generated_at": 1773360000 }
}
```

`GET /api/v1/users`

```json
{
  "data": [
    {
      "uid": 501,
      "username": "jdoe",
      "full_name": "Jane Doe",
      "read_bytes_per_sec": 12582912.0,
      "write_bytes_per_sec": 219902325.0,
      "process_count": 47,
      "quota_bytes": 1099511627776,
      "usage_bytes": 934000000000,
      "quota_used_pct": 85.0,
      "write_baseline_bps": 4194304.0,
      "write_anomaly_ratio": 52.4
    }
  ],
  "meta": { "count": 1, "generated_at": 1773360000 }
}
```

`write_anomaly_ratio` is current rate over rolling baseline. It is the number the
"nefarious user" panel sorts on.

`GET /api/v1/alerts?state=active`

```json
{
  "data": [
    {
      "id": "alert:17",
      "rule_id": "capacity_critical",
      "severity": "critical",
      "subject_type": "mount",
      "subject_id": "mount:4",
      "subject_label": "/Volumes/CaseFiles",
      "message": "Volume 85% full, projected full in 6 days",
      "value": 85.0,
      "threshold": 85.0,
      "opened_at": 1773359400,
      "resolved_at": null,
      "acked_at": null
    }
  ],
  "meta": { "count": 1, "generated_at": 1773360000 }
}
```

---

## 3. Quota semantics — read this before building the quota panel

macOS/APFS has **no kernel-enforced per-user quotas**. The legacy `quota`
tooling is HFS+ era and does not apply. Our quotas are **soft**: we account
usage and raise alerts. We do not block writes.

The API reflects this honestly. `quota_bytes` is a value from our own config
file, not from the filesystem. The UI must label this panel "Soft Quotas
(advisory)". Kernel-enforced quotas via FSKit go in Future Work.

Saying this plainly is worth more with these judges than pretending otherwise.

---

## 4. Who owns what

| Area | Owner |
|---|---|
| Schema DDL, migrations | A |
| `/health`, `/overview`, `/mounts`, `/containers`, `/devices/{id}/io` | A |
| `/users`, `/processes/top`, `/nfs`, `/snapshots`, `/alerts` | B |
| Rules engine + alert event writing | B |
| Seed script, mock API server, all frontend | C |
| `/metrics` Prometheus exporter | C |
| README, build docs, future work, demo script | C |

**C owns the seed script and therefore owns this document.** Changes go through
C so the mock server and the Swift implementation never drift.

---

## 5. Change protocol

During the event, an API change is a 30-second conversation, not a PR review.
But it must be *announced* — say it out loud, update this file, update the mock
server. A silent field rename at 3am is how integration dies.
