import Foundation

/// The version scripts/setup.sh stamps into Info.plist at build time: a number that grows by one
/// with every commit, and the commit the app was built from.
enum AppVersion {
    /// "13". "0" when built outside a git checkout, "?" when run without the .app (`swift run`).
    static let number = info("CFBundleShortVersionString") ?? "?"
    /// "d97685b", or "d97685b, modified" when built with uncommitted changes.
    static let commit = info("GitCommit") ?? "unknown"
    /// "v13 (d97685b)"
    static var description: String { "v\(number) (\(commit))" }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
