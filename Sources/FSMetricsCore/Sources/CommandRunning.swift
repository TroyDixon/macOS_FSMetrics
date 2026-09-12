import Foundation

/// Runs a CLI probe and returns raw stdout bytes.
///
/// Implementations MUST NOT build shell strings: pass the tool and its
/// arguments separately. Missing tools or non-zero exits should throw; callers
/// degrade gracefully.
public protocol CommandRunning: Sendable {
    func run(_ tool: String, _ args: [String]) throws -> Data
}

/// A probe failed to run or reported a non-zero exit.
public struct CommandError: Error, Sendable, Equatable {
    public var tool: String
    public var args: [String]
    public var status: Int32
    public var stderr: String

    public init(tool: String, args: [String], status: Int32, stderr: String) {
        self.tool = tool
        self.args = args
        self.status = status
        self.stderr = stderr
    }
}

/// Conventional exit status for "command not found".
private let commandNotFoundStatus: Int32 = 127

/// Production ``CommandRunning`` adapter: launches the tool directly with
/// `Process` and never builds a shell command.
///
/// Absolute (or explicitly relative) tool paths are used as-is; a bare tool
/// name is searched across `PATH` for an executable file. A tool that runs
/// longer than ``timeout`` is terminated, and a non-zero exit is reported as
/// ``CommandError`` with the captured stderr text.
public struct ProcessCommandRunner: CommandRunning {
    /// Timeout applied to every ``run(_:_:)`` call, in seconds.
    public static let defaultTimeout: TimeInterval = 15

    /// How long a timed-out process may take to exit after `SIGTERM` before it
    /// is killed with `SIGKILL`.
    public static let terminationGracePeriod: TimeInterval = 2

    /// Maximum time a tool may run before it is terminated.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = ProcessCommandRunner.defaultTimeout) {
        self.timeout = timeout
    }

    public func run(_ tool: String, _ args: [String]) throws -> Data {
        guard let executableURL = Self.resolveExecutable(tool) else {
            throw CommandError(
                tool: tool, args: args, status: commandNotFoundStatus,
                stderr: "executable not found: \(tool)"
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes concurrently so a chatty child cannot deadlock on a
        // full pipe buffer.
        let stdout = DataBox()
        let stderr = DataBox()
        let ioGroup = DispatchGroup()
        Self.drain(stdoutPipe.fileHandleForReading, into: stdout, group: ioGroup)
        Self.drain(stderrPipe.fileHandleForReading, into: stderr, group: ioGroup)

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            // Launch failed before the child inherited the pipes; close the
            // write ends so the drains do not wait forever.
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            ioGroup.wait()
            throw CommandError(
                tool: tool, args: args, status: commandNotFoundStatus,
                stderr: "failed to launch \(tool): \(error.localizedDescription)"
            )
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + Self.terminationGracePeriod) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            ioGroup.wait()
            throw CommandError(
                tool: tool, args: args, status: process.terminationStatus,
                stderr: "timed out after \(timeout)s"
            )
        }

        ioGroup.wait()
        guard process.terminationStatus == 0 else {
            throw CommandError(
                tool: tool, args: args, status: process.terminationStatus,
                stderr: String(decoding: stderr.value, as: UTF8.self)
            )
        }
        return stdout.value
    }

    /// Resolves `tool` to an executable URL: names containing `/` are used
    /// as-is, bare names are searched across `PATH`.
    static func resolveExecutable(_ tool: String) -> URL? {
        let fileManager = FileManager.default
        if tool.contains("/") {
            guard fileManager.isExecutableFile(atPath: tool) else { return nil }
            return URL(fileURLWithPath: tool)
        }

        let searchPath = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(tool)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private static func drain(_ handle: FileHandle, into box: DataBox, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.set(handle.readDataToEndOfFile())
            group.leave()
        }
    }
}

/// Thread-safe byte accumulator for the concurrent pipe drains.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage = data
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Test ``CommandRunning`` adapter keyed by ``key(_:_:)``.
///
/// Fixtures hold recorded stdout bytes; a missing key throws ``CommandError``
/// so tests fail with the requested invocation and the registered keys.
public struct FixtureCommandRunner: CommandRunning {
    /// Fixture stdout keyed by ``key(_:_:)``.
    public let fixtures: [String: Data]

    public init(fixtures: [String: Data]) {
        self.fixtures = fixtures
    }

    /// Convenience for text fixtures; values are encoded as UTF-8.
    public init(fixtures: [String: String]) {
        self.init(fixtures: fixtures.mapValues { Data($0.utf8) })
    }

    /// The lookup key for one invocation: `"tool arg1 arg2"`.
    public static func key(_ tool: String, _ args: [String]) -> String {
        ([tool] + args).joined(separator: " ")
    }

    public func run(_ tool: String, _ args: [String]) throws -> Data {
        let key = Self.key(tool, args)
        guard let data = fixtures[key] else {
            let available = fixtures.keys.sorted().joined(separator: ", ")
            throw CommandError(
                tool: tool, args: args, status: commandNotFoundStatus,
                stderr: "no fixture registered for '\(key)' (available: \(available))"
            )
        }
        return data
    }
}
