import Foundation

/// One NFS mount as reported by `nfsstat -m`.
public struct NFSMount: Sendable, Equatable {
    public var mountPoint: String
    public var server: String
    public var flags: String
    public var pnfs: Bool

    public init(mountPoint: String, server: String, flags: String, pnfs: Bool) {
        self.mountPoint = mountPoint
        self.server = server
        self.flags = flags
        self.pnfs = pnfs
    }
}

/// NFS/pNFS tooling seam. `NfsstatTool` is production; `FixtureNFSTool`
/// serves recorded outputs in tests. macOS exposes no clean API for pNFS
/// layout state, so this stays a CLI probe.
public protocol NFSTool: Sendable {
    func mounts() throws -> [NFSMount]
    /// Named integer client RPC counters from `nfsstat -c`.
    func clientCounters() throws -> [String: Int]
}

/// Production ``NFSTool``: runs `nfsstat -m` and `nfsstat -c` through the
/// injected ``CommandRunning``.
public struct NfsstatTool: NFSTool {
    private let commands: any CommandRunning

    public init(commands: any CommandRunning) {
        self.commands = commands
    }

    public func mounts() throws -> [NFSMount] {
        let data = try commands.run("nfsstat", ["-m"])
        return Self.parseMounts(String(decoding: data, as: UTF8.self))
    }

    public func clientCounters() throws -> [String: Int] {
        if let data = try? commands.run("nfsstat", ["-c", "-f", "JSON"]),
           let counters = Self.parseClientCountersJSON(String(decoding: data, as: UTF8.self)) {
            return counters
        }
        let data = try commands.run("nfsstat", ["-c"])
        return Self.parseClientCounters(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Parsing

    /// Ported from Python `collector/nfs_shared.py::parse_nfsstat_m`.
    ///
    /// Each block starts with a mount header at column zero. Linux prints
    /// `server:/export on /mount`; macOS prints `/mount from server:/export`.
    /// The first `Flags:` line after the header supplies the flag list, or,
    /// absent one (macOS), the last `NFS parameters:` line does: macOS emits
    /// an "Original mount options" block before the live "Current mount
    /// parameters" block, so the last value wins. `pnfs` anywhere in that
    /// list, case-insensitively, marks the mount as pNFS. Lines that are
    /// neither headers nor flags (lease times, etc.) are ignored.
    static func parseMounts(_ raw: String) -> [NFSMount] {
        var mounts: [NFSMount] = []
        var header: (server: String, mountPoint: String)?
        var flags = ""
        var flagsCaptured = false

        func flush() {
            guard let header else { return }
            mounts.append(NFSMount(
                mountPoint: header.mountPoint,
                server: header.server,
                flags: flags,
                pnfs: flags.lowercased().contains("pnfs")
            ))
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let parsed = Self.mountHeader(in: text) {
                flush()
                header = parsed
                flags = ""
                flagsCaptured = false
            } else if header != nil, !flagsCaptured, let range = text.range(of: "Flags:") {
                flagsCaptured = true
                flags = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if header != nil, !flagsCaptured, let range = text.range(of: "NFS parameters:") {
                // macOS: no `Flags:` line; the last `NFS parameters:` line is
                // the live `-- Current mount parameters` value.
                flags = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return mounts
    }

    /// Matches either mount-header orientation: Linux
    /// `server:/export on /mount` or macOS `/mount from server:/export`.
    private static func mountHeader(in line: String) -> (server: String, mountPoint: String)? {
        guard let first = line.first, !first.isWhitespace else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3 else { return nil }
        switch parts[1] {
        case "on":
            return (server: String(parts[0]), mountPoint: String(parts[2]))
        case "from":
            return (server: String(parts[2]), mountPoint: String(parts[0]))
        default:
            return nil
        }
    }

    /// Ported from Python `collector/nfs_shared.py::parse_nfsstat_client_counters`:
    /// `name: value` or `name value` lines, names lowercased, values integers.
    static func parseClientCounters(_ raw: String) -> [String: Int] {
        let counterRegex = /^\s*(\w+)\s*:?\s*(\d+)\s*$/
        var counters: [String: Int] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = try? counterRegex.wholeMatch(in: String(line)),
                  let value = Int(match.2)
            else { continue }
            counters[match.1.lowercased()] = value
        }
        return counters
    }

    /// Maps macOS `nfsstat -c -f JSON` client counters onto the keys
    /// ``NFSCollector`` consumes (`TimedOut` -> `timeout`, `Retries` ->
    /// `retrans`), plus `requests`/`invalid` for completeness. Returns nil when
    /// the document has no `Client Info` -> `RPC Info` object, so the caller can
    /// fall back to the text parser.
    static func parseClientCountersJSON(_ raw: String) -> [String: Int]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let root = object as? [String: Any],
              let client = root["Client Info"] as? [String: Any],
              let rpc = client["RPC Info"] as? [String: Any]
        else { return nil }

        var counters: [String: Int] = [:]
        if let value = rpc["TimedOut"] as? Int { counters["timeout"] = value }
        if let value = rpc["Retries"] as? Int { counters["retrans"] = value }
        if let value = rpc["Requests"] as? Int { counters["requests"] = value }
        if let value = rpc["Invalid"] as? Int { counters["invalid"] = value }
        return counters
    }
}

/// Test ``NFSTool`` serving fixed outputs and an optional forced counters
/// failure.
public struct FixtureNFSTool: NFSTool {
    private let storedMounts: [NFSMount]
    private let storedCounters: [String: Int]
    private let countersError: (any Error)?

    public init(
        mounts: [NFSMount] = [],
        counters: [String: Int] = [:],
        countersError: (any Error)? = nil
    ) {
        self.storedMounts = mounts
        self.storedCounters = counters
        self.countersError = countersError
    }

    public func mounts() throws -> [NFSMount] {
        storedMounts
    }

    public func clientCounters() throws -> [String: Int] {
        if let countersError { throw countersError }
        return storedCounters
    }
}
