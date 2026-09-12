import Foundation

/// Shared retention owner: B must not schedule a second raw-sample cleanup job.
public final class RetentionSampler: Sampler {
    public let name = "retention"
    public let interval: TimeInterval = 3600
    static let rawTables = ["capacity_samples", "container_capacity_samples", "io_samples",
                            "user_io_samples", "process_io_samples", "nfs_samples", "device_health_samples"]
    public init() {}
    public func collect(_ ctx: SampleContext) throws -> SamplerOutcome {
        let cutoff = ctx.ts - 24 * 60 * 60
        try ctx.db.write { connection in
            for table in Self.rawTables {
                try connection.execute("DELETE FROM \(table) WHERE ts < ?", bindings: [.integer(cutoff)])
            }
        }
        ctx.log.debug("retention: removed raw samples older than \(cutoff)")
        return .ok
    }
}
