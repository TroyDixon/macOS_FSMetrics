import Foundation

/// Write side of the storage seam.
public protocol MetricSink: Sendable {
    func write(_ metrics: [Metric]) throws
    func write(_ alert: AlertEvent) throws
}

/// Read side of the storage seam. Callers (alert engine, UI, CLI) depend on
/// this and never on GRDB.
public protocol MetricQuery: Sendable {
    func latest(of kind: MetricKind, volume: String, uid: String?) throws -> Sample?
    func series(of kind: MetricKind, volume: String, since: Date) throws -> [Sample]
    func recentAlerts(limit: Int) throws -> [AlertEvent]
    func volumes() throws -> [String]
}

/// The full store seam. Adapters: `SQLiteMetricStore` (production) and
/// `InMemoryMetricStore` (tests). Both must pass `StoreConformanceTests`.
public protocol MetricStore: MetricSink, MetricQuery {}

public extension MetricQuery {
    /// Convenience for the common case of a host-scoped, user-less metric.
    func latest(of kind: MetricKind, volume: String) throws -> Sample? {
        try latest(of: kind, volume: volume, uid: nil)
    }
}
