import Foundation
import os
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Dispatches a fired alert. Adapters: `AppleScriptNotifier` (default,
/// unsigned-safe), `UserNotificationNotifier`, `WebhookNotifier`,
/// `CompositeNotifier`, `NoopNotifier`.
public protocol Notifier: Sendable {
    func send(_ event: AlertEvent) async
}

/// Test ``Notifier`` that discards every event.
public struct NoopNotifier: Notifier {
    public init() {}

    public func send(_ event: AlertEvent) async {}
}

/// Fans an event out to several notifiers in order.
public struct CompositeNotifier: Notifier {
    private let notifiers: [any Notifier]

    public init(_ notifiers: [any Notifier]) {
        self.notifiers = notifiers
    }

    public func send(_ event: AlertEvent) async {
        for notifier in notifiers {
            await notifier.send(event)
        }
    }
}

/// Default notifier on an unsigned build: shells out to `osascript`, which
/// works with ad-hoc signing (unlike `UNUserNotificationCenter`).
public struct AppleScriptNotifier: Notifier {
    private let title: String
    private let runner: any CommandRunning
    private static let log = Logger(subsystem: "local.fsmetrics", category: "notify")

    public init(title: String = "macOS FS Metrics", runner: any CommandRunning = ProcessCommandRunner()) {
        self.title = title
        self.runner = runner
    }

    public func send(_ event: AlertEvent) async {
        let script = "display notification \"\(Self.escape(event.message))\" with title \"\(Self.escape(title))\""
        do {
            _ = try runner.run("/usr/bin/osascript", ["-e", script])
        } catch {
            // Alerting must never crash the collector loop.
            Self.log.error("osascript notification failed: \(error, privacy: .public)")
        }
    }

    /// Escape for an AppleScript double-quoted string literal. AppleScript
    /// strings do not support `\n`, so newlines collapse to spaces.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

/// POSTs `{"text": "..."}` to a Slack-compatible webhook. Errors are swallowed
/// so a broken webhook cannot disrupt collection.
public struct WebhookNotifier: Notifier {
    private let url: URL
    private let session: URLSession
    private static let log = Logger(subsystem: "local.fsmetrics", category: "notify")

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func send(_ event: AlertEvent) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try? JSONEncoder().encode(WebhookPayload(text: "[\(event.severity.rawValue.uppercased())] \(event.message)"))

        do {
            _ = try await session.data(for: request)
        } catch {
            Self.log.error("webhook failed: \(error, privacy: .public)")
        }
    }

    private struct WebhookPayload: Encodable {
        var text: String
    }
}

/// Best-effort native notification. `UNUserNotificationCenter` requires a
/// bundle identifier and is unreliable under ad-hoc signing, so this is a
/// no-op outside a real `.app` bundle.
public struct UserNotificationNotifier: Notifier {
    public init() {}

    public func send(_ event: AlertEvent) async {
        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "macOS FS Metrics"
        content.body = event.message
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
        #endif
    }
}
