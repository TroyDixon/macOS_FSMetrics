import Foundation

/// Per-user capacity attribution for one volume.
///
/// Ported from Python `collector/capacity.py::collect`: the injected
/// ``FileScanner`` walks the configured paths, and one `capacity.user_bytes`
/// metric is emitted per owning uid, with the uid converted to `String` at
/// this layer (the scanner works in `uid_t`).
public struct CapacityCollector: Collector {
    private let volumePath: String
    private let scanPaths: [String]
    private let scanner: any FileScanner
    private let followSymlinks: Bool

    public init(
        volumePath: String,
        scanPaths: [String],
        scanner: any FileScanner,
        followSymlinks: Bool = false
    ) {
        self.volumePath = volumePath
        self.scanPaths = scanPaths
        self.scanner = scanner
        self.followSymlinks = followSymlinks
    }

    public func sample(host: String, now: Date) throws -> [Metric] {
        let usage = try scanner.usageByUID(paths: scanPaths, followSymlinks: followSymlinks)
        return usage.map { uid, totalBytes in
            Metric(
                kind: .userBytes,
                host: host,
                volume: volumePath,
                value: Double(totalBytes),
                uid: String(uid),
                username: username(forUID: uid),
                ts: now
            )
        }
    }
}
