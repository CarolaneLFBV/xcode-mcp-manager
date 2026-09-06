import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum XcodeProjectScenarios {
    static func check(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        try XcodeManagementScenarios.check(try condition(), description)
    }

    static func run() async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appending(path: "MCPManager-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appending(path: "CodingAssistant")
        let alpha = root.appending(path: "client A/ExampleApp")
        let beta = root.appending(path: "client B/ExampleApp")
        let missing = root.appending(path: "missing")
        for directory in [base.appending(path: "codex"), alpha.appending(path: ".codex"), beta.appending(path: ".codex")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let globalURL = base.appending(path: "codex/config.toml")
        let alphaURL = alpha.appending(path: ".codex/config.toml")
        let betaURL = beta.appending(path: ".codex/config.toml")
        let global = """
        developer_instructions = '''
        [projects."/not/a/real/project"]
        '''
        [mcp_servers.sentry]
        url = "https://example.com/global"
        [projects.'\(alpha.path)']
        trust_level = "trusted"
        [projects.'\(missing.path)']
        trust_level = "trusted"
        """
        let project = """
        [mcp_servers.sentry]
        url = "https://example.com/project"
        enabled = false
        [mcp_servers.sentry.env]
        PRIVATE_TOKEN = "fixture-secret"
        """
        try Data(global.utf8).write(to: globalURL)
        try Data(project.utf8).write(to: alphaURL)
        try Data(project.utf8).write(to: betaURL)
        let discovery = XcodeProjectDiscovery(codingAssistantDirectory: base)
        let automatic = discovery.inventory()
        try check(automatic.errors.isEmpty && automatic.entries.count == 1,
            "Known projects discovered; missing directories ignored (\(automatic.entries.count) entries, \(automatic.errors))")
        let entry = automatic.entries[0]
        try check(entry.server.scope == .project && entry.target.projectDirectoryURL?.path == alpha.resolvingSymlinksInPath().path, "Project scope retained")
        let projectName = "ExampleApp"
        let disabledSuffix = String(localized: " · désactivé")
        try check(entry.target.isDisabled && entry.target.statusTitle == String(localized: "Configuré pour \(projectName)\(disabledSuffix)"), "Project-specific disabled status")
        try check(entry.server.environmentVariableNames == ["PRIVATE_TOKEN"], "Secret names only")
        try check(!(String(data: try JSONEncoder().encode(entry.server), encoding: .utf8) ?? "").contains("fixture-secret"), "No secret in catalogue model")
        try check(discovery.inventory().entries.map(\.id) == automatic.entries.map(\.id), "IDs stable across refresh")
        var passed = ["Détection des projets connus, portée, état désactivé et secrets non copiés"]

        let both = discovery.inventory(additionalProjectDirectories: [alpha, beta, alpha, missing])
        try check(both.errors.isEmpty && both.entries.count == 2, "Selected directories merged without duplicates")
        try check(Set(both.entries.map(\.id)).count == 2 && Set(both.entries.map(\.target.id)).count == 2, "Same project and server names have distinct path-based identities")
        let manager = XcodeMCPManagement(directory: base)
        let globalEntry = try manager.entries(for: .codex)[0]
        try check(!both.entries.map(\.id).contains(globalEntry.id), "Global and project identity isolated")
        let installer = XcodeMCPInstaller(codingAssistantDirectory: base, developerToolPaths: [:])
        let alias = MCPServer(name: "Sentry alias", transport: .streamableHTTP, url: "https://example.com/project")
        try check(installer.projectTargets(for: alias, in: both).count == 2, "Catalogue alias matches each project connection")
        let namesake = MCPServer(name: "sentry", transport: .streamableHTTP, url: "https://example.com/different")
        try check(installer.projectTargets(for: namesake, in: both).isEmpty, "A matching name alone is not proof of the same project connection")
        try check(installer.projectTargets(for: entry.server, in: both).count == 1, "Binding matches only its project")
        passed.append("Dossiers ajoutés, doublons, alias du catalogue et isolation Global / Projets")

        do {
            _ = try manager.perform(.uninstall, binding: entry.server.xcodeBinding!, revision: globalEntry.target.revision!)
            throw XcodeManagementScenarios.Failure(description: "Project binding reached global management")
        } catch is XcodeManagementError { }
        do {
            _ = try await installer.install(alias, into: entry.target)
            throw XcodeManagementScenarios.Failure(description: "Project target reached global installer")
        } catch is XcodeManagementError { }
        do {
            _ = try await installer.install(entry.server, into: globalEntry.target)
            throw XcodeManagementScenarios.Failure(description: "Bound project definition reached global installer")
        } catch is XcodeManagementError { }
        try check(try Data(contentsOf: globalURL) == Data(global.utf8), "Global configuration unchanged")
        try check(try Data(contentsOf: alphaURL) == Data(project.utf8), "Project configuration unchanged")
        try check(try manager.history().isEmpty, "No journal or writes for rejected project actions")
        let legacyBinding = try JSONDecoder().decode(XcodeServerBinding.self, from: Data(#"{"kind":"codex","name":"sentry"}"#.utf8))
        try check(legacyBinding.projectDirectoryURL == nil, "Existing bindings remain backward compatible")
        passed.append("Lecture seule imposée dans les services, aucune écriture globale/projet, rétrocompatibilité")

        try Data("[mcp_servers.bad]\nargs = [\n".utf8).write(to: betaURL)
        let malformed = discovery.inventory(additionalProjectDirectories: [beta])
        try check(malformed.entries.count == 1 && malformed.errors.count == 1, "A malformed project is reported without hiding healthy projects")
        let absentGlobal = XcodeProjectDiscovery(codingAssistantDirectory: root.appending(path: "no-agent"))
            .inventory(additionalProjectDirectories: [alpha])
        try check(absentGlobal.errors.isEmpty && absentGlobal.entries.count == 1, "Manual discovery works without global config")
        passed.append("Projet illisible signalé, projets sains conservés et découverte manuelle sans config globale")
        return passed
    }
}
