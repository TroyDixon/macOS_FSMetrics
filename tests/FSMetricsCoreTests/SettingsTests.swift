import Foundation
import Testing

import FSMetricsCore

/// Config decoding for the per-volume user quota: `VolumeSettings` owns
/// `user_quota_bytes`, and the retired global `thresholds.user_quota_bytes`
/// key is ignored.
@Suite("Settings")
struct SettingsTests {
    @Test("volume settings decode user_quota_bytes")
    func volumeSettingsDecodeQuota() throws {
        let json = Data(#"{"path": "/Volumes/X", "user_quota_bytes": 5000000000}"#.utf8)

        let volume = try JSONDecoder().decode(VolumeSettings.self, from: json)

        #expect(volume.path == "/Volumes/X")
        #expect(volume.userQuotaBytes == 5e9)
    }

    @Test("volume settings default user_quota_bytes to 0")
    func volumeSettingsDefaultQuota() throws {
        let json = Data(#"{"path": "/Volumes/X"}"#.utf8)

        let volume = try JSONDecoder().decode(VolumeSettings.self, from: json)

        #expect(volume.userQuotaBytes == 0)
    }

    @Test("settings decode tolerates the retired global quota key")
    func settingsToleratesRetiredGlobalQuota() throws {
        let json = Data(#"""
        {
          "volumes": [{"path": "/", "user_quota_bytes": 1000}],
          "thresholds": {
            "capacity_pct_warn": 80,
            "capacity_pct_crit": 95,
            "user_growth_bytes_window": 600,
            "user_growth_bytes_threshold": 5000000000,
            "user_quota_bytes": 2000,
            "io_error_count_threshold": 1,
            "throughput_stall_seconds": 120,
            "cooldown": 3600
          }
        }
        """#.utf8)

        let settings = try JSONDecoder().decode(Settings.self, from: json)

        #expect(settings.volumes.count == 1)
        #expect(settings.volumes[0].userQuotaBytes == 1000)
    }
}
