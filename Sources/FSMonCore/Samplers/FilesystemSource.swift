import Foundation
import Darwin
import IOKit

struct FilesystemFailure: Error, CustomStringConvertible {
    let description: String
}

struct MountReading {
    let path: String
    let device: String
    let fsType: String
    let flags: UInt32
    let blockSize: UInt64
    let blocks: UInt64
    let freeBlocks: UInt64
    let availableBlocks: UInt64
    let files: UInt64
    let freeFiles: UInt64
    var isRemote: Bool { flags & UInt32(MNT_LOCAL) == 0 || ["nfs", "smbfs", "webdav"].contains(fsType) }
    var isReal: Bool { !["devfs", "autofs", "fdesc", "volfs", "procfs"].contains(fsType) }
}

struct VolumeAttributes {
    let usedBytes: Int64?
    let uuid: String?
    let name: String?

    /// Packed ABI for RETURNED_ATTRS + VOL_SPACEUSED + VOL_NAME + VOL_UUID.
    /// SPACEUSED is packed before NAME and UUID despite its larger flag value.
    static func decode(_ data: Data) throws -> VolumeAttributes {
        try data.withUnsafeBytes { bytes in
            guard bytes.count >= 56 else { throw FilesystemFailure(description: "Short volume attribute buffer") }
            let length = Int(bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            guard length >= 56, length <= bytes.count else { throw FilesystemFailure(description: "Invalid volume attribute length") }
            let returned = bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let rawUsed = bytes.loadUnaligned(fromByteOffset: 24, as: Int64.self)
            let used = returned & UInt32(ATTR_VOL_SPACEUSED) != 0 && rawUsed >= 0 ? rawUsed : nil
            var name: String?
            if returned & UInt32(ATTR_VOL_NAME) != 0 {
                let offset = Int(bytes.loadUnaligned(fromByteOffset: 32, as: Int32.self))
                let count = Int(bytes.loadUnaligned(fromByteOffset: 36, as: UInt32.self))
                let start = 32 + offset
                guard start >= 56, count > 0, start <= length, count <= length - start,
                      bytes[start + count - 1] == 0 else {
                    throw FilesystemFailure(description: "Invalid volume name reference")
                }
                name = String(data: data.subdata(in: start..<(start + count - 1)), encoding: .utf8)
            }
            var uuid: String?
            if returned & UInt32(ATTR_VOL_UUID) != 0 {
                let raw = Array(bytes[40..<56])
                if raw.contains(where: { $0 != 0 }) {
                    let hex = raw.map { String(format: "%02X", $0) }
                    uuid = [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
                        .map { $0.joined() }.joined(separator: "-")
                }
            }
            return VolumeAttributes(usedBytes: used, uuid: uuid, name: name)
        }
    }
}

struct ContainerIdentity {
    let uuid: String
    let bsdName: String?

    /// A snapshot device (disk3s1s1) belongs to the same synthesized APFS
    /// container as disk3s1. This is a topology lookup, never a stable identity.
    static func bsdName(forVolumeDevice device: String) -> String? {
        guard device.range(of: #"^/dev/disk[0-9]+s[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil,
              let range = device.range(of: #"disk[0-9]+"#, options: .regularExpression) else { return nil }
        return String(device[range])
    }
}

protocol FilesystemSource {
    func cachedMounts() throws -> [MountReading]
    func refreshLocal(_ mount: MountReading) throws -> MountReading
    func attributes(_ mount: MountReading) throws -> VolumeAttributes
    func apfsContainersByVolumeUUID() throws -> [String: ContainerIdentity]
}

struct SystemFilesystemSource: FilesystemSource {
    func cachedMounts() throws -> [MountReading] {
        // Spare slots and a bounded retry handle mounts arriving between calls.
        for _ in 0..<3 {
            let count = getfsstat(nil, 0, MNT_NOWAIT)
            guard count >= 0 else { throw failure("getfsstat") }
            var entries = Array<statfs>(repeating: statfs(), count: Int(count) + 16)
            let capacity = entries.count
            let found = entries.withUnsafeMutableBufferPointer {
                getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            }
            guard found >= 0 else { throw failure("getfsstat") }
            if found < capacity { return entries.prefix(Int(found)).map(reading) }
        }
        throw FilesystemFailure(description: "Mount table changed repeatedly during enumeration")
    }

    func refreshLocal(_ mount: MountReading) throws -> MountReading {
        precondition(!mount.isRemote, "Never statfs a remote mount")
        var entry = statfs()
        guard mount.path.withCString({ statfs($0, &entry) }) == 0 else { throw failure("statfs \(mount.path)") }
        let updated = reading(entry)
        guard updated.path == mount.path, updated.device == mount.device, updated.fsType == mount.fsType,
              !updated.isRemote else { throw FilesystemFailure(description: "Mount changed during refresh: \(mount.path)") }
        return updated
    }

    func attributes(_ mount: MountReading) throws -> VolumeAttributes {
        precondition(!mount.isRemote, "Never getattrlist a remote mount")
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attrs.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED) | UInt32(ATTR_VOL_NAME) | UInt32(ATTR_VOL_UUID)
        var data = Data(count: 4096)
        let result = data.withUnsafeMutableBytes { bytes in
            mount.path.withCString { getattrlist($0, &attrs, bytes.baseAddress, bytes.count, UInt32(FSOPT_PACK_INVAL_ATTRS)) }
        }
        guard result == 0 else { throw failure("getattrlist \(mount.path)") }
        return try VolumeAttributes.decode(data)
    }

    func apfsContainersByVolumeUUID() throws -> [String: ContainerIdentity] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleAPFSVolume"), &iterator)
        guard result == KERN_SUCCESS else { throw FilesystemFailure(description: "IOKit APFS enumeration failed: \(result)") }
        defer { IOObjectRelease(iterator) }
        var containers: [String: ContainerIdentity] = [:]
        while case let volume = IOIteratorNext(iterator), volume != 0 {
            defer { IOObjectRelease(volume) }
            guard let volumeUUID = property(volume, "UUID") else { continue }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(volume, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            guard IOObjectConformsTo(parent, "AppleAPFSContainer") != 0,
                  let containerUUID = property(parent, "UUID") else { continue }
            let volumeBSD = property(volume, "BSD Name")
            let bsdName = volumeBSD.flatMap { name in
                name.range(of: #"^disk[0-9]+"#, options: .regularExpression).map { String(name[$0]) }
            }
            containers[volumeUUID.uppercased()] = ContainerIdentity(
                uuid: containerUUID.uppercased(), bsdName: bsdName
            )
        }
        return containers
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
    private func failure(_ operation: String) -> FilesystemFailure {
        FilesystemFailure(description: "\(operation): \(String(cString: strerror(errno)))")
    }
    private func reading(_ entry: statfs) -> MountReading {
        func string<T>(_ tuple: T) -> String {
            var tuple = tuple
            return withUnsafeBytes(of: &tuple) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        return MountReading(path: string(entry.f_mntonname), device: string(entry.f_mntfromname),
                            fsType: string(entry.f_fstypename), flags: entry.f_flags,
                            blockSize: UInt64(entry.f_bsize), blocks: entry.f_blocks,
                            freeBlocks: entry.f_bfree, availableBlocks: entry.f_bavail,
                            files: entry.f_files, freeFiles: entry.f_ffree)
    }
}
