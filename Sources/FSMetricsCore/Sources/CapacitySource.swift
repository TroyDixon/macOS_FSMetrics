import Darwin
import Foundation

/// Capacity of one mounted volume.
///
/// On APFS, `totalBytes`, `freeBytes`, and `availableBytes` describe the
/// shared container (every volume in it reports the same numbers), while
/// `usedBytes` is this volume's own allocation. `usedPct` uses `df`'s Capacity
/// formula, `used / (used + available)`, so it agrees with `df -k`.
public struct VolumeCapacity: Sendable, Equatable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var availableBytes: Int64
    public var usedBytes: Int64
    public var container: String?

    public init(
        totalBytes: Int64,
        freeBytes: Int64,
        availableBytes: Int64,
        usedBytes: Int64,
        container: String? = nil
    ) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.container = container
    }

    /// `100 * used / (used + available)`, rounded to two decimals; 0 when both
    /// are zero.
    public var usedPct: Double {
        let denominator = Double(usedBytes) + Double(availableBytes)
        guard denominator > 0 else { return 0 }
        let percent = 100.0 * Double(usedBytes) / denominator
        return (percent * 100).rounded() / 100
    }

    /// Shared APFS container usage, `(total - available) / total`, rounded to
    /// two decimals. Non-APFS readings do not have a container percentage.
    public var containerUsedPct: Double? {
        guard container != nil, totalBytes > 0 else { return nil }
        let percent = 100.0 * Double(totalBytes - availableBytes) / Double(totalBytes)
        return (percent * 100).rounded() / 100
    }

    /// Builds a reading from raw `statfs` block counters plus the volume's
    /// `ATTR_VOL_SPACEUSED`.
    ///
    /// APFS never falls back to `total - free`: that is the whole container's
    /// usage, which every volume in the container would then report. Other
    /// filesystems own their blocks, so `total - free` is their usage.
    public static func fromCounters(
        filesystemType: String,
        blockSize: UInt64,
        blocks: UInt64,
        freeBlocks: UInt64,
        availableBlocks: UInt64,
        spaceUsed: Int64?,
        container: String? = nil
    ) throws -> VolumeCapacity {
        guard blockSize > 0, freeBlocks <= blocks else {
            throw CapacityError(message: "invalid capacity counters")
        }
        func bytes(_ count: UInt64) throws -> Int64 {
            let product = count.multipliedReportingOverflow(by: blockSize)
            guard !product.overflow, let value = Int64(exactly: product.partialValue) else {
                throw CapacityError(message: "capacity counters overflow")
            }
            return value
        }

        let total = try bytes(blocks)
        let free = try bytes(freeBlocks)
        // Filesystems may report negative availability as a wrapped unsigned value.
        let available = Int64(bitPattern: availableBlocks) < 0 ? 0 : try bytes(availableBlocks)

        let used: Int64
        if let spaceUsed {
            used = spaceUsed
        } else if filesystemType.lowercased() == "apfs" {
            throw CapacityError(message: "per-volume used space (ATTR_VOL_SPACEUSED) unavailable on APFS")
        } else {
            used = total - free
        }
        return VolumeCapacity(
            totalBytes: total,
            freeBytes: free,
            availableBytes: available,
            usedBytes: used,
            container: container
        )
    }
}

/// Capacity could not be measured honestly; the sample should be skipped.
public struct CapacityError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Volume attributes decoded from a `getattrlist` buffer.
public struct VolumeAttributes: Sendable, Equatable {
    public var spaceUsed: Int64?
    public var name: String?
    public var uuid: String?

    public init(spaceUsed: Int64? = nil, name: String? = nil, uuid: String? = nil) {
        self.spaceUsed = spaceUsed
        self.name = name
        self.uuid = uuid
    }

    /// Decodes the packed reply to `ATTR_CMN_RETURNED_ATTRS` +
    /// `ATTR_VOL_INFO | ATTR_VOL_SPACEUSED | ATTR_VOL_NAME | ATTR_VOL_UUID`
    /// requested with `FSOPT_PACK_INVAL_ATTRS`.
    ///
    /// Layout: 4-byte length, 20-byte returned `attribute_set_t`, 8-byte
    /// SPACEUSED, 8-byte NAME `attrreference_t`, 16-byte UUID, then the
    /// NUL-terminated name. SPACEUSED is packed *before* NAME and UUID despite
    /// its larger flag value.
    public static func decode(_ data: Data) throws -> VolumeAttributes {
        try data.withUnsafeBytes { bytes in
            guard bytes.count >= 56 else {
                throw CapacityError(message: "short volume attribute buffer")
            }
            let length = Int(bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            guard length >= 56, length <= bytes.count else {
                throw CapacityError(message: "invalid volume attribute length")
            }
            let returned = bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)

            let rawUsed = bytes.loadUnaligned(fromByteOffset: 24, as: Int64.self)
            let spaceUsed = returned & UInt32(ATTR_VOL_SPACEUSED) != 0 && rawUsed >= 0 ? rawUsed : nil

            var name: String?
            if returned & UInt32(ATTR_VOL_NAME) != 0 {
                let offset = Int(bytes.loadUnaligned(fromByteOffset: 32, as: Int32.self))
                let count = Int(bytes.loadUnaligned(fromByteOffset: 36, as: UInt32.self))
                let start = 32 + offset
                guard start >= 56, count > 0, start <= length, count <= length - start,
                      bytes[start + count - 1] == 0
                else {
                    throw CapacityError(message: "invalid volume name reference")
                }
                name = String(decoding: bytes[start..<(start + count - 1)], as: UTF8.self)
            }

            var uuid: String?
            if returned & UInt32(ATTR_VOL_UUID) != 0 {
                let raw = Array(bytes[40..<56])
                if raw.contains(where: { $0 != 0 }) {
                    let hex = raw.map { String(format: "%02X", $0) }
                    uuid = [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
                        .map { $0.joined() }
                        .joined(separator: "-")
                }
            }
            return VolumeAttributes(spaceUsed: spaceUsed, name: name, uuid: uuid)
        }
    }
}

/// Capacity seam. `SystemCapacitySource` is production;
/// `FixtureCapacitySource` serves fixed readings in tests.
public protocol CapacitySource: Sendable {
    func capacity(at path: String) throws -> VolumeCapacity
}

/// Production ``CapacitySource``: `statfs` for the container-wide counters and
/// `getattrlist` `ATTR_VOL_SPACEUSED` for the volume's own usage, which matches
/// `df`'s Used column and `diskutil` CapacityInUse.
///
/// `statfs(path)` is used rather than cached `getfsstat(MNT_NOWAIT)` entries,
/// which lag behind recent writes on local filesystems.
public struct SystemCapacitySource: CapacitySource {
    public init() {}

    public func capacity(at path: String) throws -> VolumeCapacity {
        var filesystem = statfs()
        guard path.withCString({ statfs($0, &filesystem) }) == 0 else {
            throw Self.failure("statfs \(path)")
        }
        let filesystemType = withUnsafeBytes(of: &filesystem.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let mountSource = withUnsafeBytes(of: &filesystem.f_mntfromname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let container = Self.containerIdentifier(
            filesystemType: filesystemType,
            mountSource: mountSource
        )

        var spaceUsed: Int64?
        if filesystem.f_flags & UInt32(MNT_LOCAL) != 0 {
            do {
                spaceUsed = try Self.volumeAttributes(at: path).spaceUsed
            } catch {
                // Only APFS needs SPACEUSED; elsewhere `total - free` is honest.
                if filesystemType.lowercased() == "apfs" { throw error }
            }
        }

        return try VolumeCapacity.fromCounters(
            filesystemType: filesystemType,
            blockSize: UInt64(filesystem.f_bsize),
            blocks: filesystem.f_blocks,
            freeBlocks: filesystem.f_bfree,
            availableBlocks: filesystem.f_bavail,
            spaceUsed: spaceUsed,
            container: container
        )
    }

    /// Maps an APFS mounted device such as `/dev/disk3s1s1` to its synthesized
    /// container (`disk3`). Other filesystems and non-device mount sources do
    /// not have an APFS container identity.
    public static func containerIdentifier(filesystemType: String, mountSource: String) -> String? {
        guard filesystemType.lowercased() == "apfs", mountSource.hasPrefix("/dev/") else {
            return nil
        }
        let device = String(mountSource.dropFirst("/dev/".count))
        guard device.range(
            of: #"^disk[0-9]+s[0-9]+(?:s[0-9]+)*$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return DiskInfo.wholeDisk(from: device)
    }

    static func volumeAttributes(at path: String) throws -> VolumeAttributes {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        request.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED)
            | UInt32(ATTR_VOL_NAME) | UInt32(ATTR_VOL_UUID)

        var buffer = Data(count: 4096)
        let result = buffer.withUnsafeMutableBytes { bytes in
            path.withCString {
                getattrlist($0, &request, bytes.baseAddress, bytes.count, UInt32(FSOPT_PACK_INVAL_ATTRS))
            }
        }
        guard result == 0 else { throw failure("getattrlist \(path)") }
        return try VolumeAttributes.decode(buffer)
    }

    private static func failure(_ operation: String) -> CapacityError {
        CapacityError(message: "\(operation): \(String(cString: strerror(errno)))")
    }
}

/// Test ``CapacitySource`` serving a fixed reading or error.
public struct FixtureCapacitySource: CapacitySource {
    public var reading: VolumeCapacity
    public var error: (any Error)?

    public init(reading: VolumeCapacity, error: (any Error)? = nil) {
        self.reading = reading
        self.error = error
    }

    public func capacity(at path: String) throws -> VolumeCapacity {
        if let error { throw error }
        return reading
    }
}
