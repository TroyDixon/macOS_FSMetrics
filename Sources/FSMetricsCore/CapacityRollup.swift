import Foundation

/// Capacity fields needed to roll mounted volumes into a host-wide total.
public struct CapacityRollupInput: Sendable, Equatable {
    public var totalBytes: Double?
    public var usedBytes: Double?
    public var container: String?
    public var containerTotalBytes: Double?
    public var containerAvailableBytes: Double?
    /// Remote shares (NFS/SMB) report the server's filesystem, which may be
    /// storage a local volume already represents; they keep their own
    /// per-volume reading but are excluded from the host rollup by default.
    /// Pass `includeRemote: true` to ``CapacityRollup/fleet(_:includeRemote:)``
    /// for a whole-fleet total, such as the free-space headline.
    public var isRemote: Bool

    public init(
        totalBytes: Double?,
        usedBytes: Double?,
        container: String? = nil,
        containerTotalBytes: Double? = nil,
        containerAvailableBytes: Double? = nil,
        isRemote: Bool = false
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.container = container
        self.containerTotalBytes = containerTotalBytes
        self.containerAvailableBytes = containerAvailableBytes
        self.isRemote = isRemote
    }
}

public struct CapacityRollupResult: Sendable, Equatable {
    public var totalBytes: Double?
    public var usedBytes: Double?

    public init(totalBytes: Double?, usedBytes: Double?) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
    }
}

/// Deduplicates shared local APFS capacity while retaining ordinary local
/// volume totals and, by default, excluding remote volumes, which report the
/// server's filesystem.
public enum CapacityRollup {
    /// Rolls `inputs` into one host-wide total.
    ///
    /// Remote shares report the server's filesystem and are excluded from the
    /// host rollup by default, since that storage may already be represented by
    /// a local volume. Pass `includeRemote: true` for a whole-fleet total, such
    /// as the free-space headline; remote inputs then roll in under exactly the
    /// same container-dedup and nil-skipping rules as local ones.
    public static func fleet(
        _ inputs: [CapacityRollupInput],
        includeRemote: Bool = false
    ) -> CapacityRollupResult {
        var total = 0.0
        var used = 0.0
        var hasTotal = false
        var hasUsed = false
        var containers: [String: (total: Double?, available: Double?)] = [:]

        for input in inputs {
            if input.isRemote && !includeRemote {
                continue
            }
            if let container = input.container {
                let previous = containers[container]
                containers[container] = (
                    total: previous?.total ?? input.containerTotalBytes,
                    available: previous?.available ?? input.containerAvailableBytes
                )
                continue
            }
            if let volumeTotal = input.totalBytes {
                total += volumeTotal
                hasTotal = true
            }
            if let volumeUsed = input.usedBytes {
                used += volumeUsed
                hasUsed = true
            }
        }

        for container in containers.values {
            if let containerTotal = container.total {
                total += containerTotal
                hasTotal = true
                if let available = container.available {
                    used += containerTotal - available
                    hasUsed = true
                }
            }
        }

        return CapacityRollupResult(
            totalBytes: hasTotal ? total : nil,
            usedBytes: hasUsed ? used : nil
        )
    }
}
