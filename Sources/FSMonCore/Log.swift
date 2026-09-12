import Foundation

public final class Logger {
    public enum Level: String, CaseIterable {
        case debug, info, warn, error
        fileprivate var rank: Int { Self.allCases.firstIndex(of: self)! }
    }
    private let minimum: Level
    private let lock = NSLock()
    public init(level: Level = .info) { minimum = level }
    public func log(_ level: Level, _ message: String) {
        guard level.rank >= minimum.rank else { return }
        lock.lock(); defer { lock.unlock() }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level.rawValue)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    public func debug(_ message: String) { log(.debug, message) }
    public func info(_ message: String) { log(.info, message) }
    public func warn(_ message: String) { log(.warn, message) }
    public func error(_ message: String) { log(.error, message) }
}
