import Foundation
import Darwin

public final class Scheduler {
    private final class Entry {
        let sampler: Sampler
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
        var busy = false // Accessed only on control.
        var nextPlannedWallTime: TimeInterval = 0
        init(_ sampler: Sampler) {
            self.sampler = sampler
            queue = DispatchQueue(label: "fsmond.sampler.\(sampler.name)")
        }
    }
    private let control = DispatchQueue(label: "fsmond.scheduler")
    private let pending = DispatchGroup()
    private let entries: [Entry]
    private let db: Database
    private let log: Logger
    public let statuses: SamplerStatusStore
    private var started = false
    private var stopped = false

    public init(registry: SamplerRegistry, db: Database, log: Logger, statuses: SamplerStatusStore = SamplerStatusStore()) {
        entries = registry.samplers.map(Entry.init)
        self.db = db; self.log = log; self.statuses = statuses
        registry.samplers.forEach { statuses.register($0) }
    }
    public func start() {
        control.sync {
            guard !started && !stopped else { return }
            started = true
            for entry in entries {
                let now = Date().timeIntervalSince1970
                trigger(entry, ts: Int64(now.rounded(.down)))

                let interval = entry.sampler.interval
                let boundary = (floor(now / interval) + 1) * interval
                entry.nextPlannedWallTime = boundary
                let timer = DispatchSource.makeTimerSource(queue: control)
                let delay = max(0, boundary + 0.050 - now)
                timer.schedule(deadline: .now() + delay, repeating: interval)
                timer.setEventHandler { [weak self, weak entry] in
                    guard let self, let entry, !self.stopped else { return }
                    let plannedTS = Int64(entry.nextPlannedWallTime.rounded(.down))
                    entry.nextPlannedWallTime += entry.sampler.interval
                    self.trigger(entry, ts: plannedTS)
                }
                entry.timer = timer
                timer.resume()
            }
        }
    }
    private func trigger(_ entry: Entry, ts: Int64) {
        guard !entry.busy else {
            log.warn("Skipping tick for \(entry.sampler.name): previous run still active")
            return
        }
        entry.busy = true
        pending.enter()
        entry.queue.async {
            let context = SampleContext(
                ts: ts,
                monotonicNanos: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW),
                db: self.db,
                log: self.log
            )
            var status = "ok"
            var detail: String?
            do {
                if case .degraded(let reason) = try entry.sampler.collect(context) {
                    status = "degraded"
                    detail = reason
                }
            } catch {
                status = "error"
                detail = String(describing: error)
            }
            self.statuses.update(name: entry.sampler.name, interval: entry.sampler.interval, ts: ts, status: status, detail: detail)
            if let detail { self.log.warn("\(entry.sampler.name): \(status): \(detail)") }
            self.control.async {
                entry.busy = false
                self.pending.leave()
            }
        }
    }
    /// Cancels future ticks and drains in-flight runs. Call outside sampler queues.
    public func stop() {
        control.sync {
            stopped = true
            for entry in entries { entry.timer?.cancel(); entry.timer = nil }
        }
        pending.wait()
    }
    deinit { stop() }
}
