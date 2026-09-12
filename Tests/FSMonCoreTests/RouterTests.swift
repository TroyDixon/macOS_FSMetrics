import XCTest
@testable import FSMonCore

final class RouterTests: XCTestCase {
    func testParameterQueryAndStaticPrecedence() throws {
        let router = Router()
        router.get("/api/v1/mounts/{id}") { req in
            try .json(.object(["id": .string(req.parameters["id"]!), "from": .string(req.query["from"]!), "missing": .null]))
        }
        router.get("/api/v1/mounts/top") { _ in try .json(.string("static")) }
        let request = try XCTUnwrap(HTTPParser.parse(Data("GET /api/v1/mounts/mount%3A42?from=123 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)))
        let response = router.handle(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "mount:42")
        XCTAssertEqual(json["from"] as? String, "123")
        XCTAssertTrue(json["missing"] is NSNull)
        XCTAssertEqual(router.handle(Request(method: "GET", path: "/api/v1/mounts/top")).body, try JSON.string("static").encoded())
    }
    func test404ErrorAndCORS() throws {
        let response = Router().handle(Request(method: "GET", path: "/api/v1/nope"))
        XCTAssertEqual(response.status, 404)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: [String: String]])
        XCTAssertEqual(json["error"]?["code"], "not_found")
        let wire = String(decoding: response.wireData(), as: UTF8.self)
        XCTAssertTrue(wire.contains("Access-Control-Allow-Origin: *\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: \(response.body.count)\r\n"))
        XCTAssertEqual(Router().handle(Request(method: "OPTIONS", path: "/api/v1/scans")).status, 204)
    }
    func testHandlerErrorUsesInternalEnvelope() throws {
        struct Failure: Error {}
        let router = Router(log: Logger(level: .error))
        router.get("/fail") { _ in throw Failure() }
        let response = router.handle(Request(method: "GET", path: "/fail"))
        XCTAssertEqual(response.status, 500)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("\"code\":\"internal\""))
    }
    func testFragmentedBodyAndInvalidFraming() throws {
        let header = "POST /api/v1/scans HTTP/1.1\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try HTTPParser.parse(Data(header.utf8) + Data("{".utf8)))
        XCTAssertEqual(try HTTPParser.parse(Data((header + "{}").utf8))?.body, Data("{}".utf8))
        for headers in ["Content-Length: -1", "Content-Length: 1\r\nContent-Length: 2", "Transfer-Encoding: chunked", "Content-Length: 65537", "Expect: 100-continue", "Host : localhost"] {
            XCTAssertThrowsError(try HTTPParser.parse(Data("POST / HTTP/1.1\r\n\(headers)\r\n\r\n".utf8)))
        }
        XCTAssertThrowsError(try HTTPParser.parse(Data(repeating: 65, count: HTTPParser.maxHeader + 1)))
    }
    func testJSONUsesShortestNumbersAndPreservesNulls() throws {
        let data = try JSON.object([
            "used_pct": .number(81.6),
            "ratio": .number(0.1),
            "missing": .null,
            "invalid": .number(.infinity),
            "escaped": .string("quote\" slash\\ line\n tab\t control\u{1}"),
        ]).encoded()
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "{\"escaped\":\"quote\\\" slash\\\\ line\\n tab\\t control\\u0001\",\"invalid\":null,\"missing\":null,\"ratio\":0.1,\"used_pct\":81.6}"
        )
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}
