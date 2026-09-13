import Foundation
import Testing

import FSMetricsCore

@Suite("SystemVolume")
struct SystemVolumeTests {
    @Test("boot mount points are expected read-only")
    func bootPaths() {
        #expect(SystemVolume.isReadOnlyByDesign(path: "/"))
        #expect(SystemVolume.isReadOnlyByDesign(path: "//"))
    }

    @Test("other volumes are not treated as expected read-only")
    func otherPaths() {
        #expect(!SystemVolume.isReadOnlyByDesign(path: "/System/Volumes/Data"))
        #expect(!SystemVolume.isReadOnlyByDesign(path: "/Volumes/Research"))
        #expect(!SystemVolume.isReadOnlyByDesign(path: ""))
    }
}
