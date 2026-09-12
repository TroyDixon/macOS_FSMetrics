import Foundation
import FSMetricsCore

// MARK: - Severity

/// UI severity for the menu-bar badge and status colors. Ordered from least to
/// most severe so `max` yields the worst current state.
enum StatusLevel: Int, Comparable, Sendable {
    case none = 0
    case ok = 1
    case warning = 2
    case critical = 3

    static func < (lhs: StatusLevel, rhs: StatusLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .none: return "No data"
        case .ok: return "OK"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "questionmark.circle"
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

// MARK: - Read models

/// One row of the Flask `/api/summary` payload, plus the configured metadata
/// needed to draw it.
struct VolumeSummary: Identifiable, Sendable, Equatable {
    var path: String
    var label: String
    var kind: VolumeKind
    var usedPct: Double?
    var usedBytes: Double?
    var totalBytes: Double?
    var freeBytes: Double?
    var smartOK: Bool?
    var writable: Bool?
    var throughputGbps: Double?
    var throughputAgeSeconds: Double?

    var id: String { path }

    init(
        path: String,
        label: String,
        kind: VolumeKind,
        usedPct: Double? = nil,
        usedBytes: Double? = nil,
        totalBytes: Double? = nil,
        freeBytes: Double? = nil,
        smartOK: Bool? = nil,
        writable: Bool? = nil,
        throughputGbps: Double? = nil,
        throughputAgeSeconds: Double? = nil
    ) {
        self.path = path
        self.label = label
        self.kind = kind
        self.usedPct = usedPct
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.smartOK = smartOK
        self.writable = writable
        self.throughputGbps = throughputGbps
        self.throughputAgeSeconds = throughputAgeSeconds
    }

    /// Capacity severity from the configured thresholds (never hard-coded).
    func capacitySeverity(thresholds: AlertThresholds) -> StatusLevel {
        guard let usedPct else { return .none }
        if usedPct >= thresholds.capacityPctCrit { return .critical }
        if usedPct >= thresholds.capacityPctWarn { return .warning }
        return .ok
    }

    /// SMART failure or a read-only volume is critical; no health sample at
    /// all is `none` so absence of data does not mask real data.
    func healthSeverity() -> StatusLevel {
        if smartOK == false || writable == false { return .critical }
        if smartOK == nil, writable == nil { return .none }
        return .ok
    }

    /// The Flask page falls back to `(used_pct / 100) * total_bytes` when an
    /// explicit used-bytes sample is unavailable.
    var displayUsedBytes: Double? {
        if let usedBytes { return usedBytes }
        guard let usedPct, let totalBytes else { return nil }
        return usedPct / 100 * totalBytes
    }
}

/// One row of the Flask `/api/users` payload.
struct UserUsage: Identifiable, Sendable, Equatable {
    var uid: String
    var username: String?
    var bytes: Double

    var id: String { uid }

    var displayName: String {
        if let username, !username.isEmpty { return username }
        return uid
    }
}

/// One row of the Flask `/api/alerts` payload.
struct AlertRow: Identifiable, Sendable, Equatable {
    var ts: Date
    var severity: AlertEvent.Severity
    var volume: String
    var category: String
    var message: String
    var uid: String?

    /// Stable across refreshes so SwiftUI keeps row identity.
    var id: String {
        "\(ts.timeIntervalSince1970)|\(category)|\(volume)|\(uid ?? "")|\(message)"
    }
}

/// One point of either Flask history endpoint.
struct ChartPoint: Identifiable, Sendable, Equatable {
    var ts: Date
    var value: Double

    var id: String {
        "\(ts.timeIntervalSince1970)-\(value)"
    }
}

// MARK: - Formatting

/// Mirrors the Flask page's small formatting helpers.
enum MetricsFormat {
    /// `fmtBytes`: 1024-based units with two decimals.
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var scaled = value
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        return String(format: "%.2f %@", scaled, units[index])
    }

    static func gbps(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "no I/O sample" }
        return String(format: "%.2f GB/s", value)
    }

    static func pct(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%.1f%%", value)
    }

    /// `fmtTime`: locale time-of-day.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        return describeAge(max(0, now.timeIntervalSince(date)))
    }

    static func age(secondsAgo: TimeInterval?) -> String {
        guard let secondsAgo else { return "never" }
        return describeAge(max(0, secondsAgo))
    }

    private static func describeAge(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(Int(seconds))s ago"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }
}

// MARK: - Snapshot loading

/// Volumes currently selected in the dashboard pickers.
struct DashboardSelection: Sendable {
    var throughputVolume: String?
    var capacityVolume: String?
    var usersVolume: String?
}

/// Point-in-time dashboard data, produced off the main actor.
struct DashboardSnapshot: Sendable {
    var volumes: [VolumeSummary]
    var volumeNames: [String]
    var alerts: [AlertRow]
    var throughputVolume: String?
    var throughputPoints: [ChartPoint]
    var capacityVolume: String?
    var capacityPoints: [ChartPoint]
    var usersVolume: String?
    var users: [UserUsage]
    var lastCapacityScan: Date?
}

/// Read-only projection of `MetricQuery` into UI models. This is the only
/// place the app reads the store, and it runs on a background task so views
/// never touch GRDB.
enum DashboardLoader {
    private enum Lookback {
        static let throughput: TimeInterval = 3600
        static let capacityHistory: TimeInterval = 6 * 3600
        static let users: TimeInterval = 3600
        static let alerts = 100
    }

    static func load(
        store: any MetricQuery,
        settings: Settings,
        selection: DashboardSelection,
        now: Date
    ) throws -> DashboardSnapshot {
        let volumeNames = try store.volumes().sorted()

        var summaries: [VolumeSummary] = []
        var lastCapacityScan: Date?
        for path in volumeNames {
            let configured = settings.volumes.first { $0.path == path }
            let usedPct = try store.latest(of: .usedPct, volume: path)
            let total = try store.latest(of: .totalBytes, volume: path)
            let used = try store.latest(of: .usedBytes, volume: path)
            let free = try store.latest(of: .freeBytes, volume: path)
            let smart = try store.latest(of: .smartOK, volume: path)
            let writable = try store.latest(of: .writable, volume: path)
            let throughput = try store.latest(of: .throughputGbps, volume: path)

            // `capacity.user_bytes` is only written by the expensive capacity
            // scan, so its newest timestamp is the age of the last scan.
            let userBytes = try store.latest(of: .userBytes, volume: path, uid: nil)
            if let userBytes, lastCapacityScan.map({ userBytes.ts > $0 }) ?? true {
                lastCapacityScan = userBytes.ts
            }

            summaries.append(VolumeSummary(
                path: path,
                label: configured?.label ?? path,
                kind: configured?.kind ?? .other,
                usedPct: usedPct?.value,
                usedBytes: used?.value,
                totalBytes: total?.value,
                freeBytes: free?.value,
                smartOK: smart.map { $0.value != 0 },
                writable: writable.map { $0.value != 0 },
                throughputGbps: throughput?.value,
                throughputAgeSeconds: throughput.map { now.timeIntervalSince($0.ts) }
            ))
        }

        let throughputVolume = resolved(selection.throughputVolume, among: volumeNames)
        var throughputPoints: [ChartPoint] = []
        if let throughputVolume {
            throughputPoints = try store
                .series(
                    of: .throughputGbps,
                    volume: throughputVolume,
                    since: now.addingTimeInterval(-Lookback.throughput)
                )
                .map { ChartPoint(ts: $0.ts, value: $0.value) }
        }

        let capacityVolume = resolved(selection.capacityVolume, among: volumeNames)
        var capacityPoints: [ChartPoint] = []
        if let capacityVolume {
            capacityPoints = try store
                .series(
                    of: .usedPct,
                    volume: capacityVolume,
                    since: now.addingTimeInterval(-Lookback.capacityHistory)
                )
                .map { ChartPoint(ts: $0.ts, value: $0.value) }
        }

        let usersVolume = resolved(selection.usersVolume, among: volumeNames)
        var users: [UserUsage] = []
        if let usersVolume {
            // Flask `/api/users`: rows since 3600s, newest per uid wins, then
            // descending by bytes.
            let samples = try store
                .series(of: .userBytes, volume: usersVolume, since: now.addingTimeInterval(-Lookback.users))
            var latestByUID: [String: Sample] = [:]
            for sample in samples {
                guard let uid = sample.uid else { continue }
                if let existing = latestByUID[uid], existing.ts > sample.ts { continue }
                latestByUID[uid] = sample
            }
            users = latestByUID.values
                .map { UserUsage(uid: $0.uid ?? "", username: $0.username, bytes: $0.value) }
                .sorted { $0.bytes > $1.bytes }
        }

        let alerts = try store.recentAlerts(limit: Lookback.alerts).map { event in
            AlertRow(
                ts: event.ts,
                severity: event.severity,
                volume: event.volume,
                category: event.category,
                message: event.message,
                uid: event.uid
            )
        }

        return DashboardSnapshot(
            volumes: summaries,
            volumeNames: volumeNames,
            alerts: alerts,
            throughputVolume: throughputVolume,
            throughputPoints: throughputPoints,
            capacityVolume: capacityVolume,
            capacityPoints: capacityPoints,
            usersVolume: usersVolume,
            users: users,
            lastCapacityScan: lastCapacityScan
        )
    }

    private static func resolved(_ candidate: String?, among names: [String]) -> String? {
        if let candidate, names.contains(candidate) { return candidate }
        return names.first
    }
}
