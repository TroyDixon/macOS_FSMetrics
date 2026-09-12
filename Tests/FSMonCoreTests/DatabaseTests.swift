import XCTest
@testable import FSMonCore

final class DatabaseTests: XCTestCase {
    func temporaryPath() -> String { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.db").path }
    func testRoundTripSchemaReopenAndConnectionPragmas() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let db = try Database(path: path)
        let values: [SQLValue] = [.integer(9_007_199_254_740_993), .real(1.25), .text("quote'\0雪"), .null, .blob(Data([0, 255])), .blob(Data())]
        try db.write { connection in
            XCTAssertEqual(try connection.query("PRAGMA foreign_keys").first?["foreign_keys"], .integer(1))
            XCTAssertEqual(try connection.query("PRAGMA busy_timeout").first?["timeout"], .integer(5000))
            XCTAssertEqual(try connection.query("PRAGMA synchronous").first?["synchronous"], .integer(1))
            try connection.execute("CREATE TABLE test_values (i INTEGER, r REAL, t TEXT, n TEXT, b BLOB, e BLOB)")
            try connection.execute("INSERT INTO test_values VALUES (?, ?, ?, ?, ?, ?)", bindings: values)
        }
        try db.read { connection in
            let row = try XCTUnwrap(connection.query("SELECT * FROM test_values").first)
            XCTAssertEqual([row["i"]!, row["r"]!, row["t"]!, row["n"]!, row["b"]!, row["e"]!], values)
            XCTAssertEqual(try connection.query("PRAGMA journal_mode").first?["journal_mode"], .text("wal"))
            XCTAssertEqual(try connection.query("PRAGMA foreign_keys").first?["foreign_keys"], .integer(1))
            XCTAssertEqual(try connection.query("PRAGMA busy_timeout").first?["timeout"], .integer(5000))
            XCTAssertEqual(try connection.query("PRAGMA synchronous").first?["synchronous"], .integer(1))
            XCTAssertThrowsError(try connection.execute("DELETE FROM test_values"))
            let tables = Set(try connection.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.string })
            let expected: Set<String> = ["devices", "containers", "mounts", "users", "capacity_samples", "container_capacity_samples", "io_samples", "user_io_samples", "process_io_samples", "nfs_samples", "device_health_samples", "snapshots", "tree_scans", "tree_scan_entries", "alert_events", "io_rollup_5m", "test_values"]
            XCTAssertEqual(tables, expected)
        }
        try db.close()
        try db.close()
        XCTAssertThrowsError(try db.read { try $0.query("SELECT 1") })
        let reopened = try Database(path: path)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.read { try $0.query("PRAGMA user_version").first?["user_version"] }, .integer(1))
        XCTAssertEqual(try reopened.read { try $0.query("SELECT count(*) AS count FROM test_values").first?["count"] }, .integer(1))
    }
    func testRollbackAndForeignKeyEnforcement() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let db = try Database(path: path)
        defer { try? db.close() }
        XCTAssertThrowsError(try db.write { conn in
            try conn.execute("INSERT INTO users (uid, first_seen, last_seen) VALUES (501, 1, 1)")
            try conn.execute("INSERT INTO user_io_samples VALUES (1, 999, 0, 0, 1)")
        })
        XCTAssertEqual(try db.read { try $0.query("SELECT count(*) AS n FROM users").first?["n"] }, .integer(0))
    }
    func testReaderContinuesDuringUncommittedWrite() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let db = try Database(path: path)
        defer { try? db.close() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "writer committed")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try db.write { conn in
                    try conn.execute("INSERT INTO users (uid, first_seen, last_seen) VALUES (501, 1, 1)")
                    entered.signal()
                    _ = release.wait(timeout: .now() + 3)
                }
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        XCTAssertEqual(try db.read { try $0.query("SELECT count(*) AS n FROM users").first?["n"] }, .integer(0))
        release.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(try db.read { try $0.query("SELECT count(*) AS n FROM users").first?["n"] }, .integer(1))
    }
}
