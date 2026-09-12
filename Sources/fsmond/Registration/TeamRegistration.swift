import FSMonCore

// Person B owns this file. New Swift files under Sources/FSMonCore are picked
// up automatically; no Package.swift or main.swift edits are needed.
func registerTeamSamplers(_ registry: SamplerRegistry) {
    // registry.register(YourSampler())
}

func registerTeamRoutes(_ router: Router, db: Database, statuses: SamplerStatusStore, log: Logger) {
    // router.get("/api/v1/users") { request in ... }
}
