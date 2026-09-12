import Foundation

public struct SamplerStatus: Equatable {
    public let name: String
    public let interval: TimeInterval
    public let lastRun: Int64?
    public let status: String
    public let detail: String?
}
public final class SamplerStatusStore {
    private let lock = NSLock()
    private var values: [String: SamplerStatus] = [:]
    public init() {}
    func register(_ sampler: Sampler) {
        update(name: sampler.name, interval: sampler.interval, ts: nil, status: "degraded", detail: "Awaiting first sample")
    }
    func update(name: String, interval: TimeInterval, ts: Int64?, status: String, detail: String?) {
        lock.lock(); defer { lock.unlock() }
        values[name] = SamplerStatus(name: name, interval: interval, lastRun: ts, status: status, detail: detail)
    }
    public func snapshot() -> [SamplerStatus] {
        lock.lock(); defer { lock.unlock() }
        return values.values.sorted { $0.name < $1.name }
    }
}
