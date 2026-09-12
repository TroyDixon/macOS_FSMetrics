import Foundation
import Testing

import FSMetricsCore

/// Loads recorded command output from the test bundle's `Fixtures` directory.
private func fixtureData(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

/// Forced failure that sends ``PerformanceCollector`` down the iostat path.
private struct SourceFailure: Error {}

/// End-to-end golden cycle: one `CollectorService.runOnce()` driving all
/// fixture-backed collectors, the in-memory store, and the real alert engine.
/// This is the complete `[Metric]` + `[AlertEvent]` assertion Python lacked.
@Suite("Golden cycle")
struct GoldenCycleTests {
    private let host = "mac-mini"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// `a.txt` (1000 bytes) and `sub/b.txt` (2500 bytes), owned by the
    /// current uid.
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSMetricsGolden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x61, count: 1000).write(to: root.appendingPathComponent("a.txt"))
        try Data(repeating: 0x62, count: 2500)
            .write(to: root.appendingPathComponent("sub/b.txt"))
        return root
    }

    /// Reads back every persisted metric: one `series` call per
    /// (volume, kind), since the query seam has no "all metrics" read.
    private func storedSamples(
        in store: any MetricQuery
    ) throws -> [(kind: MetricKind, volume: String, sample: Sample)] {
        var result: [(kind: MetricKind, volume: String, sample: Sample)] = []
        for volume in try store.volumes() {
            for kind in MetricKind.allCases {
                for sample in try store.series(of: kind, volume: volume, since: .distantPast) {
                    result.append((kind: kind, volume: volume, sample: sample))
                }
            }
        }
        return result
    }

    @Test("one runOnce produces the complete metric set and the capacity warning")
    func goldenCycle() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let diskutil = try fixtureData("diskutil_info", "plist")
        let iostat = try fixtureData("iostat_sample", "txt")
        let nfsstat = try fixtureData("nfsstat_m_sample", "txt")
        let commands = FixtureCommandRunner(fixtures: [
            FixtureCommandRunner.key("diskutil", ["info", "-plist", "/"]): diskutil,
            FixtureCommandRunner.key("iostat", ["-d", "-c", "2", "disk0"]): iostat,
            FixtureCommandRunner.key("nfsstat", ["-m"]): nfsstat,
        ])

        // The pNFS mount the collector sees is the one the recorded
        // `nfsstat -m` output describes, served through the fixture tool.
        let mounts = try NfsstatTool(commands: commands).mounts()
        let research = try #require(mounts.first { $0.mountPoint == "/Volumes/Research" })
        #expect(research.pnfs)

        let store = InMemoryMetricStore()
        let volumeSource = StaticVolumeSource(paths: [
            (path: "/", kind: .apfs, label: "Macintosh HD"),
            (path: "/Volumes/Research", kind: .nfs, label: "Research"),
        ])
        // Warn at 50 so the diskutil fixture's 63.31% fires exactly one
        // warning; crit stays at the default 95.
        let thresholds = AlertThresholds(capacityPctWarn: 50)

        let collectors: [any Collector] = [
            HealthCollector(
                volumePath: "/",
                probe: DiskUtilProbe(commands: commands)
            ),
            PerformanceCollector(
                volumePath: "/",
                diskID: "disk0",
                stats: FixtureBlockStatsSource(counters: [:], error: SourceFailure()),
                commands: commands
            ),
            NFSCollector(
                volumePath: research.mountPoint,
                mountPoint: research.mountPoint,
                tool: FixtureNFSTool(mounts: [research])
            ),
        ]
        let capacityCollectors: [any Collector] = [
            CapacityCollector(
                volumePath: "/",
                scanPaths: [tree.path],
                scanner: FileManagerScanner()
            ),
        ]

        let service = CollectorService(
            settings: Settings(hostLabel: host, thresholds: thresholds),
            store: store,
            volumes: volumeSource,
            collectors: collectors,
            capacityCollectors: capacityCollectors,
            engine: AlertEngine(thresholds: thresholds),
            notifier: NoopNotifier(),
            clock: TestClock(now: now)
        )
        try await service.runOnce()

        // The complete persisted metric set, read back through `MetricQuery`.
        let stored = try storedSamples(in: store)
        let expectedKinds: [MetricKind] = [
            .smartOK, .writable, .totalBytes, .usedBytes, .freeBytes, .usedPct,
            .throughputGbps, .transfersPerSec, .kbPerTransfer,
            .nfsMountOK, .pnfsEnabled,
            .userBytes,
        ]
        #expect(stored.count == expectedKinds.count)
        #expect(Set(stored.map(\.kind)) == Set(expectedKinds))
        #expect(stored.allSatisfy { $0.sample.ts == now })

        let byKind = Dictionary(
            stored.map { ($0.kind, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Six health/capacity metrics from the diskutil fixture, on "/".
        #expect(byKind[.smartOK]?.volume == "/")
        #expect(byKind[.smartOK]?.sample.value == 1)
        #expect(byKind[.writable]?.volume == "/")
        #expect(byKind[.writable]?.sample.value == 1)
        #expect(byKind[.totalBytes]?.volume == "/")
        #expect(byKind[.totalBytes]?.sample.value == 2_000_398_934_016)
        #expect(byKind[.usedBytes]?.volume == "/")
        #expect(byKind[.usedBytes]?.sample.value == 1_266_395_078_656)
        #expect(byKind[.freeBytes]?.volume == "/")
        #expect(byKind[.freeBytes]?.sample.value == 734_003_855_360)
        #expect(byKind[.usedPct]?.volume == "/")
        #expect(byKind[.usedPct]?.sample.value == 63.31)

        // Three iostat fallback performance metrics on "/".
        #expect(byKind[.throughputGbps]?.volume == "/")
        let gbps = try #require(byKind[.throughputGbps]?.sample.value)
        let expectedGbps = 45.60 * 1_048_576 / 1_000_000_000
        #expect(abs(gbps - expectedGbps) <= 1e-9)
        #expect(byKind[.transfersPerSec]?.volume == "/")
        #expect(byKind[.transfersPerSec]?.sample.value == 91)
        #expect(byKind[.kbPerTransfer]?.volume == "/")
        #expect(byKind[.kbPerTransfer]?.sample.value == 512.02)

        // One per-user capacity metric for the temp tree on "/".
        let user = try #require(byKind[.userBytes])
        #expect(user.volume == "/")
        #expect(user.sample.uid == String(getuid()))
        #expect(user.sample.username == username(forUID: getuid()))
        #expect(user.sample.value == 3500)

        // Two NFS metrics for the pNFS mount.
        #expect(byKind[.nfsMountOK]?.volume == "/Volumes/Research")
        #expect(byKind[.nfsMountOK]?.sample.value == 1)
        #expect(byKind[.pnfsEnabled]?.volume == "/Volumes/Research")
        #expect(byKind[.pnfsEnabled]?.sample.value == 1)

        // Exactly one persisted alert: 63.31 >= warn 50, below crit 95.
        let alerts = try store.recentAlerts(limit: 10)
        #expect(alerts.count == 1)
        let alert = try #require(alerts.first)
        #expect(alert.severity == .warning)
        #expect(alert.category == "capacity")
        #expect(alert.volume == "/")
        #expect(alert.uid == nil)
        #expect(alert.ts == now)
        #expect(alert.message.contains("63.3"))
        #expect(alert.message.contains("warn threshold"))

        // Both configured volumes were written.
        let volumes = try store.volumes()
        #expect(volumes.contains("/"))
        #expect(volumes.contains("/Volumes/Research"))
    }
}
