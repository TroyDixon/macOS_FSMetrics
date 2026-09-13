import Foundation
import GRDB

/// Errors raised while opening or validating the SQLite store.
public enum SQLiteMetricStoreError: Error, LocalizedError, Equatable, Sendable {
    /// The `v1` migration did not run, or the expected tables are absent.
    case schemaMissing(detail: String)

    public var errorDescription: String? {
        switch self {
        case .schemaMissing(let detail):
            return "SQLiteMetricStore schema is missing or incomplete: \(detail)"
        }
    }
}

/// Production ``MetricStore`` adapter: one SQLite file via GRDB.
///
/// Backed by a ``DatabaseQueue`` (single writer, low volume). WAL is enabled
/// at open, the schema is created by the `v1` migration, and any failure to
/// establish the schema throws ``SQLiteMetricStoreError/schemaMissing(detail:)``.
public final class SQLiteMetricStore: MetricStore, Sendable {
    /// Identifier of the schema migration required by this adapter.
    public static let schemaMigration = "v1"

    private let dbQueue: DatabaseQueue

    /// Opens (or creates) the database at `path`, creating parent directories
    /// as needed.
    public convenience init(path: String) throws {
        try self.init(url: URL(fileURLWithPath: path))
    }

    /// Opens (or creates) the database at `url`, creating parent directories
    /// as needed.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.journalMode = .wal
        let dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)

        var migrator = DatabaseMigrator()
        migrator.registerMigration(Self.schemaMigration) { db in
            try db.create(table: "metric") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull()
                t.column("kind", .text).notNull()
                t.column("host", .text).notNull()
                t.column("volume", .text).notNull()
                t.column("uid", .text)
                t.column("username", .text)
                t.column("value", .double).notNull()
                t.column("unit", .text).notNull()
            }
            try db.create(indexOn: "metric", columns: ["kind", "ts"])
            try db.create(indexOn: "metric", columns: ["volume", "ts"])

            try db.create(table: "alert") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull()
                t.column("host", .text).notNull()
                t.column("volume", .text).notNull()
                t.column("severity", .text).notNull()
                t.column("category", .text).notNull()
                t.column("message", .text).notNull()
                t.column("uid", .text)
            }
            try db.create(indexOn: "alert", columns: ["ts"])
        }

        // Register at open; fail loudly if the migration or its schema is absent.
        try migrator.migrate(dbQueue)
        let completed = try dbQueue.read { try migrator.completedMigrations($0) }
        guard completed.contains(Self.schemaMigration) else {
            throw SQLiteMetricStoreError.schemaMissing(
                detail: "migration '\(Self.schemaMigration)' did not complete "
                    + "(completed: \(completed))"
            )
        }
        try dbQueue.read { db in
            guard try db.tableExists("metric"), try db.tableExists("alert") else {
                throw SQLiteMetricStoreError.schemaMissing(
                    detail: "tables 'metric' and 'alert' were not created by migration "
                        + "'\(Self.schemaMigration)'"
                )
            }
        }

        self.dbQueue = dbQueue
    }

    /// Closes the underlying database connection. The queue also closes on
    /// deallocation; this releases the file eagerly.
    public func close() throws {
        try dbQueue.close()
    }

    // MARK: - MetricSink

    public func write(_ metrics: [Metric]) throws {
        guard !metrics.isEmpty else { return }
        try dbQueue.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO metric (ts, kind, host, volume, uid, username, value, unit)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for metric in metrics {
                try statement.execute(arguments: [
                    metric.ts.timeIntervalSince1970,
                    metric.kind.rawValue,
                    metric.host,
                    metric.volume,
                    metric.uid,
                    metric.username,
                    metric.value,
                    metric.kind.unit.rawValue,
                ])
            }
        }
    }

    public func write(_ alert: AlertEvent) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO alert (ts, host, volume, severity, category, message, uid)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                alert.ts.timeIntervalSince1970,
                alert.host,
                alert.volume,
                alert.severity.rawValue,
                alert.category,
                alert.message,
                alert.uid,
            ])
        }
    }

    /// Deletes alerts matching the row's identifying fields. `uid IS ?` so a
    /// nil uid matches the NULL column instead of comparing false.
    public func deleteAlert(_ alert: AlertEvent) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM alert
                WHERE ts = ? AND host = ? AND volume = ? AND category = ? AND message = ?
                  AND uid IS ?
                """, arguments: [
                alert.ts.timeIntervalSince1970,
                alert.host,
                alert.volume,
                alert.category,
                alert.message,
                alert.uid,
            ])
        }
    }

    public func deleteAllAlerts() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM alert")
        }
    }

    // MARK: - MetricQuery

    public func latest(of kind: MetricKind, volume: String, uid: String?) throws -> Sample? {
        try dbQueue.read { db in
            var sql = """
                SELECT ts, value, uid, username FROM metric
                WHERE kind = ? AND volume = ?
                """
            var values: [(any DatabaseValueConvertible)?] = [kind.rawValue, volume]
            if let uid {
                sql += " AND uid = ?"
                values.append(uid)
            }
            sql += " ORDER BY ts DESC LIMIT 1"

            guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(values)) else {
                return nil
            }
            return Sample(
                ts: Date(timeIntervalSince1970: row["ts"]),
                value: row["value"],
                uid: row["uid"],
                username: row["username"]
            )
        }
    }

    public func series(of kind: MetricKind, volume: String, since: Date) throws -> [Sample] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ts, value, uid, username FROM metric
                WHERE kind = ? AND volume = ? AND ts >= ?
                ORDER BY ts ASC
                """, arguments: [kind.rawValue, volume, since.timeIntervalSince1970])
            return rows.map { row in
                Sample(
                    ts: Date(timeIntervalSince1970: row["ts"]),
                    value: row["value"],
                    uid: row["uid"],
                    username: row["username"]
                )
            }
        }
    }

    public func recentAlerts(limit: Int) throws -> [AlertEvent] {
        let limit = max(0, limit)
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ts, severity, category, message, host, volume, uid FROM alert
                ORDER BY ts DESC LIMIT ?
                """, arguments: [limit])
            return rows.map { row in
                AlertEvent(
                    // Data is written by this adapter, so an unknown severity
                    // only arises from external tampering; degrade to warning.
                    severity: AlertEvent.Severity(rawValue: row["severity"]) ?? .warning,
                    category: row["category"],
                    message: row["message"],
                    host: row["host"],
                    volume: row["volume"],
                    uid: row["uid"],
                    ts: Date(timeIntervalSince1970: row["ts"])
                )
            }
        }
    }

    public func volumes() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT volume FROM metric")
        }
    }
}
