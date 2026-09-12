import Foundation

public enum JSON: Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([JSON]), object([String: JSON])

    public func encoded() throws -> Data {
        var output = ""
        append(to: &output)
        return Data(output.utf8)
    }

    private func append(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .integer(let value):
            output += String(value)
        case .number(let value):
            output += value.isFinite ? String(value) : "null"
        case .string(let value):
            appendEscaped(value, to: &output)
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.append(to: &output)
            }
            output += "]"
        case .object(let values):
            output += "{"
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                appendEscaped(key, to: &output)
                output += ":"
                values[key]!.append(to: &output)
            }
            output += "}"
        }
    }

    private func appendEscaped(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0C: output += "\\f"
            case 0x0D: output += "\\r"
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            case 0x00...0x1F: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
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
        try! .json(.object(["error": .object(["code": .string(code.rawValue), "message": .string(message)])]), status: status)
    }
    func wireData() -> Data {
        let reasons = [200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 404: "Not Found", 408: "Request Timeout", 413: "Payload Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        let headers = "HTTP/1.1 \(status) \(reasons[status] ?? "Response")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n"
        return Data(headers.utf8) + body
    }
}
