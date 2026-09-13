import Foundation
import Synchronization
import Testing

import FSMetricsCore

@Suite("ActivityLocationResolver")
struct ActivityLocationResolverTests {
    private let volume = "/Volumes/Data"

    /// Injects a uid-to-home mapping and a set of paths that are reported to
    /// exist, so tests never touch the real filesystem or accounts.
    private func resolver(
        homeByUID: [uid_t: String] = [:],
        existing: Set<String> = []
    ) -> ActivityLocationResolver {
        ActivityLocationResolver(
            homeDirectory: { homeByUID[$0] },
            pathExists: { existing.contains($0) }
        )
    }

    @Test("user_growth resolves to an existing home directory and passes the parsed uid")
    func userGrowthHome() {
        let requestedUID = Mutex<uid_t?>(nil)
        let resolver = ActivityLocationResolver(
            homeDirectory: { uid in
                requestedUID.withLock { $0 = uid }
                return "/Users/alice"
            },
            pathExists: { $0 == "/Users/alice" }
        )

        #expect(
            resolver.directory(category: "user_growth", uid: "501", volume: volume)
                == "/Users/alice"
        )
        #expect(requestedUID.withLock { $0 } == uid_t(501))
    }

    @Test("user_growth falls back to the volume when the home directory is missing")
    func missingHomeFallsBackToVolume() {
        let resolver = resolver(homeByUID: [501: "/Users/alice"], existing: [volume])

        #expect(
            resolver.directory(category: "user_growth", uid: "501", volume: volume)
                == volume
        )
    }

    @Test("user_growth with an unknown uid uses the volume, or nil when it is missing")
    func unknownUIDFallsBackToVolume() {
        let existing = resolver(existing: [volume])
        #expect(
            existing.directory(category: "user_growth", uid: "501", volume: volume)
                == volume
        )

        let missing = resolver()
        #expect(
            missing.directory(category: "user_growth", uid: "501", volume: volume)
                == nil
        )
    }

    @Test("user_growth with a nil uid falls back to the volume")
    func nilUIDFallsBackToVolume() {
        let resolver = resolver(homeByUID: [501: "/Users/alice"], existing: [volume])

        #expect(
            resolver.directory(category: "user_growth", uid: nil, volume: volume)
                == volume
        )
    }

    @Test("user_growth with a non-numeric uid falls back to the volume")
    func nonNumericUIDFallsBackToVolume() {
        let resolver = resolver(homeByUID: [501: "/Users/alice"], existing: [volume])

        #expect(
            resolver.directory(category: "user_growth", uid: "bob", volume: volume)
                == volume
        )
    }

    @Test("user_growth with an out-of-range uid falls back to the volume")
    func outOfRangeUIDFallsBackToVolume() {
        let resolver = resolver(homeByUID: [501: "/Users/alice"], existing: [volume])

        #expect(
            resolver.directory(
                category: "user_growth", uid: "4294967296", volume: volume
            ) == volume
        )
        #expect(
            resolver.directory(category: "user_growth", uid: "-1", volume: volume)
                == volume
        )
    }

    @Test("user_growth with an empty home path falls back to the volume")
    func emptyHomeFallsBackToVolume() {
        let resolver = ActivityLocationResolver(
            homeDirectory: { _ in "" },
            pathExists: { _ in true }
        )

        #expect(
            resolver.directory(category: "user_growth", uid: "501", volume: volume)
                == volume
        )
    }

    @Test(
        "other categories resolve to the volume when it exists and nil otherwise",
        arguments: ["capacity", "health", "nfs", "performance", "unknown"]
    )
    func otherCategoriesUseVolume(category: String) {
        let resolver = resolver(existing: [volume])

        #expect(
            resolver.directory(category: category, uid: "501", volume: volume)
                == volume
        )
        #expect(
            resolver.directory(category: category, uid: "501", volume: "/Volumes/Gone")
                == nil
        )
    }

    @Test("an unknown category still uses the volume so callers need no whitelist")
    func unknownCategoryUsesVolume() {
        let resolver = resolver(existing: [volume])
        #expect(
            resolver.directory(category: "housekeeping", uid: nil, volume: volume)
                == volume
        )
    }

    @Test("an empty volume with no candidates resolves to nil")
    func emptyVolumeResolvesToNil() {
        let resolver = resolver()
        #expect(resolver.directory(category: "capacity", uid: "501", volume: "") == nil)
        #expect(
            resolver.directory(category: "user_growth", uid: "501", volume: "")
                == nil
        )
        #expect(resolver.directory(category: "user_growth", uid: nil, volume: "") == nil)
    }
}
