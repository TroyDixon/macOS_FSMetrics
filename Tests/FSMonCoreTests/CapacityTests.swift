import XCTest
import Darwin
@testable import FSMonCore

final class CapacityFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db: Database
    let source = FakeFilesystemSource()
    let inventory = MountInventoryStore()
    let statuses = SamplerStatusStore()
    let log = Logger(level: .error)
    init() throws { db = try Database(path: directory.appendingPathComponent("test.db").path) }
    deinit { try? db.close(); try? FileManager.default.removeItem(at: directory) }
    func collect(_ ts: Int64 = 120) throws -> SamplerOutcome {
        try CapacitySampler(source: source, inventory: inventory).collect(context(ts))
    }
    func context(_ ts: Int64) -> SampleContext { SampleContext(ts: ts, monotonicNanos: 1, db: db, log: log) }
    func router(now: Int64 = 120) -> Router {
        let router = Router(log: log)
        CapacityRoutes.register(on: router, db: db, inventory: inventory, statuses: statuses, now: { now }, uptime: { 42 })
        return router
    }
}

final class FakeFilesystemSource: FilesystemSource {
    var mounts: [MountReading] = []
    var refreshed: [String: MountReading] = [:]
    var attrs: [String: VolumeAttributes] = [:]
    var containers: [String: ContainerIdentity] = [:]
    var refreshCalls: [String] = []
    var attributeCalls: [String] = []
    var refreshFailures: Set<String> = []
    var enumerationFails = false
    func cachedMounts() throws -> [MountReading] {
        if enumerationFails { throw FilesystemFailure(description: "enumeration failed") }
        return mounts
    }
    func refreshLocal(_ mount: MountReading) throws -> MountReading {
        refreshCalls.append(mount.path)
        if refreshFailures.contains(mount.path) { throw FilesystemFailure(description: "refresh failed") }
        return refreshed[mount.path] ?? mount
    }
    func attributes(_ mount: MountReading) throws -> VolumeAttributes {
        attributeCalls.append(mount.path)
        guard let attributes = attrs[mount.path] else { throw FilesystemFailure(description: "attributes unsupported") }
        return attributes
    }
    func apfsContainersByVolumeUUID() throws -> [String: ContainerIdentity] { containers }
}

func testMount(_ path: String = "/test", device: String = "/dev/disk10s1", fs: String = "apfs",
               remote: Bool = false, blocks: UInt64 = 1000, free: UInt64 = 600, available: UInt64 = 500,
               files: UInt64 = 10) -> MountReading {
    MountReading(path: path, device: device, fsType: fs, flags: remote ? 0 : UInt32(MNT_LOCAL),
                 blockSize: 4096, blocks: blocks, freeBlocks: free, availableBlocks: available, files: files, freeFiles: 4)
}

final class CapacityTests: XCTestCase {
    func testPackedAttributesFollowKernelOrderAndValidateBounds() throws {
        // Byte layout captured with a combined getattrlist request on this Mac.
        // 4-byte length, 20-byte returned attrs, 8-byte SPACEUSED, 8-byte NAME
        // reference, 16-byte UUID, then NUL-terminated variable-length name.
        let hex = "40000000 00000080 00208400 00000000 00000000 00000000 00606fb8 2b000000 18000000 05000000 0b12b925 94fa4986 8743cea4 ef9c4acc 44617461 00000000"
        let compact = hex.replacingOccurrences(of: " ", with: "")
        var data = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            data.append(UInt8(compact[index..<next], radix: 16)!)
            index = next
        }
        let attributes = try VolumeAttributes.decode(data)
        XCTAssertEqual(attributes.usedBytes, 187_777_900_544)
        XCTAssertEqual(attributes.name, "Data")
        XCTAssertEqual(attributes.uuid, "0B12B925-94FA-4986-8743-CEA4EF9C4ACC")
        XCTAssertThrowsError(try VolumeAttributes.decode(data.prefix(20)))
        data[32] = 255
        XCTAssertThrowsError(try VolumeAttributes.decode(data))
    }

    func testFreshLocalCapacityAndRemoteNeverCallsFilesystem() throws {
        let f = try CapacityFixture()
        f.source.mounts = [testMount(), testMount("/nfs", device: "server:/share", fs: "nfs", remote: true),
                           // Even a contradictory local flag must not enable a
                           // path call on a known network filesystem type.
                           testMount("/smb", device: "//server/share", fs: "smbfs"),
                           testMount("/dev", fs: "devfs"), testMount("/home", fs: "autofs")]
        f.source.refreshed["/test"] = testMount(free: 550, available: 450)
        f.source.attrs["/test"] = VolumeAttributes(usedBytes: 123456, uuid: "UUID-A", name: "Test")
        // Map the local APFS volume to a container so the only possible issue would come
        // from the remote mounts: cached remote numbers are expected, not a health fault.
        f.source.containers = ["UUID-A": ContainerIdentity(uuid: "CONTAINER-A", bsdName: "disk10")]
        XCTAssertEqual(try f.collect(), .ok)
        XCTAssertEqual(f.source.refreshCalls, ["/test"])
        XCTAssertEqual(f.source.attributeCalls, ["/test"])
        let rows = try f.db.read { try $0.query("SELECT m.mount_point, c.* FROM mounts m JOIN capacity_samples c ON c.mount_id = m.id ORDER BY m.mount_point") }
        XCTAssertEqual(rows.count, 3)
        let local = try XCTUnwrap(rows.first { $0["mount_point"] == .text("/test") })
        XCTAssertEqual(local["used_bytes"], .integer(123456))
        XCTAssertEqual(local["free_bytes"], .integer(550 * 4096))
        XCTAssertEqual(rows.first?["used_bytes"], .integer(400 * 4096))
    }

    func testMountIdentityIncludesPathAndNullUUIDDoesNotDuplicate() throws {
        let f = try CapacityFixture()
        f.source.mounts = [testMount("/first"), testMount("/second"), testMount("/nfs", fs: "nfs", remote: true)]
        f.source.attrs["/first"] = VolumeAttributes(usedBytes: 5, uuid: "SAME-UUID", name: "One")
        f.source.attrs["/second"] = f.source.attrs["/first"]
        _ = try f.collect(120)
        let firstIDs = f.inventory.snapshot()!.ids
        _ = try f.collect(125)
        XCTAssertEqual(f.inventory.snapshot()!.ids, firstIDs)
        XCTAssertEqual(Set(firstIDs).count, 3)
        XCTAssertEqual(try f.db.read { try $0.query("SELECT count(*) AS n FROM mounts").first?["n"] }, .integer(3))
        // A volume replaced at the same path gets a distinct identity.
        f.source.attrs["/first"] = VolumeAttributes(usedBytes: 6, uuid: "NEW-UUID", name: "Two")
        _ = try f.collect(130)
        XCTAssertNotEqual(f.inventory.snapshot()!.ids[0], firstIDs[0])
    }

    func testAttributeFailurePreservesIdentityAndSkipsMisleadingAPFSSample() throws {
        let f = try CapacityFixture()
        f.source.mounts = [testMount()]
        f.source.attrs["/test"] = VolumeAttributes(usedBytes: 7, uuid: "UUID-A", name: "Test")
        _ = try f.collect(120)
        let ids = f.inventory.snapshot()!.ids
        f.source.attrs = [:]
        XCTAssertNotEqual(try f.collect(125), .ok)
        XCTAssertEqual(f.inventory.snapshot()!.ids, ids)
        XCTAssertEqual(try f.db.read { try $0.query("SELECT count(*) AS n FROM capacity_samples").first?["n"] }, .integer(1))
    }

    func testNonAPFSFallbackAndInvalidCounters() throws {
        let value = try CapacityReading(mount: testMount(fs: "exfat", files: 0), attributes: nil)
        XCTAssertEqual(value.used, 400 * 4096)
        XCTAssertNil(value.inodesTotal)
        XCTAssertThrowsError(try CapacityReading(mount: testMount(blocks: .max), attributes: nil))
        XCTAssertThrowsError(try CapacityReading(mount: testMount(blocks: 10, free: 11), attributes: nil))
    }

    func testDetachPublishesEmptyInventoryAndRetainsHistory() throws {
        let f = try CapacityFixture()
        f.source.mounts = [testMount()]
        f.source.attrs["/test"] = VolumeAttributes(usedBytes: 7, uuid: "UUID-A", name: "Test")
        _ = try f.collect(120)
        f.source.mounts = []
        _ = try f.collect(125)
        XCTAssertEqual(f.inventory.snapshot()?.ids, [])
        XCTAssertEqual(try f.db.read { try $0.query("SELECT count(*) AS n FROM mounts").first?["n"] }, .integer(1))
        XCTAssertEqual(try f.db.read { try $0.query("SELECT count(*) AS n FROM capacity_samples").first?["n"] }, .integer(1))
    }
}
