import Foundation

/// Every collector crosses the same seam: given the host label and the current
/// time, produce metrics (with `volume` filled in). Dependencies (probes,
/// scanners, tools) are injected at construction.
public protocol Collector: Sendable {
    func sample(host: String, now: Date) throws -> [Metric]
}
