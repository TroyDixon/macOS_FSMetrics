import Foundation

public protocol Sampler: AnyObject {
    var name: String { get }
    var interval: TimeInterval { get }
    func collect(_ ctx: SampleContext) throws -> SamplerOutcome
}
public enum SamplerOutcome: Equatable { case ok, degraded(String) }
public struct SampleContext {
    public let ts: Int64
    /// Raw monotonic time for elapsed-time and rate calculations. This value is
    /// unrelated to Unix epoch time and remains stable across wall-clock changes.
    public let monotonicNanos: UInt64
    public let db: Database
    public let log: Logger
    public init(ts: Int64, monotonicNanos: UInt64, db: Database, log: Logger) {
        self.ts = ts
        self.monotonicNanos = monotonicNanos
        self.db = db
        self.log = log
    }
}
/// Populate during startup, before constructing the scheduler.
public final class SamplerRegistry {
    public private(set) var samplers: [Sampler] = []
    public init() {}
    public func register(_ sampler: Sampler) {
        precondition(!sampler.name.isEmpty && !samplers.contains { $0.name == sampler.name }, "Sampler names must be unique and nonempty")
        precondition(sampler.interval.isFinite && sampler.interval > 0, "Sampler interval must be positive and finite")
        samplers.append(sampler)
    }
}
