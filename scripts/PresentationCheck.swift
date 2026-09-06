import Foundation

@main
struct PresentationCheck {
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let catalog = try MCPCatalog.decode(Data(contentsOf: URL(fileURLWithPath: "MCPManager/Resources/catalog.json")))
        for result in try PresentationScenarios.run(catalog: catalog, directory: directory) {
            print("OK · \(result)")
        }
        for result in try await PresentationScenarios.runForms() { print("OK · \(result)") }
        // A synthetic app layout checks the helper's resource lookup, without
        // executing a launcher or touching a real profile/Keychain item.
        let app = directory.appending(path: "LocalizationFixture.app")
        let contents = app.appending(path: "Contents")
        let resources = contents.appending(path: "Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.mcp.localization", "CFBundleDevelopmentRegion": "fr", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        for language in ["fr", "en"] {
            try FileManager.default.copyItem(at: directory.appending(path: "\(language).lproj"), to: resources.appending(path: "\(language).lproj"))
        }
        let resolved = MCPLocalization.resourceBundle(executableURL: contents.appending(path: "Helpers/mcp-manager-launcher"), fallback: .main)
        precondition(resolved.bundleURL.standardizedFileURL.path == app.standardizedFileURL.path, "Launcher must use its containing app's resources")
        precondition(resolved.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil)
        precondition(MCPLocalization.resourceBundle(executableURL: directory.appending(path: "standalone"), fallback: .main) == .main)
        print("OK · Shared launcher localization bundle and standalone fallback")
        for (language, install, singular, plural) in [
            ("fr", "Installer", "1 recommandation", "2 recommandations"),
            ("en", "Install", "1 recommendation", "2 recommendations")
        ] {
            guard let bundle = Bundle(path: directory.appending(path: "\(language).lproj").path) else {
                fatalError("Missing compiled language: \(language)")
            }
            let locale = Locale(identifier: language)
            precondition(String(localized: "Installer", bundle: bundle, locale: locale) == install)
            let one = 1, two = 2
            precondition(String(localized: "\(one) recommandations", bundle: bundle, locale: locale) == singular)
            precondition(String(localized: "\(two) recommandations", bundle: bundle, locale: locale) == plural)
            precondition(String(localized: "\(one) serveurs", bundle: bundle, locale: locale) == (language == "fr" ? "1 serveur" : "1 server"))
            precondition(String(localized: "\(two) serveurs", bundle: bundle, locale: locale) == (language == "fr" ? "2 serveurs" : "2 servers"))
            let exitCode: Int32 = 1
            let exitMessage = String(localized: "Le serveur s’est arrêté avec le code \(exitCode).", bundle: bundle, locale: locale)
            precondition(exitMessage == (language == "fr" ? "Le serveur s’est arrêté avec le code 1." : "The server exited with code 1."))
            let launcherMessage = String(localized: "MCP Manager : variables indisponibles. Vérifiez le profil et l’accès au Trousseau.\n", bundle: bundle, locale: locale)
            precondition(launcherMessage.hasSuffix("\n") && launcherMessage.contains(language == "fr" ? "Trousseau" : "Keychain"))
            for recipe in catalog.recipes {
                let translated = recipe.localizedText(\.summary, bundle: bundle)
                precondition(language == "fr" ? translated == recipe.summary : translated != recipe.summary)
                precondition(recipe.makeDraft().isValid)
            }
            print("OK · \(language): labels and native plurals")
        }
    }
}
