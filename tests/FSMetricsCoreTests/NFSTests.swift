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

/// Forced failure exercising the best-effort client-counter path.
private struct ToolFailure: Error {}

@Suite("NFS")
struct NFSTests {
    private let host = "mac-mini"
    private let research = "/Volumes/Research"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func byKind(_ metrics: [Metric]) -> [MetricKind: Metric] {
        Dictionary(metrics.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("nfsstat -m fixture parses two mounts; only Research uses pNFS")
    func parseMountsFixture() throws {
        let raw = try fixtureData("nfsstat_m_sample", "txt")
        let tool = NfsstatTool(commands: FixtureCommandRunner(fixtures: [
            FixtureCommandRunner.key("nfsstat", ["-m"]): raw,
        ]))

        let mounts = try tool.mounts()
        #expect(mounts.count == 2)

        let researchMount = try #require(mounts.first { $0.mountPoint == research })
        #expect(researchMount.server == "fileserver.lab.local:/export/research")
        #expect(researchMount.pnfs)
        #expect(researchMount.flags == "vers=4,addr=10.20.0.12,rsize=65536,wsize=65536,pnfs,hard,intr")

        let scratch = try #require(mounts.first { $0.mountPoint == "/Volumes/Scratch" })
        #expect(scratch.server == "fileserver.lab.local:/export/scratch")
        #expect(!scratch.pnfs)
        #expect(scratch.flags == "vers=3,addr=10.20.0.12,rsize=32768,wsize=32768,soft")
    }

    @Test("client counters parse 'name: value' and 'name value', lowercased")
    func parseClientCounters() throws {
        let raw = "read: 1234\nwrite 567\ntimeout: 3\nretrans: 1\n"
        let tool = NfsstatTool(commands: FixtureCommandRunner(fixtures: [
            FixtureCommandRunner.key("nfsstat", ["-c"]): raw,
        ]))

        let counters = try tool.clientCounters()
        #expect(counters["read"] == 1234)
        #expect(counters["write"] == 567)
        #expect(counters["timeout"] == 3)
        #expect(counters["retrans"] == 1)
    }

    @Test("matching mount emits pnfs 1 + mount_ok 1 and maps client counters")
    func collectorMatch() throws {
        let mount = NFSMount(
            mountPoint: research,
            server: "fileserver.lab.local:/export/research",
            flags: "vers=4,pnfs",
            pnfs: true
        )
        let tool = FixtureNFSTool(mounts: [mount], counters: ["timeout": 3, "retrans": 1])
        let collector = NFSCollector(volumePath: research, mountPoint: research, tool: tool)

        let metrics = try collector.sample(host: host, now: now)
        let kinds = byKind(metrics)

        #expect(metrics.count == 4)
        #expect(kinds[.pnfsEnabled]?.value == 1)
        #expect(kinds[.nfsMountOK]?.value == 1)
        #expect(kinds[.nfsClientTimeouts]?.value == 3)
        #expect(kinds[.nfsClientRetransmits]?.value == 1)
        for metric in metrics {
            #expect(metric.host == host)
            #expect(metric.volume == research)
            #expect(metric.ts == now)
            #expect(metric.uid == nil)
        }
    }

    @Test("a matching mount without pNFS emits pnfs 0")
    func collectorMatchWithoutPNFS() throws {
        let mount = NFSMount(
            mountPoint: research,
            server: "fileserver.lab.local:/export/scratch",
            flags: "vers=3,soft",
            pnfs: false
        )
        let tool = FixtureNFSTool(mounts: [mount])
        let metrics = try NFSCollector(volumePath: research, mountPoint: research, tool: tool)
            .sample(host: host, now: now)
        let kinds = byKind(metrics)

        #expect(kinds[.pnfsEnabled]?.value == 0)
        #expect(kinds[.nfsMountOK]?.value == 1)
        #expect(metrics.count == 2)
    }

    @Test("a non-matching mount emits mount_ok 0 and no pnfs metric")
    func collectorNonMatch() throws {
        let tool = FixtureNFSTool(mounts: [
            NFSMount(mountPoint: "/Volumes/Other", server: "srv:/export", flags: "vers=3", pnfs: false),
        ])
        let collector = NFSCollector(volumePath: research, mountPoint: research, tool: tool)

        let metrics = try collector.sample(host: host, now: now)
        #expect(metrics.count == 1)
        #expect(metrics.first?.kind == .nfsMountOK)
        #expect(metrics.first?.value == 0)
        #expect(metrics.first?.volume == research)
        #expect(metrics.first?.ts == now)
    }

    @Test("a throwing clientCounters call is swallowed")
    func countersFailure() throws {
        let mount = NFSMount(
            mountPoint: research, server: "srv:/export", flags: "pnfs", pnfs: true
        )
        let tool = FixtureNFSTool(mounts: [mount], countersError: ToolFailure())
        let metrics = try NFSCollector(volumePath: research, mountPoint: research, tool: tool)
            .sample(host: host, now: now)

        #expect(metrics.map(\.kind) == [.pnfsEnabled, .nfsMountOK])
    }
}
