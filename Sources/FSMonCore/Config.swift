import Foundation
import Darwin

public struct Config {
    public var dbPath = "./data/fsmon.db"
    public var port: UInt16 = 8080
    public var bind = "127.0.0.1"
    public var logLevel: Logger.Level = .info
    public static let usage = "Usage: fsmond [--config path] [--db path] [--port 8080] [--bind 127.0.0.1] [--log-level debug|info|warn|error]"
    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }
    public init(arguments: [String]) throws {
        var flags: [String: String] = [:]
        var index = 0
        let keys: Set<String> = ["config", "db", "port", "bind", "log-level"]
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), keys.contains(String(argument.dropFirst(2))), index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { throw Invalid(description: "Invalid or missing option: \(argument)") }
            flags[String(argument.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        var values: [String: String] = [:]
        if let path = flags["config"] {
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            for (number, raw) in contents.components(separatedBy: .newlines).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, keys.subtracting(["config"]).contains(parts[0]), !parts[1].isEmpty else {
                    throw Invalid(description: "Invalid config entry at line \(number + 1)")
                }
                values[parts[0]] = parts[1]
            }
        }
        values.merge(flags) { _, flag in flag }
        if let path = values["db"] {
            guard !path.isEmpty else { throw Invalid(description: "Database path cannot be empty") }
            dbPath = path
        }
        if let text = values["port"] {
            guard let parsed = UInt16(text), parsed > 0 else { throw Invalid(description: "Port must be 1...65535") }
            port = parsed
        }
        if let value = values["bind"] {
            var v4 = in_addr(); var v6 = in6_addr()
            guard inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1 else {
                throw Invalid(description: "Bind must be an IPv4 or IPv6 address")
            }
            bind = value
        }
        if let text = values["log-level"] {
            guard let level = Logger.Level(rawValue: text) else { throw Invalid(description: "Invalid log level: \(text)") }
            logLevel = level
        }
    }
}
