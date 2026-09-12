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

/// A probe failure used to exercise the collector's error boundaries.
private struct ProbeFailure: Error {}

/// `DiskInfo` throws, so `HealthCollector` must rethrow.
private struct DiskInfoThrowingProbe: DiagnosticsProbe {
    func diskInfo(at path: String) throws -> DiskInfo { throw ProbeFailure() }
    func nvmeHealth() throws -> [NVMEHealth] { [] }
}

@Suite("HealthCollector")
struct HealthCollectorTests {
    private let host = "mac-mini"
    private let volume = "/Volumes/Data"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func byKind(_ metrics: [Metric]) -> [MetricKind: Metric] {
        Dictionary(metrics.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("diskutil fixture produces the six values asserted by test_health.py")
    func diskutilFixture() throws {
        let xml = try fixtureData("diskutil_info", "plist")
        let commands = FixtureCommandRunner(fixtures: [
            FixtureCommandRunner.key("diskutil", ["info", "-plist", volume]): xml,
        ])
        let collector = HealthCollector(volumePath: volume, probe: DiskUtilProbe(commands: commands))

        let metrics = try collector.sample(host: host, now: now)

        // No system_profiler fixture is registered, so the best-effort NVMe
        // probe throws and contributes nothing.
        #expect(metrics.count == 6)
        let kinds = byKind(metrics)
        #expect(kinds[.smartOK]?.value == 1)
        #expect(kinds[.writable]?.value == 1)
        #expect(kinds[.totalBytes]?.value == 2_000_398_934_016)
        #expect(kinds[.freeBytes]?.value == 734_003_855_360)
        #expect(kinds[.usedBytes]?.value == 1_266_395_078_656)
        #expect(kinds[.usedPct]?.value == 63.31)

        for metric in metrics {
            #expect(metric.host == host)
            #expect(metric.volume == volume)
            #expect(metric.ts == now)
            #expect(metric.uid == nil)
        }
    }

    @Test("NVMe entries map the drive name to username and OK status to 1")
    func nvmeHealth() throws {
        let probe = FixtureProbe(
            diskInfo: DiskInfo(totalBytes: 1_000, freeBytes: 250, usedBytes: 750),
            nvme: [
                NVMEHealth(name: "APPLE SSD AP0512Z", smartStatus: "Verified"),
                NVMEHealth(name: "External NVMe", smartStatus: "Failing"),
            ]
        )
        let metrics = try HealthCollector(volumePath: volume, probe: probe)
            .sample(host: host, now: now)

        let nvme = metrics.filter { $0.kind == .nvmeSmartOK }
        #expect(nvme.count == 2)
        #expect(nvme.first?.username == "APPLE SSD AP0512Z")
        #expect(nvme.first?.value == 1)
        #expect(nvme.first?.uid == nil)
        #expect(nvme.last?.username == "External NVMe")
        #expect(nvme.last?.value == 0)
        #expect(metrics.count == 8)
    }

    @Test("zero total capacity yields used_pct 0")
    func zeroTotal() throws {
        let probe = FixtureProbe(diskInfo: DiskInfo(totalBytes: 0, freeBytes: 0, usedBytes: 0))
        let metrics = try HealthCollector(volumePath: volume, probe: probe)
            .sample(host: host, now: now)
        #expect(byKind(metrics)[.usedPct]?.value == 0)
    }

    @Test("diskInfo failures rethrow; nvme failures degrade to the six core metrics")
    func degradation() throws {
        let throwing = HealthCollector(volumePath: volume, probe: DiskInfoThrowingProbe())
        #expect(throws: ProbeFailure.self) {
            _ = try throwing.sample(host: host, now: now)
        }

        let nvmeThrowing = FixtureProbe(
            diskInfo: DiskInfo(totalBytes: 2_000, freeBytes: 500, usedBytes: 1_500),
            nvmeError: ProbeFailure()
        )
        let metrics = try HealthCollector(volumePath: volume, probe: nvmeThrowing)
            .sample(host: host, now: now)
        #expect(metrics.count == 6)
        #expect(metrics.map(\.kind) == [.smartOK, .writable, .totalBytes, .usedBytes, .freeBytes, .usedPct])
    }
}
