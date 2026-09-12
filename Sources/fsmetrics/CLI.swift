import Darwin
import Foundation
import FSMetricsCore

// MARK: - Exit status and errors

/// Process exit statuses shared by every command.
enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
}

/// An error that maps directly to an exit status.
enum CLIError: Error {
    /// Bad command line or unusable config: exit 2.
    case usage(String)
    /// A failure while doing real work: exit 1.
    case runtime(String)

    var exitCode: ExitCode {
        switch self {
        case .usage: return .usage
        case .runtime: return .failure
        }
    }

    var message: String {
        switch self {
        case .usage(let message), .runtime(let message): return message
        }
    }
}

/// Options parsed from a command's argument list.
struct ParsedOptions {
    /// Boolean flags present on the command line (`--once`).
    var flags: Set<String> = []
    /// `--name value` / `--name=value` options.
    var values: [String: String] = [:]
}

// MARK: - CLI

/// The hand-rolled `fsmetrics` command-line interface.
///
/// No argument-parsing dependency: the grammar is three fixed commands with a
/// handful of `--flag value` options each. Any unknown command, unknown flag,
/// stray positional argument, or unusable `--config` file exits 2.
enum FSMetricsCLI {
    /// Parses and runs one invocation. Never throws: every failure is mapped
    /// to an exit status and reported on stderr.
    static func run(arguments: [String]) async -> Int32 {
        do {
            return try await dispatch(arguments).rawValue
        } catch let error as CLIError {
            writeError("fsmetrics: \(error.message)")
            return error.exitCode.rawValue
        } catch {
            writeError("fsmetrics: \(error)")
            return ExitCode.failure.rawValue
        }
    }

    // MARK: Dispatch

    private static func dispatch(_ arguments: [String]) async throws -> ExitCode {
        guard let command = arguments.first else {
            printGeneralUsage(to: stderr)
            throw CLIError.usage("missing command; run 'fsmetrics --help'")
        }
        let rest = arguments.dropFirst()

        switch command {
        case "-h", "--help", "help":
            printGeneralUsage()
            return .success

        case "collect":
            if hasHelp(rest) {
                printCollectUsage()
                return .success
            }
            let options = try parseOptions(
                rest, command: command, flags: ["once"], valueFlags: ["config"]
            )
            return try await runCollect(options)

        case "status":
            if hasHelp(rest) {
                printStatusUsage()
                return .success
            }
            let options = try parseOptions(
                rest, command: command, flags: [], valueFlags: ["config"]
            )
            return try runStatus(options)

        case "export":
            if hasHelp(rest) {
                printExportUsage()
                return .success
            }
            let options = try parseOptions(
                rest, command: command, flags: [], valueFlags: ["format", "since", "config"]
            )
            return try runExport(options)

        default:
            printGeneralUsage(to: stderr)
            throw CLIError.usage("unknown command '\(command)'; run 'fsmetrics --help'")
        }
    }

    // MARK: Argument parsing

    private static func hasHelp(_ arguments: ArraySlice<String>) -> Bool {
        arguments.contains("--help") || arguments.contains("-h")
    }

    /// Parses `--flag` and `--name value` / `--name=value` options. Rejects
    /// anything else (including positionals) with a usage error.
    private static func parseOptions(
        _ arguments: ArraySlice<String>,
        command: String,
        flags: Set<String>,
        valueFlags: Set<String>
    ) throws -> ParsedOptions {
        var options = ParsedOptions()
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw CLIError.usage("unexpected argument '\(argument)' for '\(command)'")
            }

            let body = argument.dropFirst(2)
            let name: String
            let inlineValue: String?
            if let equals = body.firstIndex(of: "=") {
                name = String(body[..<equals])
                inlineValue = String(body[body.index(after: equals)...])
            } else {
                name = String(body)
                inlineValue = nil
            }

            if flags.contains(name) {
                guard inlineValue == nil else {
                    throw CLIError.usage("--\(name) does not take a value")
                }
                options.flags.insert(name)
            } else if valueFlags.contains(name) {
                if let inlineValue {
                    options.values[name] = inlineValue
                } else {
                    index = arguments.index(after: index)
                    guard index < arguments.endIndex else {
                        throw CLIError.usage("--\(name) requires a value")
                    }
                    options.values[name] = arguments[index]
                }
            } else {
                throw CLIError.usage("unknown option '--\(name)' for '\(command)'")
            }

            index = arguments.index(after: index)
        }

        return options
    }

    // MARK: Settings

    /// Loads settings from `--config <path>` when given. An explicit path that
    /// is missing or unparseable is a usage error (exit 2); with no `--config`,
    /// `Settings.load()` supplies defaults when the default file is absent.
    static func loadSettings(_ options: ParsedOptions) throws -> Settings {
        if let path = options.values["config"] {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError.usage("config file not found: \(path)")
            }
            do {
                return try Settings.load(from: url)
            } catch {
                throw CLIError.usage("could not parse config \(path): \(error)")
            }
        }

        do {
            return try Settings.load()
        } catch {
            throw CLIError.usage("could not parse \(Settings.defaultURL.path): \(error)")
        }
    }

    // MARK: Interrupts

    /// Resolves on the first SIGINT (Ctrl-C).
    ///
    /// The default terminate action is replaced so the running
    /// ``CollectorService`` can observe task cancellation and shut down
    /// cleanly instead of being killed mid-cycle.
    static func waitForInterrupt() async {
        let signals = AsyncStream<Void> { continuation in
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler {
                source.cancel()
                continuation.finish()
            }
            source.resume()
        }
        var iterator = signals.makeAsyncIterator()
        _ = await iterator.next()
    }

    // MARK: Reporting

    static func emit(_ text: String, to stream: UnsafeMutablePointer<FILE> = stdout) {
        fputs(text + "\n", stream)
    }

    static func writeError(_ message: String) {
        emit(message, to: stderr)
    }
}

// MARK: - Usage

extension FSMetricsCLI {
    static func printGeneralUsage(to stream: UnsafeMutablePointer<FILE> = stdout) {
        emit("""
        fsmetrics - local filesystem health, capacity, and I/O metrics

        Usage: fsmetrics <command> [options]

        Commands:
          collect [--once] [--config <path>]
              Collect health, performance, and capacity metrics.
              Runs continuously unless --once is given.
          status [--config <path>]
              Print the latest per-volume summary and recent alerts.
          export [--format json] [--since <hours>] [--config <path>]
              Write recent metric series and alerts as JSON to stdout.

        Global options:
          -h, --help
              Show this help (also available on each command).

        Exit codes: 0 success, 1 runtime failure, 2 usage or config error.
        """, to: stream)
    }

    static func printCollectUsage(to stream: UnsafeMutablePointer<FILE> = stdout) {
        emit("""
        Usage: fsmetrics collect [--once] [--config <path>]

        Options:
          --once            Run a single collection cycle and exit.
          --config <path>   JSON settings file
                            (default: \(Settings.defaultURL.path)).
          -h, --help        Show this help.

        With no --config, defaults are used when the settings file is absent.
        """, to: stream)
    }

    static func printStatusUsage(to stream: UnsafeMutablePointer<FILE> = stdout) {
        emit("""
        Usage: fsmetrics status [--config <path>]

        Options:
          --config <path>   JSON settings file
                            (default: \(Settings.defaultURL.path)).
          -h, --help        Show this help.

        Reads the database named by db_path. If it does not exist yet, prints a
        friendly "no data yet" message and exits 0.
        """, to: stream)
    }

    static func printExportUsage(to stream: UnsafeMutablePointer<FILE> = stdout) {
        emit("""
        Usage: fsmetrics export [--format json] [--since <hours>] [--config <path>]

        Options:
          --format <fmt>    Output format; only "json" is supported (default: json).
          --since <hours>   Include samples from the last N hours (default: 24).
          --config <path>   JSON settings file
                            (default: \(Settings.defaultURL.path)).
          -h, --help        Show this help.
        """, to: stream)
    }
}
