import Foundation

/// Filesystem and backing-store health for one volume.
///
/// Ported from Python `collector/health.py::collect`: the six core metrics
/// come from the injected ``DiagnosticsProbe`` (`diskutil info -plist` in
/// production); NVMe controller health is best-effort and never fails the
/// sample. A `diskInfo` failure is rethrown — the service has an error
/// boundary per collector.
public struct HealthCollector: Collector {
    /// `diskutil` SMART strings treated as healthy (Python `_OK_STATUSES`).
    private static let okStatuses: Set<String> = ["Verified", "verified", "OK"]

    private let volumePath: String
    private let probe: any DiagnosticsProbe

    public init(volumePath: String, probe: any DiagnosticsProbe) {
        self.volumePath = volumePath
        self.probe = probe
    }

    public func sample(host: String, now: Date) throws -> [Metric] {
        let info = try probe.diskInfo(at: volumePath)

        var metrics = [
            Metric(
                kind: .smartOK, host: host, volume: volumePath,
                value: Self.okStatuses.contains(info.smartStatus) ? 1 : 0, ts: now
            ),
            Metric(
                kind: .writable, host: host, volume: volumePath,
                value: info.writable ? 1 : 0, ts: now
            ),
            Metric(
                kind: .totalBytes, host: host, volume: volumePath,
                value: Double(info.totalBytes), ts: now
            ),
            Metric(
                kind: .usedBytes, host: host, volume: volumePath,
                value: Double(info.usedBytes), ts: now
            ),
            Metric(
                kind: .freeBytes, host: host, volume: volumePath,
                value: Double(info.freeBytes), ts: now
            ),
            Metric(
                kind: .usedPct, host: host, volume: volumePath,
                value: Self.usedPercent(used: info.usedBytes, total: info.totalBytes), ts: now
            ),
        ]

        // Best-effort: NVMe controller health (internal Apple Silicon storage
        // only; network/external volumes have no SPNVMe data). Any probe
        // failure is silently skipped, mirroring Python's `except: pass`.
        if let drives = try? probe.nvmeHealth() {
            for drive in drives {
                metrics.append(Metric(
                    kind: .nvmeSmartOK, host: host, volume: volumePath,
                    value: Self.okStatuses.contains(drive.smartStatus) ? 1 : 0,
                    username: drive.name, ts: now
                ))
            }
        }

        return metrics
    }

    /// `round(100 * used / total, 2)`, guarding division by zero like Python
    /// `collector/health.py::capacity_pct`.
    private static func usedPercent(used: Int64, total: Int64) -> Double {
        guard total != 0 else { return 0 }
        let percent = 100.0 * Double(used) / Double(total)
        return (percent * 100).rounded() / 100
    }
}
