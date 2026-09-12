import XCTest
@testable import FSMonCore

final class SchedulerTests: XCTestCase {
    final class Fake: Sampler {
        let name: String
        let interval: TimeInterval
        let action: (SampleContext) throws -> SamplerOutcome
        private let lock = NSLock()
        private var runs = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return runs }
        init(_ name: String, interval: TimeInterval, action: @escaping (SampleContext) throws -> SamplerOutcome = { _ in .ok }) {
            self.name = name; self.interval = interval; self.action = action
        }
        func collect(_ ctx: SampleContext) throws -> SamplerOutcome {
            lock.lock(); runs += 1; lock.unlock()
            return try action(ctx)
        }
    }
    func testIndependentIntervalsAndStop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try Database(path: directory.appendingPathComponent("test.db").path)
        defer { try? db.close() }
        let fastDone = expectation(description: "fast sampler runs")
        fastDone.expectedFulfillmentCount = 6
        let slowDone = expectation(description: "slow sampler runs")
        slowDone.expectedFulfillmentCount = 2
        fastDone.assertForOverFulfill = false; slowDone.assertForOverFulfill = false
        let fast = Fake("fast", interval: 0.02) { _ in fastDone.fulfill(); return .ok }
        let slow = Fake("slow", interval: 0.12) { _ in slowDone.fulfill(); return .degraded("test detail") }
        let registry = SamplerRegistry(); registry.register(fast); registry.register(slow)
        let scheduler = Scheduler(registry: registry, db: db, log: Logger(level: .error))
        scheduler.start(); scheduler.start()
        wait(for: [fastDone, slowDone], timeout: 3)
        scheduler.stop(); scheduler.stop()
        XCTAssertGreaterThan(fast.count, slow.count)
        XCTAssertEqual(scheduler.statuses.snapshot().first { $0.name == "slow" }?.detail, "test detail")
        let count = fast.count
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertEqual(fast.count, count)
    }
    func testBusySamplerSkipsTicksAndDoesNotBlockOtherSampler() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try Database(path: directory.appendingPathComponent("test.db").path)
        defer { try? db.close() }
        let entered = expectation(description: "slow entered")
        let fastRuns = expectation(description: "fast continues")
        fastRuns.expectedFulfillmentCount = 6; fastRuns.assertForOverFulfill = false
        let gate = DispatchSemaphore(value: 0)
        let slow = Fake("blocked", interval: 0.01) { _ in entered.fulfill(); _ = gate.wait(timeout: .now() + 3); return .ok }
        let fast = Fake("fast", interval: 0.02) { _ in fastRuns.fulfill(); return .ok }
        let registry = SamplerRegistry(); registry.register(slow); registry.register(fast)
        let scheduler = Scheduler(registry: registry, db: db, log: Logger(level: .error))
        scheduler.start()
        wait(for: [entered, fastRuns], timeout: 2)
        XCTAssertEqual(slow.count, 1)
        let stopped = expectation(description: "stop drains")
        DispatchQueue.global().async { scheduler.stop(); stopped.fulfill() }
        // Let stop cancel timers before releasing the ongoing sample.
        Thread.sleep(forTimeInterval: 0.05)
        gate.signal()
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(slow.count, 1)
    }
    func testThrownErrorIsRecorded() throws {
        struct Failure: Error {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try Database(path: directory.appendingPathComponent("test.db").path)
        defer { try? db.close() }
        let ran = expectation(description: "ran"); ran.assertForOverFulfill = false
        let fake = Fake("error", interval: 0.01) { _ in ran.fulfill(); throw Failure() }
        let registry = SamplerRegistry(); registry.register(fake)
        let scheduler = Scheduler(registry: registry, db: db, log: Logger(level: .error))
        scheduler.start(); wait(for: [ran], timeout: 2); scheduler.stop()
        let status = try XCTUnwrap(scheduler.statuses.snapshot().first)
        XCTAssertEqual(status.status, "error")
        XCTAssertNotNil(status.lastRun); XCTAssertNotNil(status.detail)
    }
    func testImmediateRunAndAlignedTimestamps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try Database(path: directory.appendingPathComponent("test.db").path)
        defer { try? db.close() }
        let ran = expectation(description: "immediate and aligned runs")
        ran.expectedFulfillmentCount = 2
        let lock = NSLock()
        var contexts: [(ts: Int64, monotonicNanos: UInt64, observed: Date)] = []
        let startedAt = Date()
        let fake = Fake("aligned", interval: 1) { context in
            lock.lock()
            contexts.append((context.ts, context.monotonicNanos, Date()))
            lock.unlock()
            ran.fulfill()
            return .ok
        }
        let registry = SamplerRegistry(); registry.register(fake)
        let scheduler = Scheduler(registry: registry, db: db, log: Logger(level: .error))
        scheduler.start()
        wait(for: [ran], timeout: 2)
        scheduler.stop()
        lock.lock(); let samples = contexts; lock.unlock()
        XCTAssertLessThan(samples[0].observed.timeIntervalSince(startedAt), 0.1)
        XCTAssertEqual(samples[1].ts, samples[0].ts + 1)
        XCTAssertGreaterThan(samples[1].monotonicNanos, samples[0].monotonicNanos)
        XCTAssertGreaterThanOrEqual(samples[1].observed.timeIntervalSince1970 - Double(samples[1].ts), 0.04)
    }
}
