import Foundation

/// The unit attached to a metric value.
///
/// Raw values intentionally match the Python collector's `unit` strings so the
/// on-disk vocabulary stays stable across the translation.
public enum Unit: String, Codable, Sendable, CaseIterable {
    case bool
    case bytes
    case pct
    case gbps = "GB/s"
    case tps
    case kb = "KB"
    case count
}

/// The shared metric vocabulary.
///
/// Raw values MUST equal the Python `metric_type` strings so data stays
/// self-describing and greppable. This is the only place metric strings live;
/// callers never spell them as literals.
public enum MetricKind: String, CaseIterable, Codable, Sendable {
    case smartOK = "health.smart_ok"
    case writable = "health.writable"
    case nvmeSmartOK = "health.nvme_smart_ok"
    case totalBytes = "capacity.total_bytes"
    case usedBytes = "capacity.used_bytes"
    case freeBytes = "capacity.free_bytes"
    case usedPct = "capacity.used_pct"
    case containerTotalBytes = "capacity.container_total_bytes"
    case containerAvailableBytes = "capacity.container_available_bytes"
    case containerUsedPct = "capacity.container_used_pct"
    case userBytes = "capacity.user_bytes"
    case throughputGbps = "perf.throughput_gbps"
    case transfersPerSec = "perf.transfers_per_sec"
    case kbPerTransfer = "perf.kb_per_transfer"
    case nfsMountOK = "nfs.mount_ok"
    case pnfsEnabled = "nfs.pnfs_enabled"
    case nfsClientTimeouts = "nfs.client_timeouts"
    case nfsClientRetransmits = "nfs.client_retransmits"

    public var unit: Unit {
        switch self {
        case .smartOK, .writable, .nvmeSmartOK, .nfsMountOK, .pnfsEnabled:
            return .bool
        case .totalBytes, .usedBytes, .freeBytes, .containerTotalBytes,
             .containerAvailableBytes, .userBytes:
            return .bytes
        case .usedPct, .containerUsedPct:
            return .pct
        case .throughputGbps:
            return .gbps
        case .transfersPerSec:
            return .tps
        case .kbPerTransfer:
            return .kb
        case .nfsClientTimeouts, .nfsClientRetransmits:
            return .count
        }
    }

    public var category: String {
        switch self {
        case .smartOK, .writable, .nvmeSmartOK:
            return "health"
        case .totalBytes, .usedBytes, .freeBytes, .usedPct,
             .containerTotalBytes, .containerAvailableBytes, .containerUsedPct,
             .userBytes:
            return "capacity"
        case .throughputGbps, .transfersPerSec, .kbPerTransfer:
            return "perf"
        case .nfsMountOK, .pnfsEnabled, .nfsClientTimeouts, .nfsClientRetransmits:
            return "nfs"
        }
    }
}

/// One collected observation, ready to persist.
public struct Metric: Sendable, Equatable, Hashable, Codable {
    public var kind: MetricKind
    public var host: String
    public var volume: String
    public var value: Double
    public var uid: String?
    public var username: String?
    public var ts: Date

    public init(
        kind: MetricKind,
        host: String,
        volume: String,
        value: Double,
        uid: String? = nil,
        username: String? = nil,
        ts: Date
    ) {
        self.kind = kind
        self.host = host
        self.volume = volume
        self.value = value
        self.uid = uid
        self.username = username
        self.ts = ts
    }
}

/// A single time-series point as read back from a `MetricQuery`.
public struct Sample: Sendable, Equatable, Codable {
    public var ts: Date
    public var value: Double
    public var uid: String?
    public var username: String?

    public init(ts: Date, value: Double, uid: String? = nil, username: String? = nil) {
        self.ts = ts
        self.value = value
        self.uid = uid
        self.username = username
    }
}

/// A durable alert event. `AlertEngine` returns these; the service persists
/// them via `MetricSink` and dispatches them via `Notifier`.
public struct AlertEvent: Sendable, Equatable, Codable {
    public enum Severity: String, Codable, Sendable {
        case warning
        case critical
    }

    public var severity: Severity
    /// "capacity" | "user_growth" | "health" | "nfs" | "performance"
    public var category: String
    public var message: String
    public var host: String
    public var volume: String
    public var uid: String?
    public var ts: Date

    public init(
        severity: Severity,
        category: String,
        message: String,
        host: String,
        volume: String,
        uid: String? = nil,
        ts: Date
    ) {
        self.severity = severity
        self.category = category
        self.message = message
        self.host = host
        self.volume = volume
        self.uid = uid
        self.ts = ts
    }
}
