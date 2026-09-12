import Foundation
import Testing

import FSMetricsCore

@Suite("DiskInfo device resolution")
struct DiskInfoTests {
    @Test("APFS physical store wins and is reduced to the whole disk")
    func physicalStoreWins() {
        let info = DiskInfo(
            deviceIdentifier: "disk3s1s1",
            parentWholeDisk: "disk3",
            physicalStore: "disk0"
        )
        #expect(info.preferredDiskID == "disk0")
    }

    @Test("Fallback chain: parent whole disk, then device identifier, then disk0")
    func fallbackChain() {
        let parent = DiskInfo(deviceIdentifier: "disk6s1", parentWholeDisk: "disk6")
        #expect(parent.preferredDiskID == "disk6")

        let identifierOnly = DiskInfo(deviceIdentifier: "disk6s1")
        #expect(identifierOnly.preferredDiskID == "disk6s1")

        #expect(DiskInfo().preferredDiskID == "disk0")
    }

    @Test("Partition suffixes are stripped")
    func wholeDiskStripping() {
        #expect(DiskInfo.wholeDisk(from: "disk0s2") == "disk0")
        #expect(DiskInfo.wholeDisk(from: "disk0s2s1") == "disk0")
        #expect(DiskInfo.wholeDisk(from: "disk0") == "disk0")
    }
}
