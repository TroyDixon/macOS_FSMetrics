import Foundation

/// Filesystem walking seam for per-user capacity attribution and top-N files.
///
/// Implementations must degrade gracefully: unreadable directories/files are
/// skipped, never fatal.
public protocol FileScanner: Sendable {
    /// Returns `{uid: total_bytes_owned}` for every file under `paths`.
    func usageByUID(paths: [String], followSymlinks: Bool) throws -> [uid_t: Int64]

    /// The `topN` largest files under `paths`, descending by size.
    func largestPaths(paths: [String], topN: Int) throws -> [(String, Int64)]
}

public extension FileScanner {
    /// Convenience mirroring the Python default.
    func usageByUID(paths: [String]) throws -> [uid_t: Int64] {
        try usageByUID(paths: paths, followSymlinks: false)
    }
}

/// Resolve a uid to a display name, falling back to the numeric string.
public func username(forUID uid: uid_t) -> String {
    if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
        return String(cString: name)
    }
    return String(uid)
}

/// Production ``FileScanner`` implemented with `FileManager.enumerator`.
///
/// Degrades gracefully: a missing or unreadable root yields an empty result
/// and per-entry errors are skipped, so one inaccessible directory cannot
/// abort a scan (mirrors Python `os.walk(onerror:)` + `try/except`).
public struct FileManagerScanner: FileScanner {
    /// Prefetched by the enumerator so directory entries can be classified
    /// without an extra fetch. `URLResourceValues` does not expose the owner
    /// uid, so the owner comes from `attributesOfItem` regardless.
    private static let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]

    public init() {}

    public func usageByUID(paths: [String], followSymlinks: Bool) throws -> [uid_t: Int64] {
        var totals: [uid_t: Int64] = [:]
        for root in paths {
            enumerateFiles(root: root, followSymlinks: followSymlinks) { _, size, uid in
                totals[uid, default: 0] += size
            }
        }
        return totals
    }

    /// Keeps at most `topN` entries in a descending array; the full file list
    /// is never materialized.
    public func largestPaths(paths: [String], topN: Int) throws -> [(String, Int64)] {
        guard topN > 0 else { return [] }

        var top: [(path: String, size: Int64)] = []
        top.reserveCapacity(topN)

        for root in paths {
            enumerateFiles(root: root, followSymlinks: false) { url, size, _ in
                if top.count < topN {
                    top.append((url.path, size))
                } else if size > top[top.count - 1].size {
                    top[top.count - 1] = (url.path, size)
                } else {
                    return
                }
                top.sort { $0.size > $1.size }
            }
        }
        return top
    }

    // MARK: - Walk

    /// Visits every regular file under `root` with its size and owning uid.
    ///
    /// Symbolic links are skipped unless `followSymlinks` is set, in which
    /// case a link to a regular file is attributed to its target. Linked
    /// directories are never traversed, matching `os.walk(followlinks=False)`.
    private func enumerateFiles(
        root: String,
        followSymlinks: Bool,
        _ visit: (URL, Int64, uid_t) -> Void
    ) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Self.resourceKeys) else {
                continue
            }

            if values.isSymbolicLink == true {
                guard followSymlinks else { continue }
                guard let attributes = try? fileManager.attributesOfItem(
                        atPath: url.resolvingSymlinksInPath().path
                      ),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = (attributes[.size] as? NSNumber)?.int64Value,
                      let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
                else {
                    continue
                }
                visit(url, size, uid_t(owner))
                continue
            }

            guard values.isRegularFile == true else { continue }
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            else {
                continue
            }
            let size = values.fileSize.map(Int64.init)
                ?? (attributes[.size] as? NSNumber)?.int64Value
                ?? 0
            visit(url, size, uid_t(owner))
        }
    }
}
