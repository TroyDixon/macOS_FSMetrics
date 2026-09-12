import Foundation

/// `diskutil info -plist` fields the health collector cares about. Ported from
/// Python `collector/health.py::parse_diskutil_info_plist`.
public struct DiskInfo: Sendable, Equatable {
    public var deviceIdentifier: String?
    /// `ParentWholeDisk` from `diskutil` (e.g. `disk3` for an APFS volume).
    public var parentWholeDisk: String?
    /// Whole physical disk backing an APFS volume, derived from
    /// `APFSPhysicalStores` (e.g. `disk0` from `disk0s2`).
    public var physicalStore: String?
    public var volumeName: String?
    public var filesystem: String?
    public var smartStatus: String
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var usedBytes: Int64
    public var encrypted: Bool
    public var mountPoint: String?
    public var writable: Bool
    public var removableMedia: Bool

    public init(
        deviceIdentifier: String? = nil,
        parentWholeDisk: String? = nil,
        physicalStore: String? = nil,
        volumeName: String? = nil,
        filesystem: String? = nil,
        smartStatus: String = "Not Supported",
        totalBytes: Int64 = 0,
        freeBytes: Int64 = 0,
        usedBytes: Int64 = 0,
        encrypted: Bool = false,
        mountPoint: String? = nil,
        writable: Bool = true,
        removableMedia: Bool = false
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.parentWholeDisk = parentWholeDisk
        self.physicalStore = physicalStore
        self.volumeName = volumeName
        self.filesystem = filesystem
        self.smartStatus = smartStatus
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.encrypted = encrypted
        self.mountPoint = mountPoint
        self.writable = writable
        self.removableMedia = removableMedia
    }

    /// Best device identifier for `iostat`/IOKit: the whole physical disk
    /// backing the volume when known.
    ///
    /// `iostat` on Apple Silicon rejects synthesized APFS devices such as
    /// `disk3` or `disk3s1s1`; the physical store (`disk0`) is accepted and is
    /// what Python's `_disk_id_for` was reaching for via `ParentWholeDisk`.
    public var preferredDiskID: String {
        physicalStore ?? parentWholeDisk ?? deviceIdentifier ?? "disk0"
    }

    /// Strips partition suffixes: `disk0s2` -> `disk0`, `disk0s2s1` -> `disk0`.
    public static func wholeDisk(from device: String) -> String {
        var result = device
        while let range = result.range(of: #"s[0-9]+$"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result.isEmpty ? device : result
    }
}

/// One NVMe controller/medium from `system_profiler SPNVMeDataType -json`.
public struct NVMEHealth: Sendable, Equatable {
    public var name: String?
    public var smartStatus: String
    public var size: String?
    public var mediumType: String?

    public init(name: String? = nil, smartStatus: String = "Not Supported", size: String? = nil, mediumType: String? = nil) {
        self.name = name
        self.smartStatus = smartStatus
        self.size = size
        self.mediumType = mediumType
    }
}

/// Block-storage diagnostics seam. `DiskUtilProbe` is production;
/// `FixtureProbe` serves recorded outputs in tests.
public protocol DiagnosticsProbe: Sendable {
    func diskInfo(at path: String) throws -> DiskInfo
    func nvmeHealth() throws -> [NVMEHealth]
}

/// A probe produced output that could not be interpreted. Distinct from
/// ``CommandError``, which means the tool itself failed to run.
public struct ProbeParseError: Error, Sendable, Equatable {
    public var tool: String
    public var message: String

    public init(tool: String, message: String) {
        self.tool = tool
        self.message = message
    }
}

/// Production ``DiagnosticsProbe``: shells out to `diskutil info -plist` and
/// `system_profiler SPNVMeDataType -json` through the injected
/// ``CommandRunning``.
public struct DiskUtilProbe: DiagnosticsProbe {
    private let commands: any CommandRunning

    public init(commands: any CommandRunning) {
        self.commands = commands
    }

    public func diskInfo(at path: String) throws -> DiskInfo {
        let data = try commands.run("diskutil", ["info", "-plist", path])
        return try Self.parseDiskInfo(data)
    }

    public func nvmeHealth() throws -> [NVMEHealth] {
        let data = try commands.run("system_profiler", ["SPNVMeDataType", "-json"])
        return try Self.parseNVMEHealth(data)
    }

    // MARK: - Parsing

    /// Ported from Python `collector/health.py::parse_diskutil_info_plist`.
    ///
    /// `TotalSize`/`Size` and `FreeSpace`/`APFSContainerFree` are fallback
    /// chains with Python `or` semantics: a missing or zero first choice falls
    /// through to the next, and `used = total - free` is only derived when
    /// `total` is non-zero.
    static func parseDiskInfo(_ data: Data) throws -> DiskInfo {
        let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let plist = raw as? [String: Any] else {
            throw ProbeParseError(tool: "diskutil", message: "expected a plist dictionary")
        }

        let total = Self.nonZeroInt(plist["TotalSize"])
            ?? Self.nonZeroInt(plist["Size"])
            ?? 0
        let free = Self.nonZeroInt(plist["FreeSpace"])
            ?? Self.nonZeroInt(plist["APFSContainerFree"])
            ?? 0
        let used = total != 0 ? total - free : 0

        return DiskInfo(
            deviceIdentifier: Self.string(plist["DeviceIdentifier"]),
            parentWholeDisk: Self.string(plist["ParentWholeDisk"]),
            physicalStore: Self.physicalStore(plist["APFSPhysicalStores"]),
            volumeName: Self.string(plist["VolumeName"]),
            filesystem: Self.nonEmptyString(plist["FilesystemType"])
                ?? Self.nonEmptyString(plist["FilesystemName"]),
            smartStatus: Self.string(plist["SMARTStatus"]) ?? "Not Supported",
            totalBytes: total,
            freeBytes: free,
            usedBytes: used,
            encrypted: (Self.bool(plist["Encryption"]) ?? false)
                || (Self.bool(plist["FileVault"]) ?? false),
            mountPoint: Self.string(plist["MountPoint"]),
            writable: Self.bool(plist["WritableVolume"]) ?? true,
            removableMedia: Self.bool(plist["RemovableMedia"]) ?? false
        )
    }

    /// Ported from Python `collector/health.py::parse_nvme_health`.
    static func parseNVMEHealth(_ data: Data) throws -> [NVMEHealth] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let json = raw as? [String: Any] else {
            throw ProbeParseError(tool: "system_profiler", message: "expected a JSON object")
        }
        guard let items = json["SPNVMeDataType"] as? [Any] else { return [] }

        var results: [NVMEHealth] = []
        for case let item as [String: Any] in items {
            for controller in Self.nestedObjects(in: item, key: "_items") {
                for drive in Self.nestedObjects(in: controller, key: "_items") {
                    results.append(NVMEHealth(
                        name: Self.string(drive["_name"]),
                        smartStatus: Self.string(drive["smart_status"]) ?? "Not Supported",
                        size: Self.string(drive["size"]),
                        mediumType: Self.string(drive["spnvme_medium_type"])
                    ))
                }
            }
        }
        return results
    }

    /// `APFSPhysicalStores` is an array of dictionaries, e.g.
    /// `[{"APFSPhysicalStore": "disk0s2"}]`; reduce the first entry to its
    /// whole disk (`disk0`).
    private static func physicalStore(_ value: Any?) -> String? {
        guard let stores = value as? [Any],
              let first = stores.first as? [String: Any],
              let device = string(first["APFSPhysicalStore"])
        else { return nil }
        return DiskInfo.wholeDisk(from: device)
    }

    /// Python `object.get("_items", [object])`: an absent `_items` yields the
    /// parent itself, a present array yields its dictionary elements.
    private static func nestedObjects(in object: [String: Any], key: String) -> [[String: Any]] {
        guard let items = object[key] as? [Any] else { return [object] }
        return items.compactMap { $0 as? [String: Any] }
    }

    private static func int(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let int as Int: return Int64(int)
        case let int64 as Int64: return int64
        default: return nil
        }
    }

    /// `nil` for missing *and* zero values, matching Python `or` fallbacks.
    private static func nonZeroInt(_ value: Any?) -> Int64? {
        guard let value = int(value), value != 0 else { return nil }
        return value
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = string(value), !string.isEmpty else { return nil }
        return string
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        default: return nil
        }
    }
}

/// Test ``DiagnosticsProbe`` serving fixed outputs.
public struct FixtureProbe: DiagnosticsProbe {
    /// Value returned by ``diskInfo(at:)``.
    public var diskInfo: DiskInfo

    /// Drives returned by ``nvmeHealth()``.
    public var nvme: [NVMEHealth]

    /// When set, ``nvmeHealth()`` throws this instead of returning ``nvme``,
    /// exercising the collector's best-effort NVMe degradation.
    public var nvmeError: (any Error)?

    public init(diskInfo: DiskInfo, nvme: [NVMEHealth] = [], nvmeError: (any Error)? = nil) {
        self.diskInfo = diskInfo
        self.nvme = nvme
        self.nvmeError = nvmeError
    }

    public func diskInfo(at path: String) throws -> DiskInfo {
        self.diskInfo
    }

    public func nvmeHealth() throws -> [NVMEHealth] {
        if let nvmeError { throw nvmeError }
        return nvme
    }
}
