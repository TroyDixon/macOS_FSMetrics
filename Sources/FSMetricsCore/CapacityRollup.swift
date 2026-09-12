import Foundation

/// Capacity fields needed to roll mounted volumes into a host-wide total.
public struct CapacityRollupInput: Sendable, Equatable {
    public var totalBytes: Double?
    public var usedBytes: Double?
    public var container: String?
    public var containerTotalBytes: Double?
    public var containerAvailableBytes: Double?

    public init(
        totalBytes: Double?,
        usedBytes: Double?,
        container: String? = nil,
        containerTotalBytes: Double? = nil,
        containerAvailableBytes: Double? = nil
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.container = container
        self.containerTotalBytes = containerTotalBytes
        self.containerAvailableBytes = containerAvailableBytes
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

/// Deduplicates shared APFS capacity while retaining ordinary volume totals.
public enum CapacityRollup {
    public static func fleet(_ inputs: [CapacityRollupInput]) -> CapacityRollupResult {
        var total = 0.0
        var used = 0.0
        var hasTotal = false
        var hasUsed = false
        var containers: [String: (total: Double?, available: Double?)] = [:]

        for input in inputs {
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
