import FSMonCore

func registerCoreSamplers(_ registry: SamplerRegistry, inventory: MountInventoryStore) {
    registry.register(CapacitySampler(inventory: inventory))
    registry.register(RetentionSampler())
}

func registerCoreRoutes(_ router: Router, db: Database, inventory: MountInventoryStore, statuses: SamplerStatusStore, log: Logger) {
    CapacityRoutes.register(on: router, db: db, inventory: inventory, statuses: statuses)
}
