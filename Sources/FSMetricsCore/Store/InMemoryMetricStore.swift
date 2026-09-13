import Foundation

/// In-memory `MetricStore` adapter used by tests.
///
/// Thread-safe via a lock; collection order is preserved so series reads are
/// deterministic.
public final class InMemoryMetricStore: MetricStore, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: [Metric] = []
    private var alerts: [AlertEvent] = []

    public init() {}

    // MARK: - MetricSink

    public func write(_ metrics: [Metric]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.metrics.append(contentsOf: metrics)
    }

    public func write(_ alert: AlertEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        alerts.append(alert)
    }

    // MARK: - Deletion

    public func deleteAlert(_ alert: AlertEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        alerts.removeAll { existing in
            existing.ts == alert.ts
                && existing.host == alert.host
                && existing.volume == alert.volume
                && existing.category == alert.category
                && existing.message == alert.message
                && existing.uid == alert.uid
        }
    }

    public func deleteAllAlerts() throws {
        lock.lock()
        defer { lock.unlock() }
        alerts.removeAll()
    }

    // MARK: - MetricQuery

    public func latest(of kind: MetricKind, volume: String, uid: String?) throws -> Sample? {
        lock.lock()
        defer { lock.unlock() }
        let matches = metrics.filter { m in
            m.kind == kind && m.volume == volume && (uid == nil || m.uid == uid)
        }
        guard let newest = matches.max(by: { $0.ts < $1.ts }) else { return nil }
        return Sample(ts: newest.ts, value: newest.value, uid: newest.uid, username: newest.username)
    }

    public func series(of kind: MetricKind, volume: String, since: Date) throws -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return metrics
            .filter { $0.kind == kind && $0.volume == volume && $0.ts >= since }
            .sorted { $0.ts < $1.ts }
            .map { Sample(ts: $0.ts, value: $0.value, uid: $0.uid, username: $0.username) }
    }

    public func recentAlerts(limit: Int) throws -> [AlertEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(alerts.sorted { $0.ts > $1.ts }.prefix(max(0, limit)))
    }

    public func volumes() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        var result: [String] = []
        for m in metrics where !seen.contains(m.volume) {
            seen.insert(m.volume)
            result.append(m.volume)
        }
        return result
    }
}
