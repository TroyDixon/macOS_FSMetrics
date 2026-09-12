import Foundation
import os

/// Evaluates alert rules against the store and returns events.
///
/// `evaluate` is pure: it reads the store and returns `[AlertEvent]`. The
/// caller (``CollectorService``) persists and notifies. Rules are ported from
/// Python `collector/alerts.py`; a `cooldown` was added so the same alert
/// does not re-fire every poll.
public struct AlertEngine: Sendable {
    public let thresholds: AlertThresholds

    private static let log = Logger(subsystem: "local.fsmetrics", category: "alerts")

    public init(thresholds: AlertThresholds = AlertThresholds()) {
        self.thresholds = thresholds
    }

    public func evaluate(
        store: any MetricQuery,
        host: String,
        volumes: [String],
        now: Date
    ) throws -> [AlertEvent] {
        var events: [AlertEvent] = []

        for volume in volumes {
            events.append(contentsOf: try capacityEvents(store: store, host: host, volume: volume, now: now))
            events.append(contentsOf: try userGrowthEvents(store: store, host: host, volume: volume, now: now))
            events.append(contentsOf: try healthEvents(store: store, host: host, volume: volume, now: now))
            events.append(contentsOf: try stallEvents(store: store, host: host, volume: volume, now: now))
        }

        let recent = try store.recentAlerts(limit: 1000)
        return events.filter { !isCoolingDown($0, recent: recent, now: now) }
    }

    // MARK: - Rules

    private func capacityEvents(
        store: any MetricQuery, host: String, volume: String, now: Date
    ) throws -> [AlertEvent] {
        let containerSample = try store.latest(of: .containerUsedPct, volume: volume)
        let sample: Sample
        if let containerSample {
            sample = containerSample
        } else {
            guard let volumeSample = try store.latest(of: .usedPct, volume: volume) else {
                return []
            }
            sample = volumeSample
        }
        let pct = sample.value
        let subject = containerSample.map {
            "\(volume): APFS container \($0.username ?? "unknown")"
        } ?? volume
        if pct >= thresholds.capacityPctCrit {
            return [AlertEvent(
                severity: .critical,
                category: "capacity",
                message: "\(subject) is \(Self.oneDecimal(pct))% full (>= \(Self.plain(thresholds.capacityPctCrit))% critical threshold)",
                host: host,
                volume: volume,
                ts: now
            )]
        }
        if pct >= thresholds.capacityPctWarn {
            return [AlertEvent(
                severity: .warning,
                category: "capacity",
                message: "\(subject) is \(Self.oneDecimal(pct))% full (>= \(Self.plain(thresholds.capacityPctWarn))% warn threshold)",
                host: host,
                volume: volume,
                ts: now
            )]
        }
        return []
    }

    /// Compares each user's newest `capacity.user_bytes` sample against their
    /// earliest inside the lookback window. A large positive delta is the
    /// signature we treat as suspicious/noteworthy.
    private func userGrowthEvents(
        store: any MetricQuery, host: String, volume: String, now: Date
    ) throws -> [AlertEvent] {
        let since = now.addingTimeInterval(-thresholds.userGrowthWindow)
        let samples = try store.series(of: .userBytes, volume: volume, since: since)
        var byUID: [String: [Sample]] = [:]
        for sample in samples {
            guard let uid = sample.uid else { continue }
            byUID[uid, default: []].append(sample)
        }

        var events: [AlertEvent] = []
        for (uid, userSamples) in byUID {
            guard userSamples.count >= 2 else { continue }
            let sorted = userSamples.sorted { $0.ts < $1.ts }
            guard let first = sorted.first, let last = sorted.last else { continue }
            let delta = last.value - first.value
            guard delta >= thresholds.userGrowthThreshold else { continue }
            let username = last.username ?? uid
            let gb = delta / 1e9
            events.append(AlertEvent(
                severity: .warning,
                category: "user_growth",
                message: String(
                    format: "user '%@' grew usage by %.2f GB in the last %.0fs on %@",
                    username, gb, thresholds.userGrowthWindow, volume
                ),
                host: host,
                volume: volume,
                uid: uid,
                ts: now
            ))
        }
        return events
    }

    private func healthEvents(
        store: any MetricQuery, host: String, volume: String, now: Date
    ) throws -> [AlertEvent] {
        var events: [AlertEvent] = []
        if let smart = try store.latest(of: .smartOK, volume: volume), smart.value == 0 {
            events.append(AlertEvent(
                severity: .critical,
                category: "health",
                message: "\(volume): backing block storage SMART status is not OK",
                host: host,
                volume: volume,
                ts: now
            ))
        }
        if let writable = try store.latest(of: .writable, volume: volume), writable.value == 0 {
            events.append(AlertEvent(
                severity: .critical,
                category: "health",
                message: "\(volume): volume is not writable (read-only or offline)",
                host: host,
                volume: volume,
                ts: now
            ))
        }
        if let nfs = try store.latest(of: .nfsMountOK, volume: volume), nfs.value == 0 {
            events.append(AlertEvent(
                severity: .critical,
                category: "nfs",
                message: "\(volume): NFS mount appears to be down",
                host: host,
                volume: volume,
                ts: now
            ))
        }
        return events
    }

    private func stallEvents(
        store: any MetricQuery, host: String, volume: String, now: Date
    ) throws -> [AlertEvent] {
        guard let sample = try store.latest(of: .throughputGbps, volume: volume) else { return [] }
        let age = now.timeIntervalSince(sample.ts)
        guard age > thresholds.throughputStallSeconds else { return [] }
        return [AlertEvent(
            severity: .warning,
            category: "performance",
            message: "\(volume): no I/O throughput samples in \(Int(age))s (collector or mount may be stuck)",
            host: host,
            volume: volume,
            ts: now
        )]
    }

    // MARK: - Cooldown

    /// Suppress an event when an alert for the same rule/volume/uid fired
    /// within `cooldown`. The Python engine re-fired the same alert every poll;
    /// this is the fix.
    private func isCoolingDown(_ event: AlertEvent, recent: [AlertEvent], now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-thresholds.cooldown)
        let duplicate = recent.contains { existing in
            existing.ts >= cutoff
                && existing.category == event.category
                && existing.volume == event.volume
                && existing.uid == event.uid
                && existing.severity == event.severity
        }
        if duplicate {
            Self.log.debug("suppressed duplicate alert: \(event.message, privacy: .public)")
        }
        return duplicate
    }

    // MARK: - Formatting

    /// Python prints `{pct:.1f}` and thresholds as plain numbers (e.g. "95.0").
    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func plain(_ value: Double) -> String {
        String(value)
    }
}
