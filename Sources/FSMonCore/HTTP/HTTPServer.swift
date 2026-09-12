import Foundation
import Network

struct HTTPParseError: Error { let message: String; let status: Int }
/// Bounded, single-request parser. No transfer encoding, pipelining, or keep-alive.
enum HTTPParser {
    static let maxHeader = 16 * 1024
    static let maxBody = 64 * 1024
    static func parse(_ data: Data) throws -> Request? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeader { throw HTTPParseError(message: "Headers too large", status: 431) }
            return nil
        }
        guard boundary.upperBound <= maxHeader else { throw HTTPParseError(message: "Headers too large", status: 431) }
        guard let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw HTTPParseError(message: "Invalid headers", status: 400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(start[2])),
              ["GET", "POST", "OPTIONS"].contains(String(start[0])), start[1].hasPrefix("/"),
              !start[1].hasPrefix("//"), !start[1].contains("#"),
              let url = URLComponents(string: String(start[1])) else {
            throw HTTPParseError(message: "Invalid request line or unsupported method", status: 400)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError(message: "Invalid header", status: 400) }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[name] == nil else {
                throw HTTPParseError(message: "Invalid or duplicate header", status: 400)
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            throw HTTPParseError(message: "Transfer-Encoding and Expect are unsupported", status: 400)
        }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthText) else {
            throw HTTPParseError(message: "Invalid Content-Length", status: 400)
        }
        guard length <= maxBody else { throw HTTPParseError(message: "Body too large", status: 413) }
        let end = boundary.upperBound + length
        guard data.count >= end else { return nil }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(start[0]), path: url.percentEncodedPath, query: query, headers: headers, body: Data(data[boundary.upperBound..<end]))
    }
}

public final class HTTPServer {
    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var timer: DispatchSourceTimer?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private let queue = DispatchQueue(label: "fsmond.http")
    private let handlers = DispatchQueue(label: "fsmond.http.handlers", attributes: .concurrent)
    private let pending = DispatchGroup()
    private let listener: NWListener
    private let router: Router
    private let log: Logger
    private var clients: [UUID: Client] = [:]
    private var stopped = false
    public var onFailure: ((Error) -> Void)?

    public init(bind: String, port: UInt16, router: Router, log: Logger) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        self.router = router; self.log = log
    }
    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.log.info("HTTP listener ready on port \(self.listener.port?.rawValue ?? 0)")
            case .failed(let error): self.log.error("HTTP listener failed: \(error)"); self.onFailure?(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < 128 else { connection.cancel(); return }
        let id = UUID()
        let client = Client(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.remove(id); default: break }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10)
        timer.setEventHandler { [weak self] in self?.remove(id) }
        client.timer = timer
        timer.resume()
        connection.start(queue: queue)
        receive(id)
    }
    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, self.clients[id] != nil else { return }
            if let data { client.buffer.append(data) }
            do {
                if let request = try HTTPParser.parse(client.buffer) {
                    self.pending.enter()
                    self.handlers.async {
                        let response = self.router.handle(request)
                        self.queue.async { self.send(response, to: id) }
                        self.pending.leave()
                    }
                } else if complete || error != nil {
                    self.send(.error(.badRequest, message: "Incomplete request", status: 400), to: id)
                } else { self.receive(id) }
            } catch let error as HTTPParseError {
                self.send(.error(.badRequest, message: error.message, status: error.status), to: id)
            } catch { self.send(.error(.badRequest, message: "Invalid request", status: 400), to: id) }
        }
    }
    private func send(_ response: Response, to id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.send(content: response.wireData(), completion: .contentProcessed { [weak self] _ in self?.remove(id) })
    }
    private func remove(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timer?.cancel()
        client.connection.cancel()
    }
    /// Call off the HTTP queue; drains handlers before Database.close.
    public func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            for id in Array(clients.keys) { remove(id) }
        }
        pending.wait()
    }
}
