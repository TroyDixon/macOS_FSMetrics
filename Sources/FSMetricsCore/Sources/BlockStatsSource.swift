import Foundation
import IOKit

/// Cumulative block-device counters. `PerformanceCollector` diffs two reads
/// over the injected `Clock` to compute rates.
public struct BlockCounters: Sendable, Equatable {
    public var bytesRead: Int64
    public var bytesWritten: Int64

    public init(bytesRead: Int64, bytesWritten: Int64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }
}

/// Raw block-statistics seam. Production adapter reads IOKit
/// `IOBlockStorageDriver` statistics; the iostat adapter is a fallback.
public protocol BlockStatsSource: Sendable {
    /// Cumulative counters for a device such as `disk0`.
    func counters(device: String) throws -> BlockCounters
}

/// Production ``BlockStatsSource`` backed by IOKit.
///
/// Iterates the `IOBlockStorageDriver` services and, for each, walks the
/// registry child tree to the `IOMedia` whose `BSD Name` equals the requested
/// device (a driver's own children are the whole-disk and partition medias).
/// The cumulative `Bytes (Read)`/`Bytes (Write)` values are then read from the
/// matched driver's `Statistics` property.
///
/// Failures are reported as ``CommandError`` with `tool: "IOKit"`, never by
/// crashing: every IOKit call is checked, and a service that lacks the
/// `Statistics` dictionary is simply skipped.
public struct IOKitBlockStats: BlockStatsSource {
    public init() {}

    public func counters(device: String) throws -> BlockCounters {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else {
            throw Self.failure(device: device, reason: "IOServiceMatching returned nil")
        }

        var iterator: io_iterator_t = 0
        let matchingResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchingResult == KERN_SUCCESS else {
            throw Self.failure(device: device, reason: "IOServiceGetMatchingServices failed (\(matchingResult))")
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let driver = IOIteratorNext(iterator)
            guard driver != 0 else { break }
            defer { IOObjectRelease(driver) }

            guard let media = Self.firstEntry(device: device, in: driver) else { continue }
            defer { IOObjectRelease(media) }

            if let counters = Self.blockCounters(of: driver) {
                return counters
            }
        }

        throw Self.failure(device: device, reason: "no IOBlockStorageDriver with BSD Name \(device)")
    }

    // MARK: - Registry helpers

    /// Depth-first search for an entry whose `BSD Name` is `device`, returning
    /// a retained (+1) reference for the caller to release, or nil.
    private static func firstEntry(device: String, in entry: io_registry_entry_t) -> io_registry_entry_t? {
        if bsdName(of: entry) == device {
            return IOObjectRetain(entry) == KERN_SUCCESS ? entry : nil
        }

        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(children) }

        while true {
            let child = IOIteratorNext(children)
            guard child != 0 else { break }

            if let match = firstEntry(device: device, in: child) {
                IOObjectRelease(child)
                return match
            }
            IOObjectRelease(child)
        }
        return nil
    }

    private static func bsdName(of entry: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry, "BSD Name" as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return value.takeRetainedValue() as? String
    }

    private static func blockCounters(of entry: io_registry_entry_t) -> BlockCounters? {
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let statistics = dictionary["Statistics"] as? [String: Any],
              let bytesRead = int64(statistics["Bytes (Read)"]),
              let bytesWritten = int64(statistics["Bytes (Write)"])
        else { return nil }

        return BlockCounters(bytesRead: bytesRead, bytesWritten: bytesWritten)
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let int as Int: return Int64(int)
        case let int64 as Int64: return int64
        default: return nil
        }
    }

    private static func failure(device: String, reason: String) -> CommandError {
        CommandError(tool: "IOKit", args: [device], status: -1, stderr: reason)
    }
}

/// Test ``BlockStatsSource`` with mutable counters and an optional forced
/// failure.
///
/// All state is guarded by a lock so the collector can be driven from multiple
/// tasks in tests. `error` forces every read to throw, exercising the iostat
/// fallback path.
public final class FixtureBlockStatsSource: BlockStatsSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCounters: [String: BlockCounters]
    private var forcedError: (any Error)?

    public init(counters: [String: BlockCounters] = [:], error: (any Error)? = nil) {
        self.storedCounters = counters
        self.forcedError = error
    }

    /// When set, every ``counters(device:)`` call throws this instead of
    /// returning counters.
    public var error: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return forcedError
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            forcedError = newValue
        }
    }

    /// Replaces the counters recorded for `device`.
    public func setCounters(_ counters: BlockCounters, for device: String) {
        lock.lock()
        defer { lock.unlock() }
        storedCounters[device] = counters
    }

    public func counters(device: String) throws -> BlockCounters {
        lock.lock()
        defer { lock.unlock() }
        if let forcedError { throw forcedError }
        guard let counters = storedCounters[device] else {
            throw CommandError(
                tool: "FixtureBlockStatsSource", args: [device], status: -1,
                stderr: "no counters registered for '\(device)'"
            )
        }
        return counters
    }
}
