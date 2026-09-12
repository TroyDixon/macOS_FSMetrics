import FSMonCore

func registerCoreSamplers(_ registry: SamplerRegistry) {
    registry.register(DummySampler())
}

func registerCoreRoutes(_ router: Router, db: Database, statuses: SamplerStatusStore, log: Logger) {
    // Phase 1: health, overview, mounts, containers, devices, and device I/O.
}
