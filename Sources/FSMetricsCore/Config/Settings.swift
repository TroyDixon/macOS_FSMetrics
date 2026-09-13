import Foundation

/// Alert thresholds. Ported from Python `collector/config.py::AlertThresholds`,
/// plus `cooldown`, which suppresses duplicate alerts (a fix over the Python
/// behavior where the same alert re-fired every poll).
public struct AlertThresholds: Codable, Sendable, Equatable {
    public var capacityPctWarn: Double
    public var capacityPctCrit: Double
    /// Lookback window for the per-user growth rule.
    public var userGrowthWindow: TimeInterval
    /// Growth (bytes) within the window that trips the user-growth alert.
    public var userGrowthThreshold: Double
    /// Retained for parity with the Python config; not yet used by a rule.
    public var ioErrorCountThreshold: Int
    /// No throughput sample within this window means stalled.
    public var throughputStallSeconds: TimeInterval
    /// Suppress an identical alert (same rule + volume + uid) seen within this
    /// window.
    public var cooldown: TimeInterval

    public init(
        capacityPctWarn: Double = 80,
        capacityPctCrit: Double = 95,
        userGrowthWindow: TimeInterval = 600,
        userGrowthThreshold: Double = 5e9,
        ioErrorCountThreshold: Int = 1,
        throughputStallSeconds: TimeInterval = 120,
        cooldown: TimeInterval = 3600
    ) {
        self.capacityPctWarn = capacityPctWarn
        self.capacityPctCrit = capacityPctCrit
        self.userGrowthWindow = userGrowthWindow
        self.userGrowthThreshold = userGrowthThreshold
        self.ioErrorCountThreshold = ioErrorCountThreshold
        self.throughputStallSeconds = throughputStallSeconds
        self.cooldown = cooldown
    }

    enum CodingKeys: String, CodingKey {
        case capacityPctWarn = "capacity_pct_warn"
        case capacityPctCrit = "capacity_pct_crit"
        case userGrowthWindow = "user_growth_bytes_window"
        case userGrowthThreshold = "user_growth_bytes_threshold"
        case ioErrorCountThreshold = "io_error_count_threshold"
        case throughputStallSeconds = "throughput_stall_seconds"
        case cooldown
    }
}

/// One watched volume. Mirrors Python `VolumeConfig` (`config.yaml` `volumes:`
/// entries) and defaults `label` -> `path`, `scanPaths` -> `[path]`.
public struct VolumeSettings: Codable, Sendable, Equatable {
    public var path: String
    public var kind: VolumeKind
    public var label: String
    public var watchUsers: Bool
    /// Per-volume absolute per-user cap: a user's newest `capacity.user_bytes`
    /// at or above this fires a `user_quota` alert for this volume only. 0
    /// disables it.
    public var userQuotaBytes: Double
    public var scanPaths: [String]

    public init(
        path: String,
        kind: VolumeKind = .other,
        label: String? = nil,
        watchUsers: Bool = true,
        userQuotaBytes: Double = 0,
        scanPaths: [String]? = nil
    ) {
        self.path = path
        self.kind = kind
        self.label = label?.isEmpty == false ? label! : path
        self.watchUsers = watchUsers
        self.userQuotaBytes = userQuotaBytes
        self.scanPaths = (scanPaths?.isEmpty == false) ? scanPaths! : [path]
    }

    enum CodingKeys: String, CodingKey {
        case path
        case kind
        case label
        case watchUsers = "watch_users"
        case userQuotaBytes = "user_quota_bytes"
        case scanPaths = "scan_paths"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        self.init(
            path: path,
            kind: try c.decodeIfPresent(VolumeKind.self, forKey: .kind) ?? .other,
            label: try c.decodeIfPresent(String.self, forKey: .label),
            watchUsers: try c.decodeIfPresent(Bool.self, forKey: .watchUsers) ?? true,
            userQuotaBytes: try c.decodeIfPresent(Double.self, forKey: .userQuotaBytes) ?? 0,
            scanPaths: try c.decodeIfPresent([String].self, forKey: .scanPaths)
        )
    }
}

/// Codable settings, the Swift successor to `config.yaml` + `collector/config.py`.
/// Keys stay snake_case so a converted JSON config reads naturally.
public struct Settings: Codable, Sendable, Equatable {
    public var dbPath: String
    public var pollIntervalSeconds: TimeInterval
    public var capacityScanIntervalSeconds: TimeInterval
    public var hostLabel: String
    public var volumes: [VolumeSettings]
    public var thresholds: AlertThresholds
    public var webhookURL: String?
    public var simulate: Bool

    public init(
        dbPath: String = Settings.defaultDBPath,
        pollIntervalSeconds: TimeInterval = 15,
        capacityScanIntervalSeconds: TimeInterval = 120,
        hostLabel: String = Settings.defaultHostLabel,
        volumes: [VolumeSettings] = [VolumeSettings(path: "/", kind: .apfs)],
        thresholds: AlertThresholds = AlertThresholds(),
        webhookURL: String? = nil,
        simulate: Bool = false
    ) {
        self.dbPath = dbPath
        self.pollIntervalSeconds = pollIntervalSeconds
        self.capacityScanIntervalSeconds = capacityScanIntervalSeconds
        self.hostLabel = hostLabel
        self.volumes = volumes
        self.thresholds = thresholds
        self.webhookURL = webhookURL
        self.simulate = simulate
    }

    enum CodingKeys: String, CodingKey {
        case dbPath = "db_path"
        case pollIntervalSeconds = "poll_interval_seconds"
        case capacityScanIntervalSeconds = "capacity_scan_interval_seconds"
        case hostLabel = "host_label"
        case volumes
        case thresholds
        case webhookURL = "webhook_url"
        case simulate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dbPath: try c.decodeIfPresent(String.self, forKey: .dbPath) ?? Settings.defaultDBPath,
            pollIntervalSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .pollIntervalSeconds) ?? 15,
            capacityScanIntervalSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .capacityScanIntervalSeconds) ?? 120,
            hostLabel: try c.decodeIfPresent(String.self, forKey: .hostLabel) ?? Settings.defaultHostLabel,
            volumes: try c.decodeIfPresent([VolumeSettings].self, forKey: .volumes) ?? [VolumeSettings(path: "/", kind: .apfs)],
            thresholds: try c.decodeIfPresent(AlertThresholds.self, forKey: .thresholds) ?? AlertThresholds(),
            webhookURL: try c.decodeIfPresent(String.self, forKey: .webhookURL),
            simulate: try c.decodeIfPresent(Bool.self, forKey: .simulate) ?? false
        )
    }

    // MARK: - Defaults and file I/O

    /// `dbPath` with `~` expanded and the path normalized, safe for
    /// `FileManager` existence checks and for opening the store.
    public var dbURL: URL {
        URL(fileURLWithPath: dbPath).standardizedFileURL
    }

    /// `~/Library/Application Support/FSMetrics`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FSMetrics", isDirectory: true)
    }

    /// `~/Library/Application Support/FSMetrics/metrics.sqlite`
    public static var defaultDBPath: String {
        supportDirectory.appendingPathComponent("metrics.sqlite").path
    }

    /// `~/Library/Application Support/FSMetrics/settings.json`
    public static var defaultURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    public static var defaultHostLabel: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    public static func load(from url: URL = Settings.defaultURL) throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Settings()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    public func save(to url: URL = Settings.defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
