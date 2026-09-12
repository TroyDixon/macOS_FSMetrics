import Foundation
import Testing

import FSMetricsCore

@Suite("CapacityCollector")
struct CapacityCollectorTests {
    private let host = "mac-mini"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// Builds the real temp tree from `tests/test_capacity.py`: `a.txt` with
    /// 1000 bytes and `sub/b.txt` with 2500 bytes, owned by the current uid.
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSMetricsCapacity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x61, count: 1000).write(to: root.appendingPathComponent("a.txt"))
        try Data(repeating: 0x62, count: 2500)
            .write(to: root.appendingPathComponent("sub/b.txt"))
        return root
    }

    @Test("real temp tree aggregates 3500 bytes to the current uid")
    func usageTotals() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = CapacityCollector(
            volumePath: root.path,
            scanPaths: [root.path],
            scanner: FileManagerScanner()
        )
        let metrics = try collector.sample(host: host, now: now)

        let uid = getuid()
        #expect(metrics.count == 1)
        let metric = try #require(metrics.first)
        #expect(metric.kind == .userBytes)
        #expect(metric.uid == String(uid))
        #expect(metric.username == username(forUID: uid))
        #expect(metric.value == 3500)
        #expect(metric.volume == root.path)
        #expect(metric.ts == now)
    }

    @Test("a missing scan path degrades to no metrics")
    func missingPath() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("does-not-exist").path
        let scanner = FileManagerScanner()
        #expect(try scanner.usageByUID(paths: [missing], followSymlinks: false).isEmpty)

        let collector = CapacityCollector(
            volumePath: root.path, scanPaths: [missing], scanner: scanner
        )
        #expect(try collector.sample(host: host, now: now).isEmpty)
    }

    @Test("largestPaths keeps a bounded, descending top-N")
    func largestPaths() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = FileManagerScanner()
        let top = try scanner.largestPaths(paths: [root.path], topN: 5)
        #expect(top.count == 2)
        #expect(top.map(\.1) == [2500, 1000])
        #expect(top.first?.0.hasSuffix("sub/b.txt") == true)

        let single = try scanner.largestPaths(paths: [root.path], topN: 1)
        #expect(single.count == 1)
        #expect(single.first?.1 == 2500)
    }

    @Test("username falls back to the numeric string for an unknown uid")
    func usernameFallback() {
        #expect(username(forUID: uid_t(2_147_483_648)) == "2147483648")
    }
}
