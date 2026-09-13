import Foundation

/// Volume semantics shared by alerting and the UI.
public enum SystemVolume {
    /// macOS 11+ mounts the boot system volume read-only as a sealed snapshot,
    /// so a `health.writable == 0` report for it is expected rather than a
    /// fault. Every other read-only volume is still worth alerting on.
    public static func isReadOnlyByDesign(path: String) -> Bool {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized == "/"
    }
}
