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

/// Forced failure used to exercise the collectors' fallback paths.
private struct SourceFailure: Error {}

@Suite("PerformanceCollector")
struct PerformanceCollectorTests {
    private let host = "mac-mini"
    private let volume = "/Volumes/Data"
    private let disk = "disk0"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func byKind(_ metrics: [Metric]) -> [MetricKind: Metric] {
        Dictionary(metrics.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The recorded `iostat -d -c 2 disk0` output; one fixture serves both
    /// samples the probe reports.
    private func iostatCommands() throws -> FixtureCommandRunner {
        let iostat = try fixtureData("iostat_sample", "txt")
        return FixtureCommandRunner(fixtures: [
            FixtureCommandRunner.key("iostat", ["-d", "-c", "2", disk]): iostat,
        ])
    }

    /// A runner with no registered fixtures, so every probe throws.
    private func noCommands() -> FixtureCommandRunner {
        FixtureCommandRunner(fixtures: [String: Data]())
    }

    @Test("iostat fallback reports SI GB/s, tps and KB/t from the last fixture row")
    func iostatFallback() throws {
        let stats = FixtureBlockStatsSource(error: SourceFailure())
        let collector = PerformanceCollector(
            volumePath: volume, diskID: disk, stats: stats, commands: try iostatCommands()
        )

        let metrics = try collector.sample(host: host, now: now)
        let kinds = byKind(metrics)

        #expect(metrics.count == 3)
        #expect(kinds[.transfersPerSec]?.value == 91)
        #expect(kinds[.kbPerTransfer]?.value == 512.02)

        // macOS iostat "MB/s" is MiB/s: 45.60 MiB/s = 0.0478150656 SI GB/s.
        let expectedGbps = 45.60 * 1_048_576 / 1_000_000_000
        let actualGbps = try #require(kinds[.throughputGbps]?.value)
        #expect(abs(actualGbps - expectedGbps) <= 1e-9)

        for metric in metrics {
            #expect(metric.host == host)
            #expect(metric.volume == volume)
            #expect(metric.ts == now)
            #expect(metric.uid == nil)
        }
    }

    @Test("IOKit counters diff over elapsed time while iostat still supplies tps and KB/t")
    func iokitRate() throws {
        let stats = FixtureBlockStatsSource(
            counters: [disk: BlockCounters(bytesRead: 1_000_000, bytesWritten: 500_000)]
        )
        let collector = PerformanceCollector(
            volumePath: volume, diskID: disk, stats: stats, commands: try iostatCommands()
        )

        let first = try collector.sample(host: host, now: now)
        // A single cumulative reading yields no IOKit rate, so the iostat
        // fallback supplies throughput for this pass.
        let firstGbps = try #require(byKind(first)[.throughputGbps]?.value)
        #expect(abs(firstGbps - 45.60 * 1_048_576 / 1_000_000_000) <= 1e-9)
        #expect(byKind(first)[.transfersPerSec]?.value == 91)

        stats.setCounters(
            BlockCounters(bytesRead: 3_000_000, bytesWritten: 1_000_000), for: disk
        )
        let second = try collector.sample(host: host, now: now.addingTimeInterval(2))
        let kinds = byKind(second)

        let deltaBytes = Double((3_000_000 - 1_000_000) + (1_000_000 - 500_000))
        #expect(kinds[.throughputGbps]?.value == deltaBytes / 2 / 1_000_000_000)
        #expect(kinds[.throughputGbps]?.value == 0.00125)
        #expect(kinds[.transfersPerSec]?.value == 91)
        #expect(kinds[.kbPerTransfer]?.value == 512.02)
        #expect(second.count == 3)
    }

    @Test("counter reset and zero elapsed time emit no throughput")
    func counterResetAndZeroTime() throws {
        let stats = FixtureBlockStatsSource(
            counters: [disk: BlockCounters(bytesRead: 5_000, bytesWritten: 5_000)]
        )
        let collector = PerformanceCollector(
            volumePath: volume, diskID: disk, stats: stats,
            commands: noCommands()
        )

        _ = try collector.sample(host: host, now: now)

        // Counter reset: a negative delta is discarded.
        stats.setCounters(BlockCounters(bytesRead: 1_000, bytesWritten: 1_000), for: disk)
        #expect(try collector.sample(host: host, now: now.addingTimeInterval(1)).isEmpty)

        // Zero elapsed time is discarded even with a positive delta.
        stats.setCounters(BlockCounters(bytesRead: 2_000, bytesWritten: 2_000), for: disk)
        #expect(try collector.sample(host: host, now: now.addingTimeInterval(1)).isEmpty)
    }

    @Test("both sources failing yields no metrics")
    func bothFail() throws {
        let stats = FixtureBlockStatsSource(error: SourceFailure())
        let collector = PerformanceCollector(
            volumePath: volume, diskID: disk, stats: stats,
            commands: noCommands()
        )
        #expect(try collector.sample(host: host, now: now).isEmpty)
    }

    @Test("IOKit adapter reports an unmatched device as CommandError instead of crashing")
    func ioKitUnknownDevice() {
        #expect(throws: CommandError.self) {
            _ = try IOKitBlockStats().counters(device: "fsmetrics-no-such-device")
        }
    }
}
