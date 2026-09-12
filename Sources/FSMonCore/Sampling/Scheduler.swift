import Foundation

public final class Scheduler {
    private final class Entry {
        let sampler: Sampler
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
        var busy = false // Accessed only on control.
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
                let timer = DispatchSource.makeTimerSource(queue: control)
                timer.schedule(deadline: .now() + entry.sampler.interval, repeating: entry.sampler.interval)
                timer.setEventHandler { [weak self, weak entry] in
                    guard let self, let entry, !self.stopped else { return }
                    guard !entry.busy else {
                        self.log.warn("Skipping tick for \(entry.sampler.name): previous run still active")
                        return
                    }
                    entry.busy = true
                    self.pending.enter()
                    entry.queue.async {
                        let ts = Int64(Date().timeIntervalSince1970)
                        var status = "ok"
                        var detail: String?
                        do {
                            if case .degraded(let reason) = try entry.sampler.collect(SampleContext(ts: ts, db: self.db, log: self.log)) {
                                status = "degraded"; detail = reason
                            }
                        } catch { status = "error"; detail = String(describing: error) }
                        self.statuses.update(name: entry.sampler.name, interval: entry.sampler.interval, ts: ts, status: status, detail: detail)
                        if let detail { self.log.warn("\(entry.sampler.name): \(status): \(detail)") }
                        self.control.async {
                            entry.busy = false
                            self.pending.leave()
                        }
                    }
                }
                entry.timer = timer
                timer.resume()
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
