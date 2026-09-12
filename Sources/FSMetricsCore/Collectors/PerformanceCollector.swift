import Foundation

/// Live I/O throughput for one volume.
///
/// Primary path: diff cumulative ``BlockCounters`` from the injected
/// ``BlockStatsSource`` (IOKit `IOBlockStorageDriver` in production) over the
/// elapsed wall time between `sample` calls. The previous counter/timestamp
/// pair is retained internally per collector instance — an internal seam, not
/// part of the `Collector` interface.
///
/// Fallback: run `iostat -d -c 2 <disk>` through the injected
/// ``CommandRunning`` and parse the last numeric row (`-c 2` makes the first
/// row a since-boot average, which Python discards). The iostat row always
/// supplies `perf.transfers_per_sec` and `perf.kb_per_transfer` when it parses,
/// even if the IOKit rate won.
///
/// ## Units
///
/// The plan (§17) resolves the Python ambiguity in favour of SI: the metric is
/// bytes-per-second in units of 1e9 (`GB/s`, matching ``Unit/gbps``). macOS
/// `iostat` labels its third column "MB/s" but reports MiB/s (2^20 bytes), so
/// the fallback converts `mbPerSec * 1_048_576 / 1_000_000_000` — unlike
/// Python `collector/performance.py:65`, which divided by 1024 (implicitly
/// GiB/s).
///
/// Both sources failing yields `[]`; a failed stats call is ignored so the
/// previous retained counters remain the baseline for the next attempt.
public final class PerformanceCollector: Collector, @unchecked Sendable {
    /// Previous cumulative reading per device, an internal seam.
    private struct Retained {
        var counters: BlockCounters
        var ts: Date
    }

    /// One parsed `KB/t tps MB/s` row from macOS `iostat`.
    private struct IostatRow {
        var kbPerTransfer: Double
        var transfersPerSec: Double
        var mbPerSec: Double
    }

    private let volumePath: String
    private let diskID: String
    private let stats: any BlockStatsSource
    private let commands: any CommandRunning

    private let lock = NSLock()
    private var previous: Retained?

    public init(
        volumePath: String,
        diskID: String,
        stats: any BlockStatsSource,
        commands: any CommandRunning
    ) {
        self.volumePath = volumePath
        self.diskID = diskID
        self.stats = stats
        self.commands = commands
    }

    public func sample(host: String, now: Date) throws -> [Metric] {
        let iokitRate = throughputFromCounters(now: now)
        let iostatRow = runIostat()

        var metrics: [Metric] = []

        if let iokitRate {
            metrics.append(Metric(
                kind: .throughputGbps, host: host, volume: volumePath,
                value: iokitRate, ts: now
            ))
        } else if let iostatRow {
            metrics.append(Metric(
                kind: .throughputGbps, host: host, volume: volumePath,
                value: Self.siGBPerSecond(mebibytesPerSecond: iostatRow.mbPerSec),
                ts: now
            ))
        }

        if let iostatRow {
            metrics.append(Metric(
                kind: .transfersPerSec, host: host, volume: volumePath,
                value: iostatRow.transfersPerSec, ts: now
            ))
            metrics.append(Metric(
                kind: .kbPerTransfer, host: host, volume: volumePath,
                value: iostatRow.kbPerTransfer, ts: now
            ))
        }

        return metrics
    }

    // MARK: - IOKit counters

    /// Diffs the current cumulative counters against the previously retained
    /// reading. Returns nil until a second successful reading exists, when the
    /// elapsed time is not positive, or when a counter reset (negative delta)
    /// is detected; the fresh reading is still retained in all those cases.
    /// A throwing stats call is ignored entirely.
    private func throughputFromCounters(now: Date) -> Double? {
        let counters: BlockCounters
        do {
            counters = try stats.counters(device: diskID)
        } catch {
            return nil
        }

        lock.lock()
        let previous = self.previous
        self.previous = Retained(counters: counters, ts: now)
        lock.unlock()

        guard let previous else { return nil }

        let elapsed = now.timeIntervalSince(previous.ts)
        guard elapsed > 0 else { return nil }

        let deltaRead = Double(counters.bytesRead) - Double(previous.counters.bytesRead)
        let deltaWrite = Double(counters.bytesWritten) - Double(previous.counters.bytesWritten)
        guard deltaRead >= 0, deltaWrite >= 0 else { return nil }

        return (deltaRead + deltaWrite) / elapsed / 1_000_000_000
    }

    // MARK: - iostat fallback

    private func runIostat() -> IostatRow? {
        guard let data = try? commands.run("iostat", ["-d", "-c", "2", diskID]) else {
            return nil
        }
        return Self.parseLastIostatRow(String(decoding: data, as: UTF8.self))
    }

    /// macOS `iostat` "MB/s" is MiB/s: 1 MiB/s = 1_048_576 / 1e9 SI GB/s.
    /// (Plan §17 chose SI `GB/s` over Python's implicit GiB/s division by 1024.)
    private static func siGBPerSecond(mebibytesPerSecond mibPerSec: Double) -> Double {
        mibPerSec * 1_048_576 / 1_000_000_000
    }

    /// Keeps only the last numeric `KB/t tps MB/s` row, exactly like Python
    /// `collector/performance.py::parse_iostat` + `collect()`.
    ///
    /// The row regex mirrors Python's `^\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$`;
    /// header and device-name lines do not match.
    private static func parseLastIostatRow(_ raw: String) -> IostatRow? {
        let rowRegex = /^\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$/
        var last: IostatRow?

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = try? rowRegex.wholeMatch(in: String(line)),
                  let kbPerTransfer = Double(match.1),
                  let transfersPerSec = Double(match.2),
                  let mbPerSec = Double(match.3)
            else { continue }

            last = IostatRow(
                kbPerTransfer: kbPerTransfer,
                transfersPerSec: transfersPerSec,
                mbPerSec: mbPerSec
            )
        }
        return last
    }
}
