import Foundation

public enum JSON: Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([JSON]), object([String: JSON])
    private var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return value
        case .number(let value): return value.isFinite ? value as Any : NSNull()
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let values): return values.mapValues(\.foundationValue)
        }
    }
    public func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: foundationValue, options: [.sortedKeys, .fragmentsAllowed])
    }
}
public struct Response {
    public let status: Int
    public let body: Data
    public let contentType: String
    public init(status: Int = 200, body: Data, contentType: String = "application/json") {
        self.status = status; self.body = body; self.contentType = contentType
    }
    public static func json(_ value: JSON, status: Int = 200) throws -> Response {
        Response(status: status, body: try value.encoded())
    }
    public enum ErrorCode: String { case notFound = "not_found", badRequest = "bad_request", collectorUnavailable = "collector_unavailable", `internal` }
    public static func error(_ code: ErrorCode, message: String, status: Int) -> Response {
        // Strings alone cannot cause JSONSerialization to fail.
        try! .json(.object(["error": .object(["code": .string(code.rawValue), "message": .string(message)])]), status: status)
    }
    func wireData() -> Data {
        let reasons = [200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 404: "Not Found", 408: "Request Timeout", 413: "Payload Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        let headers = "HTTP/1.1 \(status) \(reasons[status] ?? "Response")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n"
        return Data(headers.utf8) + body
    }
}
