import Foundation
import FSMetricsCore
import Observation
import os

enum WindowID {
    static let dashboard = "dashboard"
}

/// The app's single source of UI state. Views read models from here; only
/// `DashboardLoader` touches the store, and it runs off the main actor.
@MainActor
@Observable
final class AppModel {
    private(set) var settings: Settings
    private(set) var volumes: [VolumeSummary] = []
    private(set) var volumeNames: [String] = []
    private(set) var alerts: [AlertRow] = []
    private(set) var throughputPoints: [ChartPoint] = []
    private(set) var capacityPoints: [ChartPoint] = []
    private(set) var users: [UserUsage] = []
    private(set) var lastCapacityScan: Date?
    private(set) var lastRefresh: Date?
    private(set) var isCollecting = false
    private(set) var lastError: String?
    private(set) var iopsPoints: [ChartPoint] = []
    private(set) var ioSizePoints: [ChartPoint] = []
    private(set) var nfs: [NFSSummary] = []
    private(set) var latestIOPS: Double?
    private(set) var latestIOSizeKB: Double?

    /// One dashboard-wide volume selector, the way a Grafana template
    /// variable scopes every panel at once. The three per-panel selections
    /// below are kept in sync with it so `DashboardLoader` is untouched.
    var selectedVolume: String?

    var selectedThroughputVolume: String?
    var selectedCapacityVolume: String?
    var selectedUsersVolume: String?

    private var store: SQLiteMetricStore?
    private var engine = AlertEngine()
    private var service: CollectorService?
    @ObservationIgnored nonisolated(unsafe) private var collectionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    private let clock = SystemClock()

    private static let log = Logger(subsystem: "local.fsmetrics", category: "app")
    private static let refreshInterval: TimeInterval = 5

    init() {
        let loaded = (try? Settings.load()) ?? Settings()
        settings = loaded
        do {
            store = try SQLiteMetricStore(path: loaded.dbPath)
        } catch {
            store = nil
            lastError = "Could not open database at \(loaded.dbPath): \(error.localizedDescription)"
        }
        start()
    }

    deinit {
        collectionTask?.cancel()
        refreshTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the background collection loop and the UI refresh timer.
    func start() {
        rebuildService()

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(for: .seconds(Self.refreshInterval))
                } catch {
                    break
                }
            }
        }
    }

    /// Runs one full collection cycle (health/perf/NFS plus a capacity scan)
    /// and refreshes the read models.
    func runOnce() async {
        guard !isCollecting else { return }
        guard let service else {
            lastError = "No database is available; check the DB path in Settings."
            return
        }
        isCollecting = true
        defer { isCollecting = false }

        do {
            try await service.runOnce()
        } catch {
            lastError = error.localizedDescription
            Self.log.error("collection failed: \(error, privacy: .public)")
        }
        await refresh()
    }

    /// Reloads the read models from the store on a background task.
    func refresh() async {
        guard let store else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let settings = self.settings
        let selection = DashboardSelection(
            throughputVolume: selectedVolume,
            capacityVolume: selectedVolume,
            usersVolume: selectedVolume
        )
        let now = Date()

        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try DashboardLoader.load(
                    store: store,
                    settings: settings,
                    selection: selection,
                    now: now
                )
            }.value
            // A newer refresh started while this one was loading; its snapshot
            // is fresher than ours.
            guard generation == refreshGeneration else { return }
            apply(snapshot)
            lastRefresh = Date()
            lastError = nil
        } catch {
            guard generation == refreshGeneration else { return }
            lastError = error.localizedDescription
            Self.log.error("dashboard refresh failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Settings

    /// Persists `draft` through `Settings.save()` and rewires the live model.
    func save(_ draft: Settings) {
        do {
            try draft.save()
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
            return
        }

        let databaseChanged = draft.dbPath != settings.dbPath
        settings = draft
        if databaseChanged { reopenStore() }
        rebuildService()
        if store != nil { lastError = nil }
        Task { await refresh() }
    }

    /// Reloads `settings.json` through `Settings.load()` and rewires.
    @discardableResult
    func reloadFromDisk() -> Settings? {
        let loaded: Settings
        do {
            loaded = try Settings.load()
        } catch {
            lastError = "Could not load settings: \(error.localizedDescription)"
            return nil
        }

        let databaseChanged = loaded.dbPath != settings.dbPath
        settings = loaded
        if databaseChanged { reopenStore() }
        rebuildService()
        if store != nil { lastError = nil }
        Task { await refresh() }
        return loaded
    }

    // MARK: - Menu-bar projections

    /// Worst of the recent alerts and the capacity/health thresholds, mapped
    /// onto none/ok/warn/crit.
    var worstSeverity: StatusLevel {
        var level = StatusLevel.none
        for volume in volumes {
            level = max(level, volume.capacitySeverity(thresholds: settings.thresholds))
            level = max(level, volume.healthSeverity())
        }

        let horizon = Date().addingTimeInterval(-Self.alertFreshness(settings.thresholds))
        for alert in alerts where alert.ts >= horizon {
            level = max(level, alert.severity == .critical ? .critical : .warning)
        }
        return level
    }

    /// Most recent `perf.throughput_gbps` across the known volumes.
    var latestThroughput: Double? {
        volumes
            .compactMap { volume -> (age: TimeInterval, value: Double)? in
                guard let value = volume.throughputGbps,
                      let age = volume.throughputAgeSeconds else { return nil }
                return (age, value)
            }
            .min { $0.age < $1.age }?
            .value
    }

    var menuBarTitle: String {
        if let latestThroughput {
            return String(format: "%.2f GB/s", latestThroughput)
        }
        return worstSeverity.label
    }

    var lastScanDescription: String {
        MetricsFormat.age(lastCapacityScan)
    }

    // MARK: - KPI projections (the stat-tile row)

    /// The volume the dashboard is currently scoped to.
    var focusedVolume: VolumeSummary? {
        guard let selectedVolume else { return volumes.first }
        return volumes.first { $0.path == selectedVolume } ?? volumes.first
    }

    /// Capacity summed across every monitored volume, so the headline number
    /// describes the host rather than whichever volume happens to be picked.
    var fleetTotalBytes: Double? {
        fleetCapacity.totalBytes
    }

    var fleetUsedBytes: Double? {
        fleetCapacity.usedBytes
    }

    var fleetFreeBytes: Double? {
        guard let fleetTotalBytes, let fleetUsedBytes else { return nil }
        return max(0, fleetTotalBytes - fleetUsedBytes)
    }

    var fleetUsedPct: Double? {
        guard let fleetTotalBytes, fleetTotalBytes > 0, let fleetUsedBytes else { return nil }
        return fleetUsedBytes / fleetTotalBytes * 100
    }

    private var fleetCapacity: CapacityRollupResult {
        CapacityRollup.fleet(volumes.map { volume in
            CapacityRollupInput(
                totalBytes: volume.totalBytes,
                usedBytes: volume.displayUsedBytes,
                container: volume.container,
                containerTotalBytes: volume.containerTotalBytes,
                containerAvailableBytes: volume.containerAvailableBytes
            )
        })
    }

    var fleetCapacitySeverity: StatusLevel {
        guard let fleetUsedPct else { return .none }
        if fleetUsedPct >= settings.thresholds.capacityPctCrit { return .critical }
        if fleetUsedPct >= settings.thresholds.capacityPctWarn { return .warning }
        return .ok
    }

    /// Volumes whose health samples all look good, over the total monitored.
    var healthyVolumeCount: Int {
        volumes.filter { $0.healthSeverity() != .critical }.count
    }

    var healthSeverity: StatusLevel {
        var level = StatusLevel.none
        for volume in volumes {
            level = max(level, volume.healthSeverity())
        }
        return level
    }

    /// Alerts inside the menu-bar freshness window — "what's firing right
    /// now", not the whole history the alerts table shows.
    var activeAlerts: [AlertRow] {
        let horizon = Date().addingTimeInterval(-Self.alertFreshness(settings.thresholds))
        return alerts.filter { $0.ts >= horizon }
    }

    var activeAlertSeverity: StatusLevel {
        var level = StatusLevel.none
        for alert in activeAlerts {
            level = max(level, alert.severity == .critical ? .critical : .warning)
        }
        return level == .none && !volumes.isEmpty ? .ok : level
    }

    var throughputSeverity: StatusLevel {
        focusedVolume?.throughputGbps == nil ? .none : .ok
    }

    // MARK: - Wiring

    private func rebuildService() {
        collectionTask?.cancel()
        collectionTask = nil

        guard let store else {
            service = nil
            return
        }

        let wiring = CollectorWiring(settings: settings)
        let engine = AlertEngine(thresholds: settings.thresholds)
        let service = CollectorService(
            settings: settings,
            store: store,
            volumes: StaticVolumeSource(paths: wiring.volumes),
            collectors: wiring.pollCollectors,
            capacityCollectors: wiring.capacityCollectors,
            engine: engine,
            notifier: Self.makeNotifier(for: settings),
            clock: clock
        )
        self.engine = engine
        self.service = service
        collectionTask = Task { await service.run() }
    }

    private func reopenStore() {
        if let store { try? store.close() }
        do {
            store = try SQLiteMetricStore(path: settings.dbPath)
            lastError = nil
        } catch {
            store = nil
            lastError = "Could not open database at \(settings.dbPath): \(error.localizedDescription)"
        }
    }

    private func apply(_ snapshot: DashboardSnapshot) {
        volumes = snapshot.volumes
        volumeNames = snapshot.volumeNames
        alerts = snapshot.alerts
        selectedThroughputVolume = snapshot.throughputVolume
        throughputPoints = snapshot.throughputPoints
        selectedCapacityVolume = snapshot.capacityVolume
        capacityPoints = snapshot.capacityPoints
        selectedUsersVolume = snapshot.usersVolume
        users = snapshot.users
        lastCapacityScan = snapshot.lastCapacityScan
        iopsPoints = snapshot.iopsPoints
        ioSizePoints = snapshot.ioSizePoints
        nfs = snapshot.nfs
        latestIOPS = snapshot.latestIOPS
        latestIOSizeKB = snapshot.latestIOSizeKB
        // The loader resolves nil (or a stale name) to the first known
        // volume; adopt whatever it settled on so the picker shows the data
        // actually on screen.
        selectedVolume = snapshot.throughputVolume
    }

    private static func makeNotifier(for settings: Settings) -> any Notifier {
        var notifiers: [any Notifier] = [UserNotificationNotifier()]
        if let raw = settings.webhookURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw) {
            notifiers.append(WebhookNotifier(url: url))
        }
        guard notifiers.count > 1 else { return notifiers[0] }
        return CompositeNotifier(notifiers)
    }

    /// Alerts newer than this window weigh on the menu-bar badge. Never
    /// shorter than five minutes so a tiny cooldown cannot hide an incident.
    private static func alertFreshness(_ thresholds: AlertThresholds) -> TimeInterval {
        max(thresholds.cooldown, 300)
    }
}

/// Builds the production collector stack for the configured volumes, exactly
/// as the `fsmetrics` CLI would: health + performance per volume, NFS for
/// `.nfs`, capacity when `watchUsers` is set.
struct CollectorWiring: Sendable {
    var volumes: [(path: String, kind: VolumeKind, label: String)]
    var pollCollectors: [any Collector]
    var capacityCollectors: [any Collector]

    init(settings: Settings) {
        let commands = ProcessCommandRunner()
        let probe = DiskUtilProbe(commands: commands)
        let capacity = SystemCapacitySource()
        let blockStats = IOKitBlockStats()
        let nfsTool = NfsstatTool(commands: commands)
        let scanner = FileManagerScanner()

        var volumes: [(path: String, kind: VolumeKind, label: String)] = []
        var pollCollectors: [any Collector] = []
        var capacityCollectors: [any Collector] = []

        for volume in settings.volumes {
            volumes.append((path: volume.path, kind: volume.kind, label: volume.label))

            pollCollectors.append(HealthCollector(volumePath: volume.path, probe: probe, capacity: capacity))

            // Resolve the whole physical disk backing the volume (`disk0` for
            // an APFS container on `disk0s2`): `iostat` rejects synthesized
            // APFS devices. Falls back to `disk0` when inspection fails
            // (e.g. an unmounted NFS).
            let diskID = (try? probe.diskInfo(at: volume.path))?.preferredDiskID ?? "disk0"
            pollCollectors.append(PerformanceCollector(
                volumePath: volume.path,
                diskID: diskID,
                stats: blockStats,
                commands: commands
            ))

            if volume.kind == .nfs {
                pollCollectors.append(NFSCollector(
                    volumePath: volume.path,
                    mountPoint: volume.path,
                    tool: nfsTool
                ))
            }

            if volume.watchUsers {
                capacityCollectors.append(CapacityCollector(
                    volumePath: volume.path,
                    scanPaths: volume.scanPaths,
                    scanner: scanner
                ))
            }
        }

        self.volumes = volumes
        self.pollCollectors = pollCollectors
        self.capacityCollectors = capacityCollectors
    }
}
