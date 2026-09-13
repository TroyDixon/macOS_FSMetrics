import Foundation

/// Resolves the Finder directory that best represents where an alert's
/// activity happened.
///
/// A `user_growth` alert points at the offending user's home directory when
/// the uid maps to an account whose home exists; every other category (and
/// all fallbacks) points at the alert's volume when that path exists. When
/// neither candidate exists the result is nil, so callers can hide the
/// affordance.
public struct ActivityLocationResolver: Sendable {
    /// Looks up a uid's home directory; nil when the uid has no account or no
    /// home.
    public typealias HomeDirectoryProvider = @Sendable (uid_t) -> String?

    /// Reports whether a path exists.
    public typealias PathExists = @Sendable (String) -> Bool

    private let homeDirectory: HomeDirectoryProvider
    private let pathExists: PathExists

    /// Creates a resolver. The defaults query the real account database and
    /// filesystem; inject closures for deterministic behavior.
    public init(
        homeDirectory: @escaping HomeDirectoryProvider = ActivityLocationResolver.systemHomeDirectory,
        pathExists: @escaping PathExists = ActivityLocationResolver.fileExists
    ) {
        self.homeDirectory = homeDirectory
        self.pathExists = pathExists
    }

    /// The directory to reveal for an alert, or nil when no candidate exists.
    ///
    /// `uid` is consulted only for `user_growth`; it is ignored when nil or
    /// malformed. All other categories resolve directly to the volume.
    public func directory(category: String, uid: String?, volume: String) -> String? {
        if category == "user_growth", let uid, let parsedUID = uid_t(uid) {
            if let home = homeDirectory(parsedUID), !home.isEmpty, pathExists(home) {
                return home
            }
        }
        return pathExists(volume) ? volume : nil
    }

    /// `getpwuid`-backed home lookup; nil when the uid has no account or no home.
    public static let systemHomeDirectory: HomeDirectoryProvider = { uid in
        guard let entry = getpwuid(uid), let home = entry.pointee.pw_dir else {
            return nil
        }
        let path = String(cString: home)
        return path.isEmpty ? nil : path
    }

    /// `FileManager.default.fileExists(atPath:)`.
    public static let fileExists: PathExists = { path in
        FileManager.default.fileExists(atPath: path)
    }
}
