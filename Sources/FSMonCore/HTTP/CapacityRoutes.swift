import Foundation

public enum CapacityRoutes {
    public static func register(on router: Router, db: Database, inventory: MountInventoryStore,
                                statuses: SamplerStatusStore) {
        let started = ProcessInfo.processInfo.systemUptime
        register(on: router, db: db, inventory: inventory, statuses: statuses,
                 now: { Int64(Date().timeIntervalSince1970) },
                 uptime: { Int64(max(0, ProcessInfo.processInfo.systemUptime - started)) })
    }

    static func register(on router: Router, db: Database, inventory: MountInventoryStore,
                         statuses: SamplerStatusStore, now: @escaping () -> Int64,
                         uptime: @escaping () -> Int64) {
        router.get("/api/v1/health") { _ in
            let samplers = statuses.snapshot()
            let status = samplers.contains { $0.status == "error" } ? "error" :
                (samplers.isEmpty || samplers.contains { $0.status != "ok" } ? "degraded" : "ok")
            return try .json(.object(["data": .object([
                "status": .string(status), "uptime_seconds": .integer(uptime()), "version": .string("0.1.0"),
                "samplers": .array(samplers.map { sampler in
                    var fields: [String: JSON] = ["name": .string(sampler.name), "interval": .number(sampler.interval),
                                                  "last_run": sampler.lastRun.json, "status": .string(sampler.status)]
                    // Contract health example omits detail when there is no diagnostic.
                    if let detail = sampler.detail { fields["detail"] = .string(detail) }
                    return .object(fields)
                }),
            ])]))
        }
        router.get("/api/v1/mounts") { _ in
            let generated = now()
            let data = try inventoryRows(db: db, inventory: inventory, now: generated)
            return try .json(.object(["data": .array(data.map { $0.json }),
                                     "meta": .object(["count": .integer(Int64(data.count)), "generated_at": .integer(generated)])]))
        }
        router.get("/api/v1/mounts/{id}") { request in
            guard let id = mountID(request) else { return badRequest("Expected an ID such as 'mount:1'") }
            let generated = now()
            let rows = try inventoryRows(db: db, inventory: inventory, now: generated)
            guard let mount = rows.first(where: { $0.id == id }) else { return missing(id) }
            return try .json(.object(["data": mount.json, "meta": .object(["generated_at": .integer(generated)])]))
        }
        router.get("/api/v1/mounts/{id}/capacity") { request in
            guard let id = mountID(request) else { return badRequest("Expected an ID such as 'mount:1'") }
            let generated = now()
            let range: CapacityRange
            do { range = try CapacityRange(query: request.query, now: generated) }
            catch { return badRequest(String(describing: error)) }
            return try db.read { connection in
                guard try !connection.query("SELECT id FROM mounts WHERE id = ?", bindings: [.integer(id)]).isEmpty else {
                    return missing(id)
                }
                let rows = try connection.query("""
                    SELECT (ts / ?) * ? AS bucket,
                      AVG(total_bytes) AS total_bytes, AVG(free_bytes) AS free_bytes,
                      AVG(available_bytes) AS available_bytes, AVG(used_bytes) AS used_bytes,
                      AVG(inodes_total) AS inodes_total, AVG(inodes_free) AS inodes_free,
                      AVG(CASE WHEN used_bytes * 1.0 + available_bytes > 0
                        THEN used_bytes * 100.0 / (used_bytes * 1.0 + available_bytes) END) AS used_pct
                    FROM capacity_samples WHERE mount_id = ? AND ts >= ? AND ts < ?
                    GROUP BY bucket ORDER BY bucket
                    """, bindings: [.integer(range.step), .integer(range.step), .integer(id), .integer(range.from), .integer(range.to)])
                let buckets = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row["bucket"]?.integer.map { ($0, row) } })
                let timestamps = range.timestamps
                var series: [String: JSON] = ["series_id": .string("mount:\(id)"), "step": .integer(range.step),
                                              "from": .integer(range.from), "to": .integer(range.to),
                                              "timestamps": .array(timestamps.map(JSON.integer))]
                for field in capacityFields {
                    series[field] = .array(timestamps.map { buckets[$0]?[field]?.json ?? .null })
                }
                return try .json(.object(["data": .object(series), "meta": .object(["generated_at": .integer(generated)])]))
            }
        }
    }

    private static let capacityFields = ["total_bytes", "free_bytes", "available_bytes", "used_bytes", "inodes_total", "inodes_free", "used_pct"]
    private struct InventoryRow { let id: Int64; let json: JSON }

    private static func inventoryRows(db: Database, inventory: MountInventoryStore, now: Int64) throws -> [InventoryRow] {
        // Do not resurrect rows from a previous daemon run or leave a frozen
        // inventory looking current indefinitely after collection has failed.
        guard let snapshot = inventory.snapshot(), now - snapshot.ts <= 15, !snapshot.ids.isEmpty else { return [] }
        let ids = snapshot.ids
        return try db.read { connection in
            let rows = try connection.query("""
                SELECT m.*, c.ts AS capacity_ts, c.total_bytes, c.free_bytes, c.available_bytes,
                  c.used_bytes, c.inodes_total, c.inodes_free
                FROM mounts m LEFT JOIN capacity_samples c ON c.mount_id = m.id AND c.ts = (
                  SELECT MAX(ts) FROM capacity_samples WHERE mount_id = m.id AND ts <= ?)
                WHERE m.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                ORDER BY m.mount_point, m.id
                """, bindings: [.integer(snapshot.ts)] + ids.map(SQLValue.integer))
            return rows.map { row in
                let id = row["id"]!.integer!
                let containerID = row["container_id"]?.integer
                let siblings = containerID.map { container in
                    rows.filter { $0["container_id"]?.integer == container && $0["id"]?.integer != id }
                        .compactMap { $0["id"]?.integer }.sorted().map { JSON.string("mount:\($0)") }
                } ?? []
                var capacity: JSON = .null
                if let ts = row["capacity_ts"]?.integer {
                    var values = Dictionary(uniqueKeysWithValues: capacityFields.map { ($0, row[$0]?.json ?? .null) })
                    values["ts"] = .integer(ts)
                    if let used = row["used_bytes"]?.integer, let available = row["available_bytes"]?.integer,
                       Double(used) + Double(available) > 0 {
                        values["used_pct"] = .number(Double(used) * 100 / (Double(used) + Double(available)))
                    }
                    capacity = .object(values)
                }
                return InventoryRow(id: id, json: .object([
                    "id": .string("mount:\(id)"), "mount_point": row["mount_point"]!.json,
                    "device_node": row["device_node"]?.json ?? .null, "fs_type": row["fs_type"]!.json,
                    "volume_uuid": row["volume_uuid"]?.json ?? .null, "volume_name": row["volume_name"]?.json ?? .null,
                    "container_id": containerID.map { .string("container:\($0)") } ?? .null,
                    "device_id": row["device_id"]?.integer.map { .string("device:\($0)") } ?? .null,
                    "is_remote": .bool(row["is_remote"]?.integer == 1), "read_only": .bool(row["read_only"]?.integer == 1),
                    "capacity": capacity, "shares_container_with": .array(siblings),
                ]))
            }
        }
    }

    private static func mountID(_ request: Request) -> Int64? {
        guard let raw = request.parameters["id"], raw.hasPrefix("mount:") else { return nil }
        let digits = raw.dropFirst(6)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let id = Int64(digits), id > 0 else { return nil }
        return id
    }
    private static func badRequest(_ message: String) -> Response { .error(.badRequest, message: message, status: 400) }
    private static func missing(_ id: Int64) -> Response { .error(.notFound, message: "No mount with id 'mount:\(id)'", status: 404) }
}

struct CapacityRange {
    let from: Int64
    let to: Int64
    let step: Int64
    var timestamps: [Int64] {
        let start = (from / step) * step
        let count = Int((to - 1 - start) / step + 1)
        return (0..<count).map { start + Int64($0) * step }
    }
    init(query: [String: String], now: Int64) throws {
        func parse(_ name: String, default fallback: Int64) throws -> Int64 {
            guard let raw = query[name] else { return fallback }
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int64(raw) else {
                throw FilesystemFailure(description: "\(name) must be a nonnegative integer")
            }
            return number
        }
        to = try parse("to", default: now)
        from = try parse("from", default: max(0, to - 3600))
        step = try parse("step", default: 60)
        guard from < to, (1...86400).contains(step) else {
            throw FilesystemFailure(description: "Require from < to and step between 1 and 86400 seconds")
        }
        let first = (from / step) * step
        guard (to - 1 - first) / step < 10_000 else {
            throw FilesystemFailure(description: "Requested range exceeds 10000 buckets; increase step")
        }
    }
}

extension SQLValue {
    var json: JSON {
        switch self {
        case .null: return .null
        case .integer(let value): return .integer(value)
        case .real(let value): return .number(value)
        case .text(let value): return .string(value)
        case .blob: return .null
        }
    }
}
extension Optional where Wrapped == Int64 {
    var json: JSON { map(JSON.integer) ?? .null }
}
