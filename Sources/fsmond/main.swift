import Foundation
import Dispatch
import Darwin
import FSMonCore

if CommandLine.arguments.dropFirst().contains("--help") {
    print(Config.usage)
    exit(EXIT_SUCCESS)
}

do {
    let config = try Config(arguments: Array(CommandLine.arguments.dropFirst()))
    let log = Logger(level: config.logLevel)
    let db = try Database(path: config.dbPath)
    let registry = SamplerRegistry()
    let statuses = SamplerStatusStore()
    let inventory = MountInventoryStore()
    registerCoreSamplers(registry, inventory: inventory)
    registerTeamSamplers(registry)
    let scheduler = Scheduler(registry: registry, db: db, log: log, statuses: statuses)
    let router = Router(log: log)
    registerCoreRoutes(router, db: db, inventory: inventory, statuses: statuses, log: log)
    registerTeamRoutes(router, db: db, statuses: statuses, log: log)
    let server = try HTTPServer(bind: config.bind, port: config.port, router: router, log: log)
    let shutdown = DispatchSemaphore(value: 0)
    let signalQueue = DispatchQueue(label: "fsmond.signals")
    let failureLock = NSLock()
    var failed = false
    server.onFailure = { _ in
        failureLock.lock(); failed = true; failureLock.unlock()
        shutdown.signal()
    }
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler { shutdown.signal() }
        source.resume()
        return source
    }
    log.info("Starting fsmond: db=\(config.dbPath) bind=\(config.bind):\(config.port)")
    server.start()
    scheduler.start()
    shutdown.wait()
    log.info("Shutting down; draining HTTP handlers and samplers")
    server.stop()
    scheduler.stop()
    signals.forEach { $0.cancel() }
    try db.close()
    log.info("Shutdown complete; database closed and WAL checkpointed")
    failureLock.lock(); let exitFailed = failed; failureLock.unlock()
    exit(exitFailed ? EXIT_FAILURE : EXIT_SUCCESS)
} catch {
    FileHandle.standardError.write(Data("fsmond: \(error)\n\(Config.usage)\n".utf8))
    exit(EXIT_FAILURE)
}
