import Foundation

/// Phase 0 only. Remove this sampler and its registration in Phase 1.
public final class DummySampler: Sampler {
    public let name = "dummy"
    public let interval: TimeInterval = 1
    public init() {}
    public func collect(_ ctx: SampleContext) throws -> SamplerOutcome {
        try ctx.db.write { connection in
            try connection.execute("CREATE TABLE IF NOT EXISTS debug_samples (ts INTEGER NOT NULL, value REAL NOT NULL)")
            try connection.execute("INSERT INTO debug_samples (ts, value) VALUES (?, ?)", bindings: [.integer(ctx.ts), .real(Double.random(in: 0..<1))])
        }
        ctx.log.debug("dummy: wrote sample at \(ctx.ts)")
        return .ok
    }
}
