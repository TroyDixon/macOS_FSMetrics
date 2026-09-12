import Foundation

public enum Schema {
    public static let version: Int64 = 1
    // Verbatim SQL from INTERFACE_CONTRACT.md, section 1.
    public static let ddl = #"""
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
"""#

    static func apply(to connection: DatabaseConnection) throws {
        let current = try connection.query("PRAGMA user_version").first?["user_version"]?.integer ?? 0
        guard current <= version else {
            throw DatabaseError(message: "Database schema is newer than this collector")
        }
        guard current == 0 else { return }
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try connection.execute(ddl)
            try connection.execute("PRAGMA user_version = 1")
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }
}
