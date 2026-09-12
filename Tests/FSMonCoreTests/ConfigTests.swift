import XCTest
@testable import FSMonCore

final class ConfigTests: XCTestCase {
    func testFileThenFlagPrecedence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "# config\ndb = ./file.db\nport = 9000\nbind = ::1\nlog-level = warn\n".write(to: file, atomically: true, encoding: .utf8)
        let config = try Config(arguments: ["--port", "8081", "--config", file.path])
        XCTAssertEqual(config.port, 8081); XCTAssertEqual(config.dbPath, "./file.db")
        XCTAssertEqual(config.bind, "::1"); XCTAssertEqual(config.logLevel, .warn)
    }
    func testInvalidOptions() {
        for arguments in [["--port", "0"], ["--port", "65536"], ["--db"], ["--log-level", "verbose"], ["--bind", "nonsense"], ["--unknown", "x"]] {
            XCTAssertThrowsError(try Config(arguments: arguments))
        }
    }
}
