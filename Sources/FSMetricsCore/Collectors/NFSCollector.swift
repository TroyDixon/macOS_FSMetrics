import Foundation

/// NFS/pNFS health for one configured mount point.
///
/// Ported from Python `collector/nfs_shared.py::collect`:
///
/// - A mount whose `mountPoint` matches the injected ``NFSTool`` produces
///   `nfs.pnfs_enabled` (1/0) and `nfs.mount_ok` = 1.
/// - No match produces only `nfs.mount_ok` = 0.
/// - `timeout`/`retrans` client counters are best-effort health signals: a
///   throwing `clientCounters()` call is swallowed, exactly like Python's
///   `except Exception: pass`.
///
/// A `mounts()` failure propagates, mirroring Python's `run(check=True)`; the
/// service wraps each collector in its own error boundary.
public struct NFSCollector: Collector {
    private let volumePath: String
    private let mountPoint: String
    private let tool: any NFSTool

    public init(volumePath: String, mountPoint: String, tool: any NFSTool) {
        self.volumePath = volumePath
        self.mountPoint = mountPoint
        self.tool = tool
    }

    public func sample(host: String, now: Date) throws -> [Metric] {
        let mounts = try tool.mounts()
        let match = mounts.first { $0.mountPoint == mountPoint }

        var metrics: [Metric] = []
        if let match {
            metrics.append(Metric(
                kind: .pnfsEnabled, host: host, volume: volumePath,
                value: match.pnfs ? 1 : 0, ts: now
            ))
            metrics.append(Metric(
                kind: .nfsMountOK, host: host, volume: volumePath,
                value: 1, ts: now
            ))
        } else {
            metrics.append(Metric(
                kind: .nfsMountOK, host: host, volume: volumePath,
                value: 0, ts: now
            ))
        }

        if let counters = try? tool.clientCounters() {
            if let timeouts = counters["timeout"] {
                metrics.append(Metric(
                    kind: .nfsClientTimeouts, host: host, volume: volumePath,
                    value: Double(timeouts), ts: now
                ))
            }
            if let retransmits = counters["retrans"] {
                metrics.append(Metric(
                    kind: .nfsClientRetransmits, host: host, volume: volumePath,
                    value: Double(retransmits), ts: now
                ))
            }
        }

        return metrics
    }
}
