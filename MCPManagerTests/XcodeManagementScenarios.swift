import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum XcodeManagementScenarios {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        if try !condition() { throw Failure(description: description) }
    }

    static func run() async throws -> [String] {
        let home = FileManager.default.temporaryDirectory.appending(path: "MCPManager-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appending(path: "Library/Developer/Xcode/CodingAssistant")
        for folder in ["codex", "ClaudeAgentConfig"] {
            try FileManager.default.createDirectory(at: base.appending(path: folder), withIntermediateDirectories: true)
        }
        let codexURL = base.appending(path: "codex/config.toml")
        let claudeURL = base.appending(path: "ClaudeAgentConfig/.claude.json")
        let pausedURL = base.appending(path: "ClaudeAgentConfig/.mcp-manager-disabled.json")
        let codex = """
        model = "keep-model"
        [mcp_servers.'shared'] # preserve alias
        command = "/usr/bin/true"
        args = [
          "first",
          "second"
        ]
        enabled = true # original
        startup_timeout_sec = 77

        [mcp_servers.other]
        command = "/usr/bin/false"
        custom = "unchanged"

        [mcp_servers.'shared'.env]
        TOKEN = "fixture-secret"
        ROOT = "/tmp/data"

        [profiles.keep]
        model = "other-model"

        """
        let claude = #"{"theme":"dark","mcpServers":{"shared":{"type":"stdio","command":"/usr/bin/true","args":["claude"],"env":{"TOKEN":"fixture-secret"}},"other":{"url":"https://example.com/mcp","headers":{"Authorization":"Bearer fixture-secret"}}}}"#
        try Data(codex.utf8).write(to: codexURL)
        try Data(claude.utf8).write(to: claudeURL)
        let manager = XcodeMCPManagement(directory: base)
        func entry(_ kind: XcodeInstallationTarget.Kind, _ name: String) throws -> XcodeInventoryEntry {
            guard let item = try manager.entries(for: kind).first(where: { $0.server.name == name }) else {
                throw Failure(description: "Missing inventory entry \(kind)/\(name)")
            }
            return item
        }
        func perform(_ action: XcodeManagementAction, _ kind: XcodeInstallationTarget.Kind, _ name: String) throws -> XcodeManagementReceipt {
            let item = try entry(kind, name)
            return try manager.perform(action, binding: item.server.xcodeBinding!, revision: item.target.revision!)
        }
        var passed: [String] = []
        let initial = manager.inventory()
        try check(initial.errors.isEmpty && initial.entries.count == 4, "Inventory reads both agents")
        try check(Set(initial.entries.map(\.id)).count == 4, "Same names in different agents must have distinct IDs")
        let boundCodex = try entry(.codex, "shared").server
        let crossAgentTarget = XcodeMCPInstaller(codingAssistantDirectory: base).detectTargets(for: boundCodex).first { $0.kind == .claude }!
        try check(crossAgentTarget.detectionError != nil, "Bound entry cannot overwrite a namesake in another agent")
        try check(try entry(.codex, "shared").server.arguments == ["first", "second"], "Multiline arrays parsed")
        try check(try entry(.codex, "shared").server.environmentVariableNames == ["ROOT", "TOKEN"], "Nested env names imported")
        let scan = await LocalMCPDiscoveryService(homeDirectory: home, applicationSupportDirectory: home.appending(path: "Application Support"), includeDeveloperTools: false).scan()
        try check(scan.discoveries.flatMap(\.sources).contains { $0.kind == .xcodeCodex }, "Codex Xcode included in local scan")
        try check(scan.discoveries.flatMap(\.sources).contains { $0.kind == .xcodeClaude }, "Claude Xcode included in local scan")
        passed.append("Inventaire par agent, identités distinctes, découverte locale, tableaux multilignes et env")

        let otherBefore = try TOMLServerDocument(Data(contentsOf: codexURL)).payload("other")
        let disabled = try perform(.disable, .codex, "shared")
        try check(try entry(.codex, "shared").target.isDisabled, "Codex disabled")
        try check(try TOMLServerDocument(Data(contentsOf: codexURL)).payload("other") == otherBefore, "Other server retained byte for byte")
        try check(try String(contentsOf: codexURL, encoding: .utf8).contains("TOKEN = \"fixture-secret\""), "Secret retained")
        let removed = try perform(.uninstall, .codex, "shared")
        try check(try !manager.entries(for: .codex).contains { $0.server.name == "shared" }, "Root and nested sections removed")
        try check(try Data(contentsOf: claudeURL) == Data(claude.utf8), "Claude is not modified by Codex operations")
        do { try manager.restore(disabled); throw Failure(description: "Older undo must wait") }
        catch is XcodeManagementError { }
        var changedOther = try String(contentsOf: codexURL, encoding: .utf8)
        changedOther = changedOther.replacingOccurrences(of: "custom = \"unchanged\"", with: "custom = \"external change\"")
        try Data(changedOther.utf8).write(to: codexURL)
        try manager.restore(removed)
        try check(try entry(.codex, "shared").target.isDisabled, "Undo uninstall restores disabled state")
        try check(try String(contentsOf: codexURL, encoding: .utf8).contains("custom = \"external change\""), "Undo preserves external edits to other server")
        try manager.restore(disabled)
        try check(try !entry(.codex, "shared").target.isDisabled, "Undo disable restores enabled state")
        passed.append("Codex : désactivation, suppression des sous-tables, restauration ciblée et isolation de Claude")

        let stale = try entry(.codex, "shared")
        var changed = try String(contentsOf: codexURL, encoding: .utf8)
        changed = changed.replacingOccurrences(of: "startup_timeout_sec = 77", with: "startup_timeout_sec = 99")
        try Data(changed.utf8).write(to: codexURL)
        do {
            _ = try manager.perform(.uninstall, binding: stale.server.xcodeBinding!, revision: stale.target.revision!)
            throw Failure(description: "Stale revision accepted")
        } catch is XcodeManagementError { }
        try check(try String(contentsOf: codexURL, encoding: .utf8) == changed, "Conflict leaves file unchanged")
        passed.append("Refus d’une action sur une entrée modifiée depuis son affichage")

        let claudeDisabled = try perform(.disable, .claude, "shared")
        try check(try entry(.claude, "shared").target.isDisabled, "Claude paused across new inventory")
        let activeJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as! [String: Any]
        try check((activeJSON["mcpServers"] as! [String: Any])["shared"] == nil, "Paused server removed from active config")
        try check(try String(contentsOf: pausedURL, encoding: .utf8).contains("fixture-secret"), "Paused definition retains secret")
        let pausedMode = try FileManager.default.attributesOfItem(atPath: pausedURL.path)[.posixPermissions] as! NSNumber
        try check(pausedMode.intValue == 0o600, "Paused definitions private")
        let enabled = try perform(.enable, .claude, "shared")
        try check(try !entry(.claude, "shared").target.isDisabled, "Claude reactivated")
        let enabledJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as! [String: Any]
        let originalJSON = try JSONSerialization.jsonObject(with: Data(claude.utf8)) as! [String: Any]
        try check(try XcodeMCPManagement.json(enabledJSON) == XcodeMCPManagement.json(originalJSON), "Claude fully preserves headers, args, env and theme")
        try manager.restore(enabled)
        try check(try entry(.claude, "shared").target.isDisabled, "Undo enable returns to paused")
        let removedPaused = try perform(.uninstall, .claude, "shared")
        try check(try !manager.entries(for: .claude).contains { $0.server.name == "shared" }, "Uninstall paused server")
        try manager.restore(removedPaused)
        try check(try entry(.claude, "shared").target.isDisabled, "Restore paused definition")
        passed.append("Claude : suspension persistante, réactivation exacte, désinstallation suspendue et fichiers privés")

        // Simulate a crash halfway through undo: both active and paused definitions exist.
        var interrupted = claudeDisabled
        interrupted.restoring = true
        let receiptURL = base.appending(path: ".mcp-manager-history/\(interrupted.id.uuidString).json")
        try JSONEncoder().encode(interrupted).write(to: receiptURL)
        var duplicate = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as! [String: Any]
        var servers = duplicate["mcpServers"] as! [String: Any]
        servers["shared"] = (originalJSON["mcpServers"] as! [String: Any])["shared"]
        duplicate["mcpServers"] = servers
        try XcodeMCPManagement.json(duplicate).write(to: claudeURL)
        try check(!manager.inventory().errors.isEmpty, "Partial transaction reported")
        try XcodeMCPManagement(directory: base).restore(interrupted)
        try check(try !entry(.claude, "shared").target.isDisabled, "Interrupted restore recovers after relaunch")
        try check(try manager.history().first { $0.id == interrupted.id }!.restored, "Recovery recorded")
        passed.append("Reprise d’une restauration interrompue après relancement du service")

        let uninstalled = try perform(.uninstall, .claude, "shared")
        var replacementJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as! [String: Any]
        var replacementMap = replacementJSON["mcpServers"] as! [String: Any]
        replacementMap["shared"] = ["command": "/usr/bin/new-definition"]
        replacementJSON["mcpServers"] = replacementMap
        let replacementData = try XcodeMCPManagement.json(replacementJSON)
        try replacementData.write(to: claudeURL)
        do { try manager.restore(uninstalled); throw Failure(description: "Undo overwrote replacement") }
        catch is XcodeManagementError { }
        try check(try Data(contentsOf: claudeURL) == replacementData, "Replacement preserved")
        passed.append("Restauration refusée lorsqu’une autre définition a repris le même nom")

        let multiline = "developer_instructions = \"\"\"Instructions\n[mcp_servers.actual]\nIgnore this as a header\n\"\"\"\n[ mcp_servers . 'actual' ] # actual table\ncommand = \"/usr/bin/true\"\n"
        try Data(multiline.utf8).write(to: codexURL)
        try check(try manager.entries(for: .codex).map(\.server.name) == ["actual"], "Multiline instructions do not create phantom sections")
        _ = try perform(.disable, .codex, "actual")
        let updatedServer = MCPServer(name: "actual", command: "/usr/bin/true", arguments: ["updated"])
        let installer = XcodeMCPInstaller(codingAssistantDirectory: base)
        let updateTarget = installer.detectTargets(for: updatedServer).first { $0.kind == .codex }!
        _ = try await installer.install(updatedServer, into: updateTarget)
        try check(try entry(.codex, "actual").server.arguments == ["updated"], "Update handles spaced and quoted header")
        try check(try String(contentsOf: codexURL, encoding: .utf8).contains("developer_instructions = \"\"\"Instructions\n[mcp_servers.actual]\nIgnore this as a header\n\"\"\""), "Multiline instructions preserved after lifecycle and update")
        let unsafe = "[mcp_servers.bad]\ncommand = \"/usr/bin/true\"\nargs = [\n\"unfinished\"\n"
        try Data(unsafe.utf8).write(to: codexURL)
        try check(!manager.inventory().errors.isEmpty, "Unsupported TOML reported, not silently omitted")
        try check(try String(contentsOf: codexURL, encoding: .utf8) == unsafe, "Unsupported file unchanged")
        passed.append("Instructions multilignes préservées, faux en-têtes ignorés et TOML incomplet refusé")
        return passed
    }
}
