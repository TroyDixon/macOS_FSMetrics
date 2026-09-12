import Foundation
import os

/// The scheduler that ties collectors, the store, the alert engine, and the
/// notifier together. Two cadences, ported from Python `collector/daemon.py`:
///
/// - `pollIntervalSeconds`: health/performance/NFS (cheap, frequent)
/// - `capacityScanIntervalSeconds`: per-user capacity walk (expensive)
///
/// Dependencies are injected, especially ``Clock``, so tests never sleep.
public actor CollectorService {
    private let settings: Settings
    private let store: any MetricStore
    private let volumeSource: any VolumeSource
    private let collectors: [any Collector]
    private let capacityCollectors: [any Collector]
    private let engine: AlertEngine
    private let notifier: any Notifier
    private let clock: any Clock

    private var lastCapacityScan: Date?
    private var isRunning = false

    private static let log = Logger(subsystem: "local.fsmetrics", category: "service")

    public init(
        settings: Settings,
        store: any MetricStore,
        volumes: any VolumeSource,
        collectors: [any Collector],
        capacityCollectors: [any Collector] = [],
        engine: AlertEngine,
        notifier: any Notifier,
        clock: any Clock
    ) {
        self.settings = settings
        self.store = store
        self.volumeSource = volumes
        self.collectors = collectors
        self.capacityCollectors = capacityCollectors
        self.engine = engine
        self.notifier = notifier
        self.clock = clock
    }

    /// Run exactly one cycle. `includeCapacity` mirrors the daemon's
    /// "is it time for the expensive walk?" decision.
    public func runOnce(includeCapacity: Bool = true) async throws {
        let now = clock.now

        var metrics: [Metric] = []
        metrics += sample(collectors, now: now)
        if includeCapacity {
            metrics += sample(capacityCollectors, now: now)
        }

        if !metrics.isEmpty {
            do {
                try store.write(metrics)
            } catch {
                Self.log.error("failed to write \(metrics.count) metrics: \(error, privacy: .public)")
                throw error
            }
        }

        let volumes = alertVolumes()
        let events = try engine.evaluate(
            store: store,
            host: settings.hostLabel,
            volumes: volumes,
            now: now
        )
        for event in events {
            do {
                try store.write(event)
            } catch {
                Self.log.error("failed to persist alert: \(error, privacy: .public)")
                continue
            }
            await notifier.send(event)
        }
    }

    /// Run until cancelled. Each collector gets its own error boundary so a
    /// single bad volume cannot abort the cycle.
    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        Self.log.info("collector starting: host=\(self.settings.hostLabel, privacy: .public) volumes=\(self.settings.volumes.count)")

        while !Task.isCancelled {
            let now = clock.now
            let capacityDue = lastCapacityScan.map {
                now.timeIntervalSince($0) >= settings.capacityScanIntervalSeconds
            } ?? true

            do {
                try await runOnce(includeCapacity: capacityDue)
            } catch {
                Self.log.error("cycle failed: \(error, privacy: .public)")
            }
            if capacityDue {
                lastCapacityScan = now
            }

            do {
                try await clock.sleep(for: settings.pollIntervalSeconds)
            } catch {
                break // cancellation
            }
        }
        Self.log.info("collector stopped cleanly")
    }

    /// Cancel a running loop (equivalent of the Python SIGINT path).
    public func stop() {
        isRunning = false
    }

    // MARK: - Helpers

    private func sample(_ collectors: [any Collector], now: Date) -> [Metric] {
        var metrics: [Metric] = []
        for collector in collectors {
            do {
                metrics += try collector.sample(host: settings.hostLabel, now: now)
            } catch {
                Self.log.error(
                    "collection failed for \(String(describing: type(of: collector)), privacy: .public): \(error, privacy: .public)"
                )
            }
        }
        return metrics
    }

    /// Configured volume paths, falling back to whatever the collectors wrote
    /// if discovery fails.
    private func alertVolumes() -> [String] {
        if let discovered = try? volumeSource.volumes(), !discovered.isEmpty {
            return discovered.map(\.path)
        }
        let configured = settings.volumes.map(\.path)
        if !configured.isEmpty { return configured }
        return (try? store.volumes()) ?? []
    }
}
