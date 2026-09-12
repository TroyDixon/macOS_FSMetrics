import XCTest
@testable import FSMonCore

final class CapacityRoutesTests: XCTestCase {
    private func object(_ response: Response) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
    func testInventoryDetailAndContainerSiblings() throws {
        let f = try CapacityFixture()
        f.source.mounts = [testMount("/one", device: "/dev/disk10s1s1"), testMount("/two", device: "/dev/disk10s2"), testMount("/hfs", fs: "hfs")]
        // Mounted snapshot UUID is absent from the IOKit volume UUID map.
        f.source.attrs["/one"] = VolumeAttributes(usedBytes: 1000, uuid: "SNAPSHOT-A", name: "One")
        f.source.attrs["/two"] = VolumeAttributes(usedBytes: 2000, uuid: "B", name: "Two")
        f.source.attrs["/hfs"] = VolumeAttributes(usedBytes: 3000, uuid: "C", name: "HFS")
        f.source.containers = ["A": ContainerIdentity(uuid: "CONTAINER", bsdName: "disk10"),
                               "B": ContainerIdentity(uuid: "CONTAINER", bsdName: "disk10")]
        _ = try f.collect()
        let router = f.router()
        let response = router.handle(Request(method: "GET", path: "/api/v1/mounts"))
        XCTAssertEqual(response.status, 200)
        let root = try object(response)
        let mounts = try XCTUnwrap(root["data"] as? [[String: Any]])
        XCTAssertEqual(mounts.count, 3)
        let one = try XCTUnwrap(mounts.first { $0["mount_point"] as? String == "/one" })
        let two = try XCTUnwrap(mounts.first { $0["mount_point"] as? String == "/two" })
        XCTAssertEqual(one["shares_container_with"] as? [String], [two["id"] as! String])
        XCTAssertEqual(one["container_id"] as? String, two["container_id"] as? String)
        XCTAssertTrue(one["device_id"] is NSNull)
        let capacity = try XCTUnwrap(one["capacity"] as? [String: Any])
        XCTAssertEqual(capacity["used_pct"] as? Double, 1000.0 * 100 / (1000 + 500 * 4096))
        let detail = try object(router.handle(Request(method: "GET", path: "/api/v1/mounts/\(one["id"] as! String)")))
        XCTAssertEqual((detail["data"] as? [String: Any])?["id"] as? String, one["id"] as? String)
        XCTAssertEqual(router.handle(Request(method: "GET", path: "/api/v1/mounts/mount:999")).status, 404)
        XCTAssertEqual(router.handle(Request(method: "GET", path: "/api/v1/mounts/nope")).status, 400)
        let stale = try object(f.router(now: 136).handle(Request(method: "GET", path: "/api/v1/mounts")))
        XCTAssertEqual((stale["data"] as? [Any])?.count, 0)
    }

    func testSeriesAveragesAndNullGapsWithExclusiveEnd() throws {
        let f = try CapacityFixture()
        f.source.mounts = [testMount()]
        f.source.attrs["/test"] = VolumeAttributes(usedBytes: 100, uuid: "A", name: "Test")
        _ = try f.collect(120)
        f.source.attrs["/test"] = VolumeAttributes(usedBytes: 300, uuid: "A", name: "Test")
        _ = try f.collect(125)
        _ = try f.collect(300) // Exactly at exclusive end; must not contribute.
        let id = f.inventory.snapshot()!.ids[0]
        let response = f.router(now: 300).handle(Request(method: "GET", path: "/api/v1/mounts/mount:\(id)/capacity",
                                                        query: ["from": "120", "to": "300", "step": "60"]))
        XCTAssertEqual(response.status, 200)
        let series = try XCTUnwrap(try object(response)["data"] as? [String: Any])
        XCTAssertEqual(series["timestamps"] as? [Int], [120, 180, 240])
        let used = try XCTUnwrap(series["used_bytes"] as? [Any])
        XCTAssertEqual(used[0] as? Double, 200)
        XCTAssertTrue(used[1] is NSNull); XCTAssertTrue(used[2] is NSNull)
        // Byte means are whole bytes on the wire (200, not 200.0); percentages stay decimal.
        let body = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(body.contains("\"used_bytes\":[200,null,null]"), body)
        XCTAssertTrue(body.contains("\"total_bytes\":[4096000,null,null]"), body)
        XCTAssertEqual(series["series_id"] as? String, "mount:\(id)")
        // Retained dimension rows permit history after a volume is detached.
        f.source.mounts = []; _ = try f.collect(305)
        XCTAssertEqual(f.router(now: 305).handle(Request(method: "GET", path: "/api/v1/mounts/mount:\(id)")).status, 404)
        XCTAssertEqual(f.router(now: 305).handle(Request(method: "GET", path: "/api/v1/mounts/mount:\(id)/capacity")).status, 200)
    }

    func testRangeValidationBoundsDefaultsAndEmptySeries() throws {
        let f = try CapacityFixture()
        let router = f.router(now: 3600)
        for query in [["step": "0"], ["step": "1", "from": "0", "to": "10001"], ["step": "86401"],
                      ["from": "-1"], ["to": "a"], ["from": "12", "to": "12"],
                      ["step": "9223372036854775808"]] {
            XCTAssertEqual(router.handle(Request(method: "GET", path: "/api/v1/mounts/mount:1/capacity", query: query)).status, 400)
        }
        XCTAssertEqual(router.handle(Request(method: "GET", path: "/api/v1/mounts/mount:1/capacity")).status, 404)
        let range = try CapacityRange(query: [:], now: 3600)
        XCTAssertEqual(range.from, 0); XCTAssertEqual(range.to, 3600); XCTAssertEqual(range.step, 60)
        XCTAssertEqual(range.timestamps.count, 60)
        XCTAssertEqual(try CapacityRange(query: ["from": "121", "to": "181"], now: 200).timestamps, [120, 180])
        try f.db.write { try $0.execute("INSERT INTO mounts (id, mount_point, fs_type, first_seen, last_seen) VALUES (1, '/gone', 'apfs', 1, 1)") }
        let series = try XCTUnwrap(try object(router.handle(Request(method: "GET", path: "/api/v1/mounts/mount:1/capacity")))["data"] as? [String: Any])
        XCTAssertTrue((series["used_bytes"] as! [Any]).allSatisfy { $0 is NSNull })
    }

    func testHealthContractShapeAndErrorAggregation() throws {
        let f = try CapacityFixture()
        let sampler = CapacitySampler(source: f.source, inventory: f.inventory)
        f.statuses.register(sampler)
        let router = f.router()
        var data = try XCTUnwrap(try object(router.handle(Request(method: "GET", path: "/api/v1/health")))["data"] as? [String: Any])
        XCTAssertEqual(Set(data.keys), ["status", "uptime_seconds", "version", "samplers"])
        XCTAssertEqual(data["uptime_seconds"] as? Int, 42)
        XCTAssertEqual(data["status"] as? String, "degraded")
        XCTAssertTrue((data["samplers"] as! [[String: Any]])[0]["last_run"] is NSNull)
        f.statuses.update(name: "capacity", interval: 5, ts: 120, status: "ok", detail: nil)
        data = try XCTUnwrap(try object(router.handle(Request(method: "GET", path: "/api/v1/health")))["data"] as? [String: Any])
        XCTAssertEqual(data["status"] as? String, "ok")
        XCTAssertEqual(Set((data["samplers"] as! [[String: Any]])[0].keys), ["name", "last_run", "interval", "status"])
        // Contract example shows integer intervals; check the wire text, since JSON parsing hides 5 vs 5.0.
        let okBody = String(decoding: router.handle(Request(method: "GET", path: "/api/v1/health")).body, as: UTF8.self)
        XCTAssertTrue(okBody.contains("\"interval\":5,"), okBody)
        f.statuses.update(name: "capacity", interval: 5, ts: 125, status: "error", detail: "failed")
        data = try XCTUnwrap(try object(router.handle(Request(method: "GET", path: "/api/v1/health")))["data"] as? [String: Any])
        // Aggregate stays within the contract's ok|degraded; the sampler row keeps "error".
        XCTAssertEqual(data["status"] as? String, "degraded")
        XCTAssertEqual((data["samplers"] as! [[String: Any]])[0]["status"] as? String, "error")
    }
}
