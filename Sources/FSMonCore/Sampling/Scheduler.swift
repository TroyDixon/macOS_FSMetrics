import Foundation
import Darwin

public final class Scheduler {
    private final class Entry {
        let sampler: Sampler
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
        var busy = false // Accessed only on control.
        var lastBoundary = -Double.infinity // Accessed only on control.
        init(_ sampler: Sampler) {
            self.sampler = sampler
            queue = DispatchQueue(label: "fsmond.sampler.\(sampler.name)")
        }
    }
    /// Ticks fire this far past each interval boundary so a slightly early or
    /// late fire still stamps the intended boundary.
    static let cushion: TimeInterval = 0.050
    private let control = DispatchQueue(label: "fsmond.scheduler")
    private let pending = DispatchGroup()
    private let entries: [Entry]
    private let db: Database
    private let log: Logger
    private let wallClock: () -> TimeInterval
    public let statuses: SamplerStatusStore
    private var started = false
    private var stopped = false

    public convenience init(registry: SamplerRegistry, db: Database, log: Logger, statuses: SamplerStatusStore = SamplerStatusStore()) {
        self.init(registry: registry, db: db, log: log, statuses: statuses, wallClock: { Date().timeIntervalSince1970 })
    }
    /// `wallClock` is injectable so tests can simulate sleep and clock steps.
    init(registry: SamplerRegistry, db: Database, log: Logger, statuses: SamplerStatusStore, wallClock: @escaping () -> TimeInterval) {
        entries = registry.samplers.map(Entry.init)
        self.db = db; self.log = log; self.statuses = statuses; self.wallClock = wallClock
        registry.samplers.forEach { statuses.register($0) }
    }
    public func start() {
        control.sync {
            guard !started && !stopped else { return }
            started = true
            for entry in entries {
                let timer = DispatchSource.makeTimerSource(queue: control)
                timer.setEventHandler { [weak self, weak entry] in
                    guard let self, let entry, !self.stopped else { return }
                    self.tick(entry)
                }
                entry.timer = timer
                tick(entry) // Immediate first run; also arms the timer.
                timer.resume()
            }
        }
    }
    /// Runs on control. The timestamp is derived from the wall clock on every
    /// tick (never accumulated), so it cannot fall behind real time after system
    /// sleep, a stalled queue, or coalesced timer fires. Timestamps strictly
    /// increase: if the wall clock steps backwards, ticks are skipped until it
    /// passes the last stored boundary.
    private func tick(_ entry: Entry) {
        let interval = entry.sampler.interval
        let now = wallClock()
        // First run stamps the current second; later runs stamp the interval boundary.
        let boundary = entry.lastBoundary == -.infinity ? floor(now) : floor(now / interval) * interval
        if boundary > entry.lastBoundary {
            entry.lastBoundary = boundary
            trigger(entry, ts: Int64(boundary))
        } else {
            log.debug("Skipping tick for \(entry.sampler.name): wall clock is not past the previous sample")
        }
        // One-shot wall-clock timer re-armed each tick: wall time keeps counting
        // during sleep, and re-arming from the clock keeps ticks aligned.
        let next = (floor(now / interval) + 1) * interval + Self.cushion
        entry.timer?.schedule(wallDeadline: .now() + max(0, next - now))
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
