import Foundation

/// Build metadata comes from Config/Version.xcconfig via the app's Info.plist.
/// Standalone synthetic test binaries have no app metadata.
enum MCPAppVersion {
    static var current: String {
        MCPLocalization.bundle.object(forInfoDictionaryKey: "MCPReleaseVersion") as? String
            ?? MCPLocalization.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
    }
}
