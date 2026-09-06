import Foundation

/// The command-line launcher shares its containing app's translations.
/// A standalone development binary falls back to its own bundle/source language.
enum MCPLocalization {
    static var bundle: Bundle {
        resourceBundle(executableURL: Bundle.main.executableURL, fallback: .main)
    }

    static func resourceBundle(executableURL: URL?, fallback: Bundle) -> Bundle {
        guard let executableURL else { return fallback }
        let helpers = executableURL.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              app.pathExtension == "app", let bundle = Bundle(url: app) else { return fallback }
        return bundle
    }
}
