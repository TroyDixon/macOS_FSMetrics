import XCTest
@testable import FSMonCore

final class RetentionTests: XCTestCase {
    func testRawRetentionCoversEveryTableAndKeepsBoundaryAndDimensions() throws {
        let f = try CapacityFixture()
        try f.db.write { c in
            try c.execute("INSERT INTO devices (id, bsd_name, first_seen, last_seen) VALUES (1, 'disk1', 0, 0)")
            try c.execute("INSERT INTO containers (id, container_uuid, first_seen, last_seen) VALUES (1, 'container', 0, 0)")
            try c.execute("INSERT INTO mounts (id, mount_point, fs_type, first_seen, last_seen) VALUES (1, '/test', 'apfs', 0, 0)")
            try c.execute("INSERT INTO users (uid, first_seen, last_seen) VALUES (501, 0, 0)")
            for ts in [99, 100, 101] {
                try c.execute("INSERT INTO capacity_samples VALUES (\(ts), 1, 1000, 500, 500, 100, NULL, NULL)")
                try c.execute("INSERT INTO container_capacity_samples (ts, container_id, total_bytes, free_bytes) VALUES (\(ts), 1, 1000, 500)")
                try c.execute("INSERT INTO io_samples (ts, device_id, read_bytes_total, write_bytes_total, read_ops_total, write_ops_total) VALUES (\(ts), 1, 0, 0, 0, 0)")
                try c.execute("INSERT INTO user_io_samples VALUES (\(ts), 501, 0, 0, 1)")
                try c.execute("INSERT INTO process_io_samples (ts, pid, uid, read_bytes_per_sec, write_bytes_per_sec) VALUES (\(ts), 1, 501, 0, 0)")
                try c.execute("INSERT INTO nfs_samples (ts, mount_id) VALUES (\(ts), 1)")
                try c.execute("INSERT INTO device_health_samples (ts, device_id) VALUES (\(ts), 1)")
            }
            try c.execute("INSERT INTO io_rollup_5m (bucket_ts, device_id, sample_count) VALUES (0, 1, 1)")
        }
        XCTAssertEqual(try RetentionSampler().collect(f.context(86500)), .ok)
        try f.db.read { c in
            for table in RetentionSampler.rawTables {
                XCTAssertEqual(try c.query("SELECT ts FROM \(table) ORDER BY ts").compactMap { $0["ts"]?.integer }, [100, 101], table)
            }
            for table in ["mounts", "containers", "devices", "users", "io_rollup_5m"] {
                XCTAssertEqual(try c.query("SELECT count(*) AS n FROM \(table)").first?["n"], .integer(1), table)
            }
        }
    }
}
