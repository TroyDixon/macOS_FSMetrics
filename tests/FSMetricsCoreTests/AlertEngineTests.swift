import Foundation
import Testing

import FSMetricsCore

/// Pure-outcome tests for ``AlertEngine`` at the
/// `evaluate(store:host:volumes:now:)` seam, porting `tests/test_alerts.py`
/// plus the stall and cooldown rules. The engine never writes: tests persist
/// returned events themselves, exactly as ``CollectorService`` does.
@Suite("AlertEngine")
struct AlertEngineTests {
    private let host = "mac-mini"
    private let volume = "/"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func metric(
        _ kind: MetricKind,
        volume: String? = nil,
        value: Double,
        uid: String? = nil,
        username: String? = nil,
        ts: Date? = nil
    ) -> Metric {
        Metric(
            kind: kind,
            host: host,
            volume: volume ?? self.volume,
            value: value,
            uid: uid,
            username: username,
            ts: ts ?? now
        )
    }

    /// The Python spike scenario: 1e9 -> 10e9 bytes within the window.
    private func growthMetrics(uid: String, username: String) -> [Metric] {
        [
            metric(
                .userBytes, value: 1e9, uid: uid, username: username,
                ts: now.addingTimeInterval(-300)
            ),
            metric(.userBytes, value: 10e9, uid: uid, username: username, ts: now),
        ]
    }

    // MARK: - Capacity

    @Test("used_pct at or above the critical threshold fires one critical capacity alert")
    func capacityCritical() throws {
        let store = InMemoryMetricStore()
        try store.write([metric(.usedPct, value: 97.5)])
        // Explicit defaults: warn 80, crit 95.
        let engine = AlertEngine(thresholds: AlertThresholds(
            capacityPctWarn: 80, capacityPctCrit: 95
        ))

        let events = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.severity == .critical)
        #expect(event.category == "capacity")
        #expect(event.volume == volume)
        #expect(event.uid == nil)
        #expect(event.message.contains("97.5"))
        #expect(event.ts == now)
    }

    @Test("used_pct below the warn threshold is silent")
    func capacityBelowThreshold() throws {
        let store = InMemoryMetricStore()
        try store.write([metric(.usedPct, value: 40)])
        let engine = AlertEngine(thresholds: AlertThresholds(
            capacityPctWarn: 80, capacityPctCrit: 95
        ))

        let events = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)
        #expect(events.isEmpty)
    }

    // MARK: - User growth

    @Test("a growth spike inside the window fires exactly one user_growth alert")
    func userGrowthSpike() throws {
        let store = InMemoryMetricStore()
        try store.write([
            metric(
                .userBytes, value: 1e9, uid: "501", username: "alice",
                ts: now.addingTimeInterval(-300)
            ),
            metric(.userBytes, value: 10e9, uid: "501", username: "alice", ts: now),
        ])
        let engine = AlertEngine(thresholds: AlertThresholds(
            userGrowthWindow: 600, userGrowthThreshold: 5e9
        ))

        let events = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.severity == .warning)
        #expect(event.category == "user_growth")
        #expect(event.uid == "501")
        #expect(event.message.contains("alice"))
        #expect(event.message.contains("9.00 GB"))
    }

    @Test("gradual growth below the threshold is silent")
    func userGrowthGradual() throws {
        let store = InMemoryMetricStore()
        try store.write([
            metric(
                .userBytes, value: 1e9, uid: "501", username: "alice",
                ts: now.addingTimeInterval(-300)
            ),
            metric(.userBytes, value: 1.5e9, uid: "501", username: "alice", ts: now),
        ])
        let engine = AlertEngine(thresholds: AlertThresholds(
            userGrowthWindow: 600, userGrowthThreshold: 5e9
        ))

        let events = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)
        #expect(events.isEmpty)
    }

    // MARK: - Health

    @Test("health.smart_ok == 0 fires a critical health alert")
    func smartFailure() throws {
        let store = InMemoryMetricStore()
        try store.write([metric(.smartOK, value: 0)])

        let events = try AlertEngine().evaluate(store: store, host: host, volumes: [volume], now: now)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.severity == .critical)
        #expect(event.category == "health")
        #expect(event.message.contains("SMART"))
    }

    @Test("health.writable == 0 fires a critical health alert")
    func readOnlyVolume() throws {
        let store = InMemoryMetricStore()
        try store.write([metric(.writable, value: 0)])

        let events = try AlertEngine().evaluate(store: store, host: host, volumes: [volume], now: now)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.severity == .critical)
        #expect(event.category == "health")
        #expect(event.message.contains("not writable"))
    }

    @Test("nfs.mount_ok == 0 fires a critical nfs alert")
    func nfsMountDown() throws {
        let store = InMemoryMetricStore()
        try store.write([metric(.nfsMountOK, value: 0)])

        let events = try AlertEngine().evaluate(store: store, host: host, volumes: [volume], now: now)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.severity == .critical)
        #expect(event.category == "nfs")
        #expect(event.message.contains("NFS mount appears to be down"))
    }

    // MARK: - Throughput stall

    @Test("throughput older than the stall window fires a performance warning")
    func throughputStall() throws {
        let store = InMemoryMetricStore()
        try store.write([
            metric(.throughputGbps, value: 0.05, ts: now.addingTimeInterval(-300)),
        ])
        let engine = AlertEngine(thresholds: AlertThresholds(throughputStallSeconds: 120))

        let events = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.severity == .warning)
        #expect(event.category == "performance")
        #expect(event.message.contains("no I/O throughput samples"))
    }

    @Test("a fresh throughput sample does not fire")
    func freshThroughput() throws {
        let store = InMemoryMetricStore()
        try store.write([
            metric(.throughputGbps, value: 0.05, ts: now.addingTimeInterval(-30)),
        ])
        let engine = AlertEngine(thresholds: AlertThresholds(throughputStallSeconds: 120))

        let events = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)
        #expect(events.isEmpty)
    }

    // MARK: - Cooldown

    @Test("cooldown suppresses an identical alert but not a new volume or uid")
    func cooldownSuppression() throws {
        let store = InMemoryMetricStore()
        let engine = AlertEngine(thresholds: AlertThresholds(cooldown: 3600))

        // Capacity critical on "/" fires, is persisted (as the service would),
        // then is suppressed while that persisted event is inside cooldown.
        try store.write([metric(.usedPct, value: 97.5)])
        let first = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)
        #expect(first.count == 1)
        let firstEvent = try #require(first.first)
        try store.write(firstEvent)

        let repeated = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)
        #expect(repeated.isEmpty)

        // The same condition on a different volume still fires.
        let dataVolume = "/data"
        try store.write([metric(.usedPct, volume: dataVolume, value: 97.5)])
        let byVolume = try engine.evaluate(
            store: store, host: host, volumes: [volume, dataVolume], now: now
        )
        #expect(byVolume.count == 1)
        #expect(byVolume.first?.volume == dataVolume)

        // A user-growth spike for uid 501 fires and then cools down; a spike
        // for uid 502 is a distinct rule key and still fires.
        try store.write(growthMetrics(uid: "501", username: "alice"))
        let alice = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)
        #expect(alice.count == 1)
        #expect(alice.first?.uid == "501")
        let aliceEvent = try #require(alice.first)
        try store.write(aliceEvent)

        let aliceRepeated = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)
        #expect(aliceRepeated.isEmpty)

        try store.write(growthMetrics(uid: "502", username: "bob"))
        let bob = try engine.evaluate(store: store, host: host, volumes: [volume], now: now)
        #expect(bob.count == 1)
        #expect(bob.first?.uid == "502")
    }
}
