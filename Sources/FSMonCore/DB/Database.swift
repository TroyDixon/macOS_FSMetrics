import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public enum SQLValue: Equatable {
    case null, integer(Int64), real(Double), text(String), blob(Data)
    public var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
    public var string: String? { if case .text(let value) = self { return value }; return nil }
}

/// Only use a connection inside its Database.read/write closure. Do not retain it
/// or call back into Database from that closure (the queues are synchronous).
public final class DatabaseConnection {
    private var handle: OpaquePointer?
    init(path: String, readOnly: Bool) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let error = failure()
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            throw error
        }
        do {
            try execute("PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL;")
            if !readOnly { try execute("PRAGMA journal_mode = WAL;") }
        } catch { close(); throw error }
    }
    deinit { close() }
    fileprivate func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }
    private func failure() -> DatabaseError {
        DatabaseError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
    }
    /// Executes SQL without bindings; supports multiple statements (e.g. schema DDL).
    public func execute(_ sql: String) throws {
        guard let handle else { throw failure() }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    public func execute(_ sql: String, bindings: [SQLValue]) throws {
        _ = try query(sql, bindings: bindings)
    }
    public func query(_ sql: String, bindings: [SQLValue] = []) throws -> [[String: SQLValue]] {
        guard let handle else { throw failure() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        guard let statement else { throw DatabaseError(message: "Empty SQL statement") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == bindings.count else {
            throw DatabaseError(message: "SQL binding count mismatch")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
            case .blob(let data):
                if data.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
                else { result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) } }
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        var rows = [[String: SQLValue]]()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            var row = [String: SQLValue]()
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    let bytes = sqlite3_column_text(statement, column)!
                    row[name] = .text(String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self))
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(statement, column))
                    row[name] = .blob(size == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column)!, count: size))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
    }
}

public final class Database {
    private let writerQueue = DispatchQueue(label: "fsmond.db.writer")
    private let readerQueue = DispatchQueue(label: "fsmond.db.reader")
    private let writer: DatabaseConnection
    private let reader: DatabaseConnection

    public init(path: String) throws {
        guard path != ":memory:" else { throw DatabaseError(message: "Use a file-backed database for separate WAL connections") }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try DatabaseConnection(path: url.path, readOnly: false)
        try Schema.apply(to: writer)
        reader = try DatabaseConnection(path: url.path, readOnly: true)
    }
    /// Serial, atomic write. A thrown error rolls back the entire closure.
    public func write<T>(_ body: (DatabaseConnection) throws -> T) throws -> T {
        try writerQueue.sync {
            try writer.execute("BEGIN IMMEDIATE")
            do {
                let result = try body(writer)
                try writer.execute("COMMIT")
                return result
            } catch { try? writer.execute("ROLLBACK"); throw error }
        }
    }
    public func read<T>(_ body: (DatabaseConnection) throws -> T) throws -> T {
        try readerQueue.sync { try body(reader) }
    }
    /// Stop producers and HTTP handlers before closing. Repeated closes are safe.
    public func close() throws {
        readerQueue.sync { reader.close() }
        try writerQueue.sync {
            defer { writer.close() }
            guard writerIsOpen else { return }
            writerIsOpen = false
            let result = try writer.query("PRAGMA wal_checkpoint(TRUNCATE)")
            if result.first?["busy"]?.integer != 0 { throw DatabaseError(message: "WAL checkpoint was busy") }
        }
    }
    private var writerIsOpen = true
    deinit { try? close() }
}
