import Foundation
import Testing

import FSMetricsCore

/// Which `MetricStore` adapter the conformance suite is exercising.
enum StoreKind: String, CaseIterable, Sendable {
    case inMemory
    case sqlite
}

/// One suite both store adapters must pass, so their `MetricSink` /
/// `MetricQuery` behavior stays interchangeable.
@Suite("MetricStore conformance")
struct StoreConformanceTests {
    private let host = "test-host"

    /// Runs `body` against a fresh store of `kind`. The on-disk store gets its
    /// own temporary directory, which is closed and removed afterwards.
    private func withStore<T>(
        _ kind: StoreKind,
        _ body: (any MetricStore) throws -> T
    ) throws -> T {
        switch kind {
        case .inMemory:
            return try body(InMemoryMetricStore())
        case .sqlite:
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FSMetricsConformance-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = try SQLiteMetricStore(url: directory.appendingPathComponent("metrics.sqlite"))
            defer { try? store.close() }
            return try body(store)
        }
    }

    private func metric(
        _ kind: MetricKind = .usedPct,
        volume: String = "vol1",
        value: Double,
        uid: String? = nil,
        username: String? = nil,
        ts: TimeInterval
    ) -> Metric {
        Metric(
            kind: kind,
            host: host,
            volume: volume,
            value: value,
            uid: uid,
            username: username,
            ts: Date(timeIntervalSince1970: ts)
        )
    }

    private func alert(
        severity: AlertEvent.Severity = .warning,
        category: String = "capacity",
        message: String,
        volume: String = "vol1",
        uid: String? = nil,
        ts: TimeInterval
    ) -> AlertEvent {
        AlertEvent(
            severity: severity,
            category: category,
            message: message,
            host: host,
            volume: volume,
            uid: uid,
            ts: Date(timeIntervalSince1970: ts)
        )
    }

    // MARK: - MetricQuery

    @Test("latest returns the newest sample; uid filters only when provided",
          arguments: StoreKind.allCases)
    func latest(kind: StoreKind) throws {
        try withStore(kind) { store in
            try store.write([
                metric(value: 10, uid: "501", username: "alice", ts: 1_000),
                metric(value: 20, uid: nil, ts: 2_000),
                metric(value: 30, uid: "502", username: "bob", ts: 3_000),
            ])

            let unfiltered = try store.latest(of: .usedPct, volume: "vol1", uid: nil)
            #expect(unfiltered?.ts == Date(timeIntervalSince1970: 3_000))
            #expect(unfiltered?.value == 30)
            #expect(unfiltered?.uid == "502")
            #expect(unfiltered?.username == "bob")

            let alice = try store.latest(of: .usedPct, volume: "vol1", uid: "501")
            #expect(alice?.ts == Date(timeIntervalSince1970: 1_000))
            #expect(alice?.value == 10)
            #expect(alice?.username == "alice")

            let bob = try store.latest(of: .usedPct, volume: "vol1", uid: "502")
            #expect(bob?.ts == Date(timeIntervalSince1970: 3_000))

            let unknownUID = try store.latest(of: .usedPct, volume: "vol1", uid: "999")
            #expect(unknownUID == nil)

            let wrongKind = try store.latest(of: .freeBytes, volume: "vol1", uid: nil)
            #expect(wrongKind == nil)

            let wrongVolume = try store.latest(of: .usedPct, volume: "missing", uid: nil)
            #expect(wrongVolume == nil)
        }
    }

    @Test("series returns samples at or after the cutoff, oldest first",
          arguments: StoreKind.allCases)
    func series(kind: StoreKind) throws {
        try withStore(kind) { store in
            try store.write([
                metric(value: 10, ts: 1_000),
                metric(value: 20, ts: 2_000),
                metric(value: 30, uid: "501", username: "alice", ts: 3_000),
                metric(.freeBytes, value: 999, ts: 2_500),
                metric(volume: "other", value: 99, ts: 3_500),
            ])

            let samples = try store.series(
                of: .usedPct,
                volume: "vol1",
                since: Date(timeIntervalSince1970: 2_000)
            )
            #expect(samples.map(\.value) == [20, 30])
            #expect(samples.map(\.ts) == [
                Date(timeIntervalSince1970: 2_000),
                Date(timeIntervalSince1970: 3_000),
            ])
            #expect(samples.last?.uid == "501")
            #expect(samples.last?.username == "alice")

            let none = try store.series(
                of: .usedPct,
                volume: "vol1",
                since: Date(timeIntervalSince1970: 4_000)
            )
            #expect(none.isEmpty)
        }
    }

    @Test("volumes returns distinct volume names", arguments: StoreKind.allCases)
    func volumes(kind: StoreKind) throws {
        try withStore(kind) { store in
            try store.write([
                metric(volume: "volA", value: 1, ts: 1_000),
                metric(volume: "volB", value: 2, ts: 1_000),
                metric(volume: "volA", value: 3, ts: 2_000),
            ])
            #expect(Set(try store.volumes()) == ["volA", "volB"])
        }
    }

    @Test("recentAlerts returns the newest alerts first, up to the limit",
          arguments: StoreKind.allCases)
    func recentAlerts(kind: StoreKind) throws {
        try withStore(kind) { store in
            try store.write(alert(message: "first", ts: 1_000))
            try store.write(alert(
                severity: .critical, category: "health", message: "second",
                uid: "501", ts: 2_000
            ))
            try store.write(alert(message: "third", ts: 3_000))

            let recent = try store.recentAlerts(limit: 2)
            #expect(recent.map(\.message) == ["third", "second"])
            #expect(recent.map(\.ts) == [
                Date(timeIntervalSince1970: 3_000),
                Date(timeIntervalSince1970: 2_000),
            ])
            #expect(recent.first?.severity == .warning)
            #expect(recent.first?.host == host)
            #expect(recent.first?.uid == nil)
            #expect(recent.last?.severity == .critical)
            #expect(recent.last?.category == "health")
            #expect(recent.last?.uid == "501")

            let empty = try store.recentAlerts(limit: 0)
            #expect(empty.isEmpty)
        }
    }

    // MARK: - MetricSink

    @Test("writing an empty metric batch is a no-op", arguments: StoreKind.allCases)
    func emptyWrite(kind: StoreKind) throws {
        try withStore(kind) { store in
            try store.write([])
            let volumes = try store.volumes()
            #expect(volumes.isEmpty)
            let alerts = try store.recentAlerts(limit: 10)
            #expect(alerts.isEmpty)
            let latest = try store.latest(of: .usedPct, volume: "vol1", uid: nil)
            #expect(latest == nil)
        }
    }
}
