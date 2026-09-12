import Foundation

public struct Request {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data
    public internal(set) var parameters: [String: String] = [:]
    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }
}

/// Register routes at startup. Handlers can run concurrently; use Database.read/write.
public final class Router {
    public typealias Handler = (Request) throws -> Response
    private struct Route { let method: String; let parts: [String]; let handler: Handler }
    private let lock = NSLock()
    private var routes: [Route] = []
    private let log: Logger
    public init(log: Logger = Logger()) { self.log = log }
    public func get(_ path: String, handler: @escaping Handler) { register("GET", path, handler) }
    public func post(_ path: String, handler: @escaping Handler) { register("POST", path, handler) }
    private func register(_ method: String, _ path: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        let parts = path.split(separator: "/").map(String.init)
        precondition(!routes.contains { $0.method == method && $0.parts == parts }, "Duplicate route")
        routes.append(Route(method: method, parts: parts, handler: handler))
        // Static routes (e.g. /scans/top) take precedence over parameter routes.
        routes.sort { $0.parts.filter { !$0.hasPrefix("{") }.count > $1.parts.filter { !$0.hasPrefix("{") }.count }
    }
    public func handle(_ request: Request) -> Response {
        if request.method == "OPTIONS" { return Response(status: 204, body: Data()) }
        let parts = request.path.split(separator: "/").map(String.init)
        lock.lock(); let snapshot = routes; lock.unlock()
        for route in snapshot where route.method == request.method && route.parts.count == parts.count {
            var parameters: [String: String] = [:]
            var matches = true
            for (pattern, value) in zip(route.parts, parts) {
                if pattern.hasPrefix("{") && pattern.hasSuffix("}") {
                    guard let decoded = value.removingPercentEncoding else {
                        return .error(.badRequest, message: "Invalid path encoding", status: 400)
                    }
                    parameters[String(pattern.dropFirst().dropLast())] = decoded
                } else if pattern != value { matches = false; break }
            }
            if matches {
                var matched = request
                matched.parameters = parameters
                do { return try route.handler(matched) }
                catch {
                    log.error("HTTP handler failed: \(error)")
                    return .error(.internal, message: "Internal server error", status: 500)
                }
            }
        }
        return .error(.notFound, message: "No route for \(request.method) \(request.path)", status: 404)
    }
}
