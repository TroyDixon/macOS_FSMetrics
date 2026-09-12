import Foundation
import Darwin

struct CapacityReading {
    let total: Int64
    let free: Int64
    let available: Int64
    let used: Int64
    let inodesTotal: Int64?
    let inodesFree: Int64?

    init(mount: MountReading, attributes: VolumeAttributes?) throws {
        func bytes(_ blocks: UInt64) throws -> Int64 {
            let result = blocks.multipliedReportingOverflow(by: mount.blockSize)
            guard !result.overflow, let value = Int64(exactly: result.partialValue) else {
                throw FilesystemFailure(description: "Capacity overflow: \(mount.path)")
            }
            return value
        }
        guard mount.blockSize > 0, mount.freeBlocks <= mount.blocks else {
            throw FilesystemFailure(description: "Invalid capacity counters: \(mount.path)")
        }
        total = try bytes(mount.blocks)
        free = try bytes(mount.freeBlocks)
        // Filesystems may represent negative availability as an unsigned value.
        available = try bytes(Int64(bitPattern: mount.availableBlocks) < 0 ? 0 : mount.availableBlocks)
        if let volumeUsed = attributes?.usedBytes {
            used = volumeUsed
        } else if mount.fsType == "apfs" {
            // Container usage is not an acceptable substitute for volume usage.
            throw FilesystemFailure(description: "Per-volume used space unavailable: \(mount.path)")
        } else {
            used = total - free
        }
        inodesTotal = mount.files == 0 ? nil : Int64(exactly: mount.files)
        inodesFree = inodesTotal == nil ? nil : Int64(exactly: mount.freeFiles)
    }
}

public final class CapacitySampler: Sampler {
    public let name = "capacity"
    public let interval: TimeInterval = 5
    private let source: FilesystemSource
    private let inventory: MountInventoryStore

    public convenience init(inventory: MountInventoryStore) {
        self.init(source: SystemFilesystemSource(), inventory: inventory)
    }
    init(source: FilesystemSource, inventory: MountInventoryStore) {
        self.source = source
        self.inventory = inventory
    }

    public func collect(_ ctx: SampleContext) throws -> SamplerOutcome {
        let mounts = try source.cachedMounts().filter(\.isReal)
        var issues: [String] = []
        var containers: [String: ContainerIdentity] = [:]
        do { containers = try source.apfsContainersByVolumeUUID() }
        catch { issues.append(String(describing: error)) }
        var observations: [(MountReading, VolumeAttributes?, CapacityReading?)] = []
        for cached in mounts {
            var mount = cached
            var attributes: VolumeAttributes?
            var capacity: CapacityReading?
            if cached.isRemote {
                // No path lookups, Foundation resource queries, statfs, or
                // getattrlist here: even a metadata lookup may block on a server.
                issues.append("Cached remote capacity: \(cached.path)")
                do { capacity = try CapacityReading(mount: cached, attributes: nil) }
                catch { issues.append(String(describing: error)) }
            } else {
                do {
                    mount = try source.refreshLocal(cached)
                    do { attributes = try source.attributes(mount) }
                    catch { issues.append(String(describing: error)) }
                    capacity = try CapacityReading(mount: mount, attributes: attributes)
                } catch { issues.append(String(describing: error)) }
            }
            observations.append((mount, attributes, capacity))
        }

        let ids = try ctx.db.write { connection -> [Int64] in
            var ids: [Int64] = []
            for (mount, attributes, capacity) in observations {
                var uuid = attributes?.uuid
                // A temporary attribute failure must not create a second identity
                // with NULL UUID for a volume that was previously identified.
                if attributes == nil && !mount.isRemote {
                    uuid = try connection.query("""
                        SELECT volume_uuid FROM mounts
                        WHERE mount_point = ? AND device_node = ? AND fs_type = ?
                        ORDER BY last_seen DESC, id DESC LIMIT 1
                        """, bindings: [.text(mount.path), .text(mount.device), .text(mount.fsType)])
                        .first?["volume_uuid"]?.string
                }
                var containerID: Int64?
                let containerBSD = ContainerIdentity.bsdName(forVolumeDevice: mount.device)
                let container = uuid.flatMap { containers[$0] } ?? containerBSD.flatMap { bsd in
                    containers.values.first { $0.bsdName == bsd }
                }
                if let container, mount.fsType == "apfs", !mount.isRemote {
                    try connection.execute("""
                        INSERT INTO containers (container_uuid, bsd_name, first_seen, last_seen)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(container_uuid) DO UPDATE SET
                          bsd_name = excluded.bsd_name,
                          last_seen = excluded.last_seen
                        """, bindings: [.text(container.uuid), container.bsdName.sql,
                                          .integer(ctx.ts), .integer(ctx.ts)])
                    containerID = try connection.query("SELECT id FROM containers WHERE container_uuid = ?",
                                                      bindings: [.text(container.uuid)]).first?["id"]?.integer
                } else if mount.fsType == "apfs" {
                    issues.append("APFS container unavailable: \(mount.path)")
                }
                let existing = try connection.query("SELECT id FROM mounts WHERE mount_point = ? AND volume_uuid IS ? ORDER BY id LIMIT 1",
                                                    bindings: [.text(mount.path), uuid.sql]).first?["id"]?.integer
                let id: Int64
                if let existing {
                    id = existing
                    try connection.execute("""
                        UPDATE mounts SET device_node = ?, fs_type = ?,
                          volume_name = COALESCE(?, volume_name), container_id = COALESCE(?, container_id),
                          is_remote = ?, read_only = ?, last_seen = ? WHERE id = ?
                        """, bindings: [.text(mount.device), .text(mount.fsType), attributes?.name.sql ?? .null,
                                          containerID.sql, .integer(mount.isRemote ? 1 : 0),
                                          .integer(mount.flags & UInt32(MNT_RDONLY) != 0 ? 1 : 0), .integer(ctx.ts), .integer(id)])
                } else {
                    try connection.execute("""
                        INSERT INTO mounts (mount_point, device_node, fs_type, volume_uuid, volume_name,
                          container_id, is_remote, read_only, first_seen, last_seen)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, bindings: [.text(mount.path), .text(mount.device), .text(mount.fsType), uuid.sql,
                                          attributes?.name.sql ?? .null, containerID.sql,
                                          .integer(mount.isRemote ? 1 : 0), .integer(mount.flags & UInt32(MNT_RDONLY) != 0 ? 1 : 0),
                                          .integer(ctx.ts), .integer(ctx.ts)])
                    id = try connection.query("SELECT last_insert_rowid() AS id").first!["id"]!.integer!
                }
                ids.append(id)
                if let capacity {
                    try connection.execute("""
                        INSERT INTO capacity_samples (ts, mount_id, total_bytes, free_bytes, available_bytes,
                          used_bytes, inodes_total, inodes_free) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(ts, mount_id) DO UPDATE SET total_bytes = excluded.total_bytes,
                          free_bytes = excluded.free_bytes, available_bytes = excluded.available_bytes,
                          used_bytes = excluded.used_bytes, inodes_total = excluded.inodes_total,
                          inodes_free = excluded.inodes_free
                        """, bindings: [.integer(ctx.ts), .integer(id), .integer(capacity.total), .integer(capacity.free),
                                          .integer(capacity.available), .integer(capacity.used),
                                          capacity.inodesTotal.sql, capacity.inodesFree.sql])
                }
            }
            return ids
        }
        inventory.publish(ids: ids, ts: ctx.ts)
        ctx.log.debug("capacity: \(ids.count) mounts at \(ctx.ts)")
        return issues.isEmpty ? .ok : .degraded(issues.joined(separator: "; "))
    }
}

extension Optional where Wrapped == String {
    var sql: SQLValue { map(SQLValue.text) ?? .null }
}
extension Optional where Wrapped == Int64 {
    var sql: SQLValue { map(SQLValue.integer) ?? .null }
}
extension Int64 {
    var sql: SQLValue { .integer(self) }
}
