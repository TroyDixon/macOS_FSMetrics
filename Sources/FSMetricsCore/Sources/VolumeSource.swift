import Foundation

/// Filesystem flavor of a mounted volume.
public enum VolumeKind: String, Codable, Sendable, CaseIterable {
    case apfs
    case nfs
    case smb
    case other

    /// Classify from a filesystem type name (`statfs.f_fstypename`).
    public init(filesystemType: String) {
        switch filesystemType.lowercased() {
        case "apfs": self = .apfs
        case "nfs", "nfs4": self = .nfs
        case "smbfs", "smb": self = .smb
        default: self = .other
        }
    }
}

/// A mounted volume discovered on this device.
public struct VolumeInfo: Sendable, Equatable {
    public var path: String
    public var kind: VolumeKind
    public var label: String
    public var device: String?

    public init(path: String, kind: VolumeKind, label: String, device: String? = nil) {
        self.path = path
        self.kind = kind
        self.label = label
        self.device = device
    }
}

/// Discovery seam. `SystemVolumeSource` is production; `StaticVolumeSource`
/// lets tests pin an exact volume list.
public protocol VolumeSource: Sendable {
    func volumes() throws -> [VolumeInfo]
}

/// Test ``VolumeSource`` adapter backed by a fixed list.
public struct StaticVolumeSource: VolumeSource {
    private let storedVolumes: [VolumeInfo]

    public init(_ volumes: [VolumeInfo]) {
        self.storedVolumes = volumes
    }

    /// Convenience from `(path, kind, label)` triples.
    public init(paths: [(path: String, kind: VolumeKind, label: String)]) {
        self.init(paths.map { VolumeInfo(path: $0.path, kind: $0.kind, label: $0.label) })
    }

    public func volumes() throws -> [VolumeInfo] {
        storedVolumes
    }
}

/// Production ``VolumeSource``: discovers mounted volumes with
/// `FileManager.mountedVolumeURLs`.
///
/// Filesystem flavor and device come from `statfs`; the label prefers the
/// volume's display name and falls back to the last path component. Hidden
/// system volumes are skipped. Discovery never throws: entries that cannot be
/// inspected are omitted, and a total failure yields an empty list.
public struct SystemVolumeSource: VolumeSource {
    public init() {}

    public func volumes() throws -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap(Self.volumeInfo(at:))
    }

    /// Builds one ``VolumeInfo`` from a mounted URL, or nil when `statfs`
    /// cannot inspect it.
    private static func volumeInfo(at url: URL) -> VolumeInfo? {
        var filesystem = statfs()
        guard url.path.withCString({ statfs($0, &filesystem) }) == 0 else { return nil }

        let filesystemType = decodeCString(&filesystem.f_fstypename)
        let mountSource = decodeCString(&filesystem.f_mntfromname)

        let resourceName = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
        let label = resourceName.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent

        return VolumeInfo(
            path: url.path,
            kind: VolumeKind(filesystemType: filesystemType),
            label: label.isEmpty ? url.path : label,
            device: mountSource.hasPrefix("/dev/") ? mountSource : nil
        )
    }

    /// Decodes a fixed-size C char array such as `statfs.f_fstypename`.
    private static func decodeCString<T>(_ value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
