import Foundation
import Testing

import FSMetricsCore

/// Parses a whitespace-separated hex dump into bytes.
private func bytes(fromHex hex: String) -> Data {
    let compact = hex.filter { !$0.isWhitespace }
    var data = Data()
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        data.append(UInt8(compact[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private struct CapacityFailure: Error {}

@Suite("Volume capacity")
struct VolumeCapacityTests {
    /// `getattrlist` reply for `/System/Volumes/Data`, captured on macOS 26.5
    /// with the exact request `SystemCapacitySource` makes. `df -k` reported
    /// 190_154_584_064 bytes used in the same second.
    private let dataVolumeBuffer = bytes(fromHex: """
        40000000 00000080 00208400 00000000 00000000 00000000
        00a01846 2c000000 18000000 05000000
        0b12b925 94fa4986 8743cea4 ef9c4acc 44617461 00000000
        """)

    /// Same request against `/` (the sealed system snapshot): a longer name.
    /// `df -k` reported exactly 17_088_548_864 bytes used.
    private let rootVolumeBuffer = bytes(fromHex: """
        48000000 00000080 00208400 00000000 00000000 00000000
        00908efa 03000000 18000000 0d000000
        8da787c5 3cd64e68 a068cbe1 eef3098f 4d616369 6e746f73 68204844 00000000
        """)

    private let host = "mac-mini"
    private let volume = "/System/Volumes/Data"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - getattrlist decoding

    @Test("SPACEUSED is decoded from before NAME and UUID in the packed buffer")
    func decodesCapturedBuffers() throws {
        let data = try VolumeAttributes.decode(dataVolumeBuffer)
        #expect(data.spaceUsed == 190_154_579_968)
        #expect(data.name == "Data")
        #expect(data.uuid == "0B12B925-94FA-4986-8743-CEA4EF9C4ACC")

        let root = try VolumeAttributes.decode(rootVolumeBuffer)
        #expect(root.spaceUsed == 17_088_548_864)
        #expect(root.name == "Macintosh HD")
        #expect(root.uuid == "8DA787C5-3CD6-4E68-A068-CBE1EEF3098F")
    }

    @Test("truncated buffers and out-of-bounds name references throw")
    func rejectsMalformedBuffers() {
        #expect(throws: CapacityError.self) {
            _ = try VolumeAttributes.decode(dataVolumeBuffer.prefix(20))
        }
        var corrupted = dataVolumeBuffer
        corrupted[32] = 0xFF
        #expect(throws: CapacityError.self) {
            _ = try VolumeAttributes.decode(corrupted)
        }
    }

    @Test("SPACEUSED missing from the returned set decodes as nil")
    func missingSpaceUsed() throws {
        var buffer = dataVolumeBuffer
        buffer[10] = 0x04 // clear ATTR_VOL_SPACEUSED (0x00800000) in the returned volattr
        let attributes = try VolumeAttributes.decode(buffer)
        #expect(attributes.spaceUsed == nil)
        #expect(attributes.name == "Data")
    }

    // MARK: - Capacity arithmetic

    @Test("APFS uses the volume's SPACEUSED with container total/free and df's used %")
    func apfsPerVolumeUsage() throws {
        // statfs counters for /System/Volumes/Data from the same capture.
        let capacity = try VolumeCapacity.fromCounters(
            filesystemType: "apfs",
            blockSize: 4096,
            blocks: 120_686_613,
            freeBlocks: 63_833_421,
            availableBlocks: 63_833_421,
            spaceUsed: 190_154_579_968
        )
        #expect(capacity.totalBytes == 494_332_366_848)
        #expect(capacity.freeBytes == 261_461_692_416)
        #expect(capacity.availableBytes == 261_461_692_416)
        #expect(capacity.usedBytes == 190_154_579_968)
        // Not the container's usage (total - free), which the old path reported.
        #expect(capacity.usedBytes != capacity.totalBytes - capacity.freeBytes)
        // used / (used + available), as df's Capacity column computes it.
        #expect(capacity.usedPct == 42.11)
    }

    @Test("APFS container usage uses total minus available")
    func apfsContainerUsage() throws {
        let capacity = try VolumeCapacity.fromCounters(
            filesystemType: "apfs",
            blockSize: 4096,
            blocks: 120_686_613,
            freeBlocks: 63_833_421,
            availableBlocks: 63_833_421,
            spaceUsed: 190_154_579_968,
            container: "disk3"
        )

        #expect(capacity.container == "disk3")
        #expect(capacity.containerUsedPct == 47.11)
    }

    @Test("APFS mounted devices map to their container")
    func containerIdentifier() {
        #expect(SystemCapacitySource.containerIdentifier(
            filesystemType: "apfs", mountSource: "/dev/disk3s5"
        ) == "disk3")
        #expect(SystemCapacitySource.containerIdentifier(
            filesystemType: "apfs", mountSource: "/dev/disk3s1s1"
        ) == "disk3")
        #expect(SystemCapacitySource.containerIdentifier(
            filesystemType: "hfs", mountSource: "/dev/disk3s5"
        ) == nil)
        #expect(SystemCapacitySource.containerIdentifier(
            filesystemType: "apfs", mountSource: "map auto_home"
        ) == nil)
    }

    @Test("APFS without SPACEUSED throws instead of reporting container usage")
    func apfsNeverFallsBack() {
        #expect(throws: CapacityError.self) {
            _ = try VolumeCapacity.fromCounters(
                filesystemType: "apfs", blockSize: 4096,
                blocks: 1_000, freeBlocks: 600, availableBlocks: 500, spaceUsed: nil
            )
        }
    }

    @Test("non-APFS without SPACEUSED uses total - free")
    func nonAPFSFallback() throws {
        let capacity = try VolumeCapacity.fromCounters(
            filesystemType: "msdos", blockSize: 4096,
            blocks: 1_000, freeBlocks: 600, availableBlocks: 500, spaceUsed: nil
        )
        #expect(capacity.usedBytes == 400 * 4096)
        #expect(capacity.usedPct == 44.44)
    }

    @Test("invalid or overflowing counters throw; wrapped negative availability clamps to 0")
    func counterValidation() throws {
        #expect(throws: CapacityError.self) {
            _ = try VolumeCapacity.fromCounters(
                filesystemType: "hfs", blockSize: 0,
                blocks: 10, freeBlocks: 5, availableBlocks: 5, spaceUsed: nil
            )
        }
        #expect(throws: CapacityError.self) {
            _ = try VolumeCapacity.fromCounters(
                filesystemType: "hfs", blockSize: 4096,
                blocks: 10, freeBlocks: 11, availableBlocks: 5, spaceUsed: nil
            )
        }
        #expect(throws: CapacityError.self) {
            _ = try VolumeCapacity.fromCounters(
                filesystemType: "hfs", blockSize: 4096,
                blocks: .max, freeBlocks: 0, availableBlocks: 0, spaceUsed: nil
            )
        }
        let wrapped = try VolumeCapacity.fromCounters(
            filesystemType: "hfs", blockSize: 4096,
            blocks: 10, freeBlocks: 1, availableBlocks: UInt64(bitPattern: -5), spaceUsed: nil
        )
        #expect(wrapped.availableBytes == 0)
        #expect(VolumeCapacity(totalBytes: 0, freeBytes: 0, availableBytes: 0, usedBytes: 0).usedPct == 0)
    }

    // MARK: - HealthCollector wiring

    @Test("a capacity reading without a container emits the original four capacity metrics")
    func collectorUsesCapacitySource() throws {
        // diskutil-style container numbers that must not reach the store.
        let probe = FixtureProbe(diskInfo: DiskInfo(totalBytes: 1_000, freeBytes: 250, usedBytes: 750))
        let source = FixtureCapacitySource(reading: VolumeCapacity(
            totalBytes: 494_332_366_848,
            freeBytes: 261_461_692_416,
            availableBytes: 261_461_692_416,
            usedBytes: 190_154_579_968
        ))

        let metrics = try HealthCollector(volumePath: volume, probe: probe, capacity: source)
            .sample(host: host, now: now)

        #expect(metrics.map(\.kind) == [.smartOK, .writable, .totalBytes, .usedBytes, .freeBytes, .usedPct])
        let byKind = Dictionary(metrics.map { ($0.kind, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(byKind[.totalBytes] == 494_332_366_848)
        #expect(byKind[.usedBytes] == 190_154_579_968)
        #expect(byKind[.freeBytes] == 261_461_692_416)
        #expect(byKind[.usedPct] == 42.11)
    }

    @Test("an APFS capacity reading appends three container metrics")
    func collectorEmitsContainerCapacity() throws {
        let probe = FixtureProbe(diskInfo: DiskInfo(totalBytes: 1_000, freeBytes: 250, usedBytes: 750))
        let source = FixtureCapacitySource(reading: VolumeCapacity(
            totalBytes: 494_332_366_848,
            freeBytes: 261_461_692_416,
            availableBytes: 261_461_692_416,
            usedBytes: 190_154_579_968,
            container: "disk3"
        ))

        let metrics = try HealthCollector(volumePath: volume, probe: probe, capacity: source)
            .sample(host: host, now: now)
        let capacityMetrics = metrics.filter { $0.kind.category == "capacity" }

        #expect(capacityMetrics.map(\.kind) == [
            .totalBytes, .usedBytes, .freeBytes, .usedPct,
            .containerTotalBytes, .containerAvailableBytes, .containerUsedPct,
        ])
        let containerMetrics = capacityMetrics.filter { $0.kind.rawValue.contains("container_") }
        #expect(containerMetrics.allSatisfy { $0.username == "disk3" })
        #expect(containerMetrics.first { $0.kind == .containerUsedPct }?.value == 47.11)
    }

    @Test("a capacity failure skips only the capacity metrics")
    func capacityFailureKeepsHealth() throws {
        let probe = FixtureProbe(diskInfo: DiskInfo(totalBytes: 1_000, freeBytes: 250, usedBytes: 750))
        let source = FixtureCapacitySource(
            reading: VolumeCapacity(totalBytes: 0, freeBytes: 0, availableBytes: 0, usedBytes: 0),
            error: CapacityFailure()
        )

        let metrics = try HealthCollector(volumePath: volume, probe: probe, capacity: source)
            .sample(host: host, now: now)

        #expect(metrics.map(\.kind) == [.smartOK, .writable])
    }

    // MARK: - Container consumers

    @Test("container percentage takes precedence for capacity alerts")
    func alertUsesContainerCapacity() throws {
        let store = InMemoryMetricStore()
        try store.write([
            Metric(kind: .usedPct, host: host, volume: "/", value: 6, ts: now),
            Metric(
                kind: .containerUsedPct, host: host, volume: "/", value: 96,
                username: "disk3", ts: now
            ),
        ])

        let events = try AlertEngine().evaluate(store: store, host: host, volumes: ["/"], now: now)

        #expect(events.count == 1)
        #expect(events.first?.severity == .critical)
        #expect(events.first?.message == "/: APFS container disk3 is 96.0% full (>= 95.0% critical threshold)")
    }

    @Test("per-volume percentage remains the alert fallback")
    func alertFallsBackToVolumeCapacity() throws {
        let store = InMemoryMetricStore()
        try store.write([
            Metric(kind: .usedPct, host: host, volume: "/", value: 96, ts: now),
        ])

        let events = try AlertEngine().evaluate(store: store, host: host, volumes: ["/"], now: now)

        #expect(events.count == 1)
        #expect(events.first?.message == "/ is 96.0% full (>= 95.0% critical threshold)")
    }

    @Test("fleet capacity counts each APFS container once")
    func fleetCapacityRollup() {
        let inputs = ["/", "/System/Volumes/Data", "/System/Volumes/VM"].map { _ in
            CapacityRollupInput(
                totalBytes: 500,
                usedBytes: 100,
                container: "disk3",
                containerTotalBytes: 500,
                containerAvailableBytes: 100
            )
        } + [
            CapacityRollupInput(totalBytes: 100, usedBytes: 25),
        ]

        let result = CapacityRollup.fleet(inputs)

        #expect(result.totalBytes == 600)
        #expect(result.usedBytes == 425)
    }

    @Test("fleet excludes remote volumes from totals")
    func fleetExcludesRemoteVolumes() {
        let inputs = [
            CapacityRollupInput(
                totalBytes: 1000,
                usedBytes: 600,
                container: "disk3",
                containerTotalBytes: 1000,
                containerAvailableBytes: 400
            ),
            CapacityRollupInput(totalBytes: 100, usedBytes: 25),
            CapacityRollupInput(totalBytes: 494, usedBytes: 303, isRemote: true),
            CapacityRollupInput(
                totalBytes: 500,
                usedBytes: 400,
                container: "disk9",
                containerTotalBytes: 500,
                containerAvailableBytes: 100,
                isRemote: true
            ),
        ]

        let result = CapacityRollup.fleet(inputs)

        #expect(result.totalBytes == 1100)
        #expect(result.usedBytes == 625)
    }

    @Test("fleet with only remote volumes has no totals")
    func fleetOnlyRemoteVolumes() {
        let inputs = [
            CapacityRollupInput(totalBytes: 494, usedBytes: 303, isRemote: true),
            CapacityRollupInput(
                totalBytes: 500,
                usedBytes: 400,
                container: "disk9",
                containerTotalBytes: 500,
                containerAvailableBytes: 100,
                isRemote: true
            ),
        ]

        let result = CapacityRollup.fleet(inputs)

        #expect(result.totalBytes == nil)
        #expect(result.usedBytes == nil)
    }

    // MARK: - Live system

    @Test("the sealed system volume reports its own usage, not its container's")
    func liveRootVolume() throws {
        let root = try SystemCapacitySource().capacity(at: "/")
        #expect(root.usedBytes > 0)
        #expect(root.usedBytes < root.totalBytes - root.freeBytes)
        #expect((0...100).contains(root.usedPct))

        let temporary = try SystemCapacitySource().capacity(at: NSTemporaryDirectory())
        #expect(temporary.usedBytes > 0)
        #expect(temporary.usedBytes <= temporary.totalBytes)
    }

    @Test("root and Data report the same live APFS container")
    func liveContainerIdentity() throws {
        let source = SystemCapacitySource()
        let root = try source.capacity(at: "/")
        let data = try source.capacity(at: "/System/Volumes/Data")

        #expect(root.container != nil)
        #expect(root.container == data.container)
        #expect(root.totalBytes == data.totalBytes)
    }
}
