import Foundation
import FSMetricsCore

// MARK: - collect

extension FSMetricsCLI {
    /// `fsmetrics collect [--once] [--config <path>]`.
    ///
    /// Opens the store, wires production adapters from `settings.volumes`,
    /// and runs one cycle (`--once`) or the cancellable loop.
    static func runCollect(_ options: ParsedOptions) async throws -> ExitCode {
        let settings = try loadSettings(options)

        let store: SQLiteMetricStore
        do {
            store = try SQLiteMetricStore(url: settings.dbURL)
        } catch {
            throw CLIError.runtime("could not open metrics database at \(settings.dbPath): \(error)")
        }
        defer { try? store.close() }

        let service = makeService(settings: settings, store: store)

        if options.flags.contains("once") {
            do {
                try await service.runOnce()
            } catch {
                throw CLIError.runtime("collection cycle failed: \(error)")
            }
            let volumesWithData = (try? store.volumes())?.count ?? 0
            emit("collect: cycle complete - host=\(settings.hostLabel), "
                + "configured volumes=\(settings.volumes.count), "
                + "volumes with data=\(volumesWithData), db=\(settings.dbPath)")
            return .success
        }

        emit("collect: starting loop - host=\(settings.hostLabel), "
            + "volumes=\(settings.volumes.count), "
            + "poll=\(settings.pollIntervalSeconds)s, "
            + "capacity scan=\(settings.capacityScanIntervalSeconds)s, "
            + "db=\(settings.dbPath) (Ctrl-C to stop)")

        let serviceTask = Task { await service.run() }
        await waitForInterrupt()
        serviceTask.cancel()
        _ = await serviceTask.value

        emit("collect: stopped cleanly")
        return .success
    }

    /// Builds the production collector graph from the configured volumes.
    ///
    /// The per-volume `diskID` for ``PerformanceCollector`` is best-effort:
    /// the whole physical disk backing the volume (`disk0` for an APFS
    /// container on `disk0s2`), since `iostat` rejects synthesized APFS
    /// devices. Falls back to `"disk0"` when the probe returns nothing or
    /// fails.
    static func makeService(settings: Settings, store: any MetricStore) -> CollectorService {
        let runner = ProcessCommandRunner()
        let probe = DiskUtilProbe(commands: runner)

        var collectors: [any Collector] = []
        var capacityCollectors: [any Collector] = []

        for volume in settings.volumes {
            collectors.append(HealthCollector(volumePath: volume.path, probe: probe))

            let diskID = (try? probe.diskInfo(at: volume.path))?.preferredDiskID ?? "disk0"
            collectors.append(PerformanceCollector(
                volumePath: volume.path,
                diskID: diskID,
                stats: IOKitBlockStats(),
                commands: runner
            ))

            if volume.kind == .nfs {
                collectors.append(NFSCollector(
                    volumePath: volume.path,
                    mountPoint: volume.path,
                    tool: NfsstatTool(commands: runner)
                ))
            }

            if volume.watchUsers {
                capacityCollectors.append(CapacityCollector(
                    volumePath: volume.path,
                    scanPaths: volume.scanPaths,
                    scanner: FileManagerScanner()
                ))
            }
        }

        let notifier: any Notifier
        if let rawURL = settings.webhookURL, let url = URL(string: rawURL) {
            notifier = CompositeNotifier([AppleScriptNotifier(), WebhookNotifier(url: url)])
        } else {
            notifier = AppleScriptNotifier()
        }

        return CollectorService(
            settings: settings,
            store: store,
            volumes: SystemVolumeSource(),
            collectors: collectors,
            capacityCollectors: capacityCollectors,
            engine: AlertEngine(thresholds: settings.thresholds),
            notifier: notifier,
            clock: SystemClock()
        )
    }
}

// MARK: - status

extension FSMetricsCLI {
    /// `fsmetrics status [--config <path>]`, a read-only summary of the store.
    static func runStatus(_ options: ParsedOptions) throws -> ExitCode {
        let settings = try loadSettings(options)

        guard FileManager.default.fileExists(atPath: settings.dbURL.path) else {
            emit("status: no data yet - \(settings.dbPath) does not exist. "
                + "Run 'fsmetrics collect' first.")
            return .success
        }

        let store: SQLiteMetricStore
        do {
            store = try SQLiteMetricStore(url: settings.dbURL)
        } catch {
            throw CLIError.runtime("could not open metrics database at \(settings.dbPath): \(error)")
        }
        defer { try? store.close() }

        let volumes: [String]
        do {
            volumes = try store.volumes()
        } catch {
            throw CLIError.runtime("could not read volumes: \(error)")
        }

        guard !volumes.isEmpty else {
            emit("status: no data yet - the metrics database is empty. "
                + "Run 'fsmetrics collect' first.")
            return .success
        }

        let now = Date()
        emit("FSMetrics status")
        emit("  host: \(settings.hostLabel)")
        emit("  db:   \(settings.dbPath)")

        for volume in volumes.sorted() {
            try printVolumeSummary(volume, store: store, now: now)
        }

        emit("")
        emit("Recent alerts (up to 5):")
        let alerts = try store.recentAlerts(limit: 5)
        if alerts.isEmpty {
            emit("  (none)")
        } else {
            for alert in alerts {
                emit("  [\(alert.severity.rawValue.uppercased())] "
                    + "\(alert.ts.formatted(.iso8601)) "
                    + "\(alert.volume): \(alert.message)")
            }
        }
        return .success
    }

    private static func printVolumeSummary(
        _ volume: String,
        store: any MetricQuery,
        now: Date
    ) throws {
        let usedPct = try store.latest(of: .usedPct, volume: volume)
        let total = try store.latest(of: .totalBytes, volume: volume)
        let free = try store.latest(of: .freeBytes, volume: volume)
        let smart = try store.latest(of: .smartOK, volume: volume)
        let writable = try store.latest(of: .writable, volume: volume)
        let throughput = try store.latest(of: .throughputGbps, volume: volume)

        var capacity = usedPct.map { String(format: "%.1f%% used", $0.value) } ?? "no sample"
        if let total {
            capacity += ", total \(formatBytes(total.value))"
        }
        if let free {
            capacity += ", free \(formatBytes(free.value))"
        }

        emit("")
        emit("Volume \(volume)")
        emit("  capacity:   \(capacity)")
        emit("  health:     \(healthText(smart: smart, writable: writable))")
        if let throughput {
            emit("  throughput: \(String(format: "%.3f", throughput.value)) GB/s "
                + "(age \(formatAge(throughput.ts, now: now)))")
        } else {
            emit("  throughput: no samples")
        }
    }

    private static func healthText(smart: Sample?, writable: Sample?) -> String {
        let smartText: String
        if let value = smart?.value {
            smartText = value == 1 ? "SMART ok" : "SMART not ok"
        } else {
            smartText = "SMART unknown"
        }

        let writableText: String
        if let value = writable?.value {
            writableText = value == 1 ? "writable" : "read-only"
        } else {
            writableText = "writability unknown"
        }
        return "\(smartText), \(writableText)"
    }
}

// MARK: - export

extension FSMetricsCLI {
    /// Shape of the `export --format json` document.
    private struct ExportPayload: Encodable {
        var host: String
        var generatedAt: Date
        /// `series[volume][metric_kind] = [{ts, value, uid, username}, ...]`.
        var series: [String: [String: [Sample]]]
        var alerts: [AlertEvent]

        enum CodingKeys: String, CodingKey {
            case host
            case generatedAt = "generated_at"
            case series
            case alerts
        }
    }

    /// `fsmetrics export [--format json] [--since <hours>] [--config <path>]`.
    ///
    /// The store has no "all metrics" query, so the series are enumerated as
    /// `MetricKind.allCases` x `store.volumes()`. Empty series are omitted.
    static func runExport(_ options: ParsedOptions) throws -> ExitCode {
        let format = (options.values["format"] ?? "json").lowercased()
        guard format == "json" else {
            throw CLIError.usage("unknown --format '\(format)' (supported: json)")
        }

        let hours: Double
        if let raw = options.values["since"] {
            guard let parsed = Double(raw), parsed.isFinite, parsed >= 0 else {
                throw CLIError.usage("--since expects a non-negative number of hours, got '\(raw)'")
            }
            hours = parsed
        } else {
            hours = 24
        }

        let settings = try loadSettings(options)
        let now = Date()
        let since = now.addingTimeInterval(-hours * 3600)

        var series: [String: [String: [Sample]]] = [:]
        var alerts: [AlertEvent] = []

        if FileManager.default.fileExists(atPath: settings.dbURL.path) {
            let store: SQLiteMetricStore
            do {
                store = try SQLiteMetricStore(url: settings.dbURL)
            } catch {
                throw CLIError.runtime(
                    "could not open metrics database at \(settings.dbPath): \(error)"
                )
            }
            defer { try? store.close() }

            for volume in try store.volumes() {
                for kind in MetricKind.allCases {
                    let samples = try store.series(of: kind, volume: volume, since: since)
                    guard !samples.isEmpty else { continue }
                    series[volume, default: [:]][kind.rawValue] = samples
                }
            }
            alerts = try store.recentAlerts(limit: 1000).filter { $0.ts >= since }
        }

        let payload = ExportPayload(
            host: settings.hostLabel,
            generatedAt: now,
            series: series,
            alerts: alerts
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return .success
    }
}

// MARK: - Formatting

extension FSMetricsCLI {
    /// SI byte sizes, matching the SI `GB/s` decision for throughput.
    static func formatBytes(_ bytes: Double) -> String {
        let magnitude = abs(bytes)
        if magnitude >= 1e12 { return String(format: "%.2f TB", bytes / 1e12) }
        if magnitude >= 1e9 { return String(format: "%.2f GB", bytes / 1e9) }
        if magnitude >= 1e6 { return String(format: "%.2f MB", bytes / 1e6) }
        if magnitude >= 1e3 { return String(format: "%.2f KB", bytes / 1e3) }
        return String(format: "%.0f B", bytes)
    }

    /// Compact "how long ago": seconds, minutes, hours, or days.
    static func formatAge(_ ts: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(ts))
        if seconds < 120 { return "\(Int(seconds))s" }
        if seconds < 7200 { return "\(Int(seconds / 60))m" }
        if seconds < 172_800 { return String(format: "%.1fh", seconds / 3600) }
        return String(format: "%.1fd", seconds / 86_400)
    }
}
