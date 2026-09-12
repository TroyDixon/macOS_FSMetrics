import Foundation

/// Time and sleeping are injected so the scheduler is testable without real
/// delays.
public protocol Clock: Sendable {
    var now: Date { get }
    func sleep(for interval: TimeInterval) async throws
}

/// Production clock.
public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

/// Test clock. Time only moves when a test moves it; `sleep(for:)` returns
/// immediately so scheduler tests never really wait.
public final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.current = now
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        set(current.addingTimeInterval(interval))
    }

    public func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }

    public func sleep(for interval: TimeInterval) async throws {
        // Intentionally a no-op: tests control time via `advance`/`set`.
    }
}
