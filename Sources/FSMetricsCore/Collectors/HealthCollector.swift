import Foundation
import os

/// Filesystem and backing-store health for one volume.
///
/// Ported from Python `collector/health.py::collect`: SMART and writable come
/// from the injected ``DiagnosticsProbe`` (`diskutil info -plist` in
/// production); capacity comes from the injected ``CapacitySource`` when one
/// is given. NVMe controller health is best-effort and never fails the
/// sample. A `diskInfo` failure is rethrown — the service has an error
/// boundary per collector.
public struct HealthCollector: Collector {
    /// `diskutil` SMART strings treated as healthy (Python `_OK_STATUSES`).
    private static let okStatuses: Set<String> = ["Verified", "verified", "OK"]

    private static let log = Logger(subsystem: "local.fsmetrics", category: "health")

    private let volumePath: String
    private let probe: any DiagnosticsProbe
    private let capacity: (any CapacitySource)?

    /// - Parameter capacity: Per-volume capacity. Production passes
    ///   ``SystemCapacitySource``. `nil` keeps the `diskutil` numbers from
    ///   `probe`, which recorded fixtures use; on current macOS those are
    ///   container-wide for APFS (`FreeSpace` is 0), so production must not
    ///   rely on them.
    public init(volumePath: String, probe: any DiagnosticsProbe, capacity: (any CapacitySource)? = nil) {
        self.volumePath = volumePath
        self.probe = probe
        self.capacity = capacity
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
        ]
        metrics += capacityMetrics(info: info, host: host, now: now)

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

    /// Total, used, free, and used % for the volume. When the capacity source
    /// cannot measure the volume honestly, the four metrics are skipped (and
    /// logged) rather than filled with container-wide numbers.
    private func capacityMetrics(info: DiskInfo, host: String, now: Date) -> [Metric] {
        if let capacity {
            do {
                let volume = try capacity.capacity(at: volumePath)
                var metrics = [
                    Metric(kind: .totalBytes, host: host, volume: volumePath, value: Double(volume.totalBytes), ts: now),
                    Metric(kind: .usedBytes, host: host, volume: volumePath, value: Double(volume.usedBytes), ts: now),
                    Metric(kind: .freeBytes, host: host, volume: volumePath, value: Double(volume.freeBytes), ts: now),
                    Metric(kind: .usedPct, host: host, volume: volumePath, value: volume.usedPct, ts: now),
                ]
                if let container = volume.container, let containerUsedPct = volume.containerUsedPct {
                    metrics += [
                        Metric(
                            kind: .containerTotalBytes, host: host, volume: volumePath,
                            value: Double(volume.totalBytes), username: container, ts: now
                        ),
                        Metric(
                            kind: .containerAvailableBytes, host: host, volume: volumePath,
                            value: Double(volume.availableBytes), username: container, ts: now
                        ),
                        Metric(
                            kind: .containerUsedPct, host: host, volume: volumePath,
                            value: containerUsedPct, username: container, ts: now
                        ),
                    ]
                }
                return metrics
            } catch {
                let path = volumePath
                Self.log.error("capacity sample skipped for \(path, privacy: .public): \(String(describing: error), privacy: .public)")
                return []
            }
        }

        return [
            Metric(kind: .totalBytes, host: host, volume: volumePath, value: Double(info.totalBytes), ts: now),
            Metric(kind: .usedBytes, host: host, volume: volumePath, value: Double(info.usedBytes), ts: now),
            Metric(kind: .freeBytes, host: host, volume: volumePath, value: Double(info.freeBytes), ts: now),
            Metric(
                kind: .usedPct, host: host, volume: volumePath,
                value: Self.usedPercent(used: info.usedBytes, total: info.totalBytes), ts: now
            ),
        ]
    }

    /// `round(100 * used / total, 2)`, guarding division by zero like Python
    /// `collector/health.py::capacity_pct`.
    private static func usedPercent(used: Int64, total: Int64) -> Double {
        guard total != 0 else { return 0 }
        let percent = 100.0 * Double(used) / Double(total)
        return (percent * 100).rounded() / 100
    }
}
