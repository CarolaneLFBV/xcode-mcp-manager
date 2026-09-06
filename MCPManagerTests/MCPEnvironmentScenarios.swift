import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum MCPEnvironmentScenarios {
    final class MemoryVault: MCPSecretStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [UUID: Data] = [:]
        private(set) var reads = 0
        func read(_ id: UUID) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            guard let data = items[id] else { throw MCPEnvironmentError.keychain(-25300) }
            return data
        }
        func write(_ data: Data, id: UUID) throws {
            lock.lock(); defer { lock.unlock() }
            guard items[id] == nil else { throw MCPEnvironmentError.keychain(-25299) }
            items[id] = data
        }
        func remove(_ id: UUID) throws {
            lock.lock(); defer { lock.unlock() }
            items[id] = nil
        }
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        try XcodeManagementScenarios.check(try condition(), message)
    }

    static func run(helperURL: URL? = nil) async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appending(path: "MCPManager-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryVault()
        let storage = MCPEnvironmentStorage(directory: root.appending(path: "profiles"), vault: vault)
        let helper = helperURL ?? URL(fileURLWithPath: "/usr/bin/true")
        let service = MCPEnvironmentService(storage: storage, helperURL: helper)
        let original = MCPServer(name: "fixture", command: "/usr/bin/printenv", arguments: ["PUBLIC_VALUE"],
            environmentVariableNames: ["PRIVATE_TOKEN", "PUBLIC_VALUE"])
        let token = "fixture-never-write-this-token"
        let saved = try service.save(server: original, drafts: [
            MCPEnvironmentDraft(name: "PRIVATE_TOKEN", value: token),
            MCPEnvironmentDraft(name: "PUBLIC_VALUE", isSecret: false, value: "ordinary value")
        ], scope: "Local test")
        let profile = try service.profile(for: saved)!
        let profileURL = storage.directory.appending(path: "\(profile.id.uuidString).json")
        let metadata = try Data(contentsOf: profileURL)
        try check(!String(decoding: metadata, as: UTF8.self).contains(token), "Secrets absent from metadata")
        try check(!String(decoding: JSONEncoder().encode(saved), as: UTF8.self).contains(token), "Secrets absent from catalogue")
        try check(try storage.secrets(profile)["PRIVATE_TOKEN"] == token, "Secret resolved from vault")
        let attributes = try FileManager.default.attributesOfItem(atPath: profileURL.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Metadata file private")
        let environment = try storage.environment(profile, inherited: ["UNRELATED_SECRET": "do-not-forward", "DYLD_INSERT_LIBRARIES": "unsafe", "HOME": "/tmp"])
        try check(environment["PRIVATE_TOKEN"] == token && environment["PUBLIC_VALUE"] == "ordinary value", "Declared values injected")
        try check(environment["UNRELATED_SECRET"] == nil && environment["DYLD_INSERT_LIBRARIES"] == nil, "Ambient secrets and loader settings not forwarded")
        var passed = ["Secrets hors fichiers/catalogue, profils privés et environnement limité au serveur"]

        let reads = vault.reads
        let drafts = try service.drafts(for: saved)
        try check(vault.reads == reads && drafts.first(where: { $0.name == "PRIVATE_TOKEN" })?.value == "", "Opening form never fetches secret values")
        let revised = try service.save(server: saved, drafts: drafts, scope: "Local revision")
        try check(revised.environmentProfileID != saved.environmentProfileID, "Edits create immutable new profile")
        try check(try storage.secrets(service.profile(for: revised)!)["PRIVATE_TOKEN"] == token, "Blank stored secret retained on save")
        var changed = saved
        changed.command = "/usr/bin/false"
        do { _ = try service.profile(for: changed); throw XcodeManagementScenarios.Failure(description: "Secrets rebound to a new command without confirmation") }
        catch is MCPEnvironmentError { }
        let tampered = MCPEnvironmentProfile(id: profile.id, scope: profile.scope, command: "/usr/bin/false",
            arguments: [], url: profile.url, transport: profile.transport, bearerVariable: profile.bearerVariable, variables: profile.variables)
        do { _ = try storage.secrets(tampered); throw XcodeManagementScenarios.Failure(description: "Tampered profile accepted") }
        catch is MCPEnvironmentError { }
        for name in ["BAD=KEY", "WITH SPACE", "DYLD_INSERT_LIBRARIES", "BASH_ENV"] {
            do {
                _ = try service.save(server: original, drafts: [MCPEnvironmentDraft(name: name, value: token)], scope: "invalid")
                throw XcodeManagementScenarios.Failure(description: "Invalid variable accepted")
            } catch is MCPEnvironmentError { }
        }
        passed.append("Secrets non relus au scan, versions immuables, conservation et refus des profils altérés")

        // Use a canonical helper filename so the inventory can recognize our managed invocation.
        let helperAlias = root.appending(path: "mcp-manager-launcher")
        try FileManager.default.createSymbolicLink(at: helperAlias, withDestinationURL: helper)
        let installService = MCPEnvironmentService(storage: storage, helperURL: helperAlias)
        let base = root.appending(path: "CodingAssistant")
        for folder in ["codex", "ClaudeAgentConfig"] {
            try FileManager.default.createDirectory(at: base.appending(path: folder), withIntermediateDirectories: true)
        }
        let installer = XcodeMCPInstaller(codingAssistantDirectory: base, developerToolPaths: [:], environmentService: installService)
        let manager = XcodeMCPManagement(directory: base, environmentService: installService)
        for target in installer.detectTargets(for: saved) {
            try check(!installer.preflight(for: saved, target: target).contains { $0.severity == .error }, "Managed local credentials supported for both agents")
            _ = try await installer.install(saved, into: target)
        }
        let inventoryReads = vault.reads
        let inventory = manager.inventory()
        try check(inventory.errors.isEmpty && inventory.entries.count == 2, "Wrapped servers discovered")
        try check(vault.reads == inventoryReads, "Inventory does not access the Keychain")
        let ids = inventory.entries.compactMap(\.server.environmentProfileID)
        try check(Set(ids).count == 2 && !ids.contains(saved.environmentProfileID!), "Independent profiles per Xcode agent")
        for entry in inventory.entries {
            try check(entry.server.command == original.command && entry.server.arguments == original.arguments, "Inventory recovers logical command")
            let data = try Data(contentsOf: entry.target.configurationURL)
            try check(!String(decoding: data, as: UTF8.self).contains(token), "No token in Xcode config")
            try check(String(decoding: data, as: UTF8.self).contains("--profile"), "Xcode really starts helper")
        }
        let codex = inventory.entries.first { $0.target.kind == .codex }!
        let disabled = try manager.perform(.disable, binding: codex.server.xcodeBinding!, revision: codex.target.revision!)
        try manager.restore(disabled)
        try check(try manager.entries(for: .codex)[0].server.environmentProfileID == codex.server.environmentProfileID, "Lifecycle restores same profile reference")
        passed.append("Installation Codex/Claude via lanceur, profils par agent, redétection et restauration")

        let remote = MCPServer(name: "remote", transport: .streamableHTTP, url: "https://example.com/mcp", bearerTokenEnvironmentVariable: "TOKEN")
        let http = try service.save(server: remote, drafts: [MCPEnvironmentDraft(name: "TOKEN", value: token)], scope: "HTTP local")
        try check(try service.storage.environment(service.profile(for: http)!)["TOKEN"] == token, "HTTP token available locally")
        for target in installer.detectTargets(for: http) {
            try check(installer.preflight(for: http, target: target).contains { $0.severity == .error }, "Managed HTTP Xcode install explicitly blocked")
        }
        var insecure = http
        insecure.url = "http://example.com/mcp"
        do {
            _ = try await HTTPMCPTransport(server: insecure).request(id: 1, method: "server/discover", params: .object([:]))
            throw XcodeManagementScenarios.Failure(description: "Managed token accepted over insecure HTTP")
        } catch is MCPEnvironmentError { }
        let obsoleteProfile = try service.profile(for: saved)!
        try vault.remove(obsoleteProfile.id)
        do { _ = try storage.environment(obsoleteProfile); throw XcodeManagementScenarios.Failure(description: "Missing secret silently ignored") }
        catch is MCPEnvironmentError { }
        passed.append("Token HTTP local distinct de Xcode et refus explicite lorsqu’un secret manque")

        if let helperURL {
            let ordinary = MCPServer(name: "probe", command: "/usr/bin/printenv")
            let configured = try service.save(server: ordinary, drafts: [MCPEnvironmentDraft(name: "PUBLIC_VALUE", isSecret: false, value: "literal ; $(not-a-command)")], scope: "Synthetic launcher test")
            func launch(_ mode: String) throws -> (Int32, String) {
                let process = Process()
                process.executableURL = helperURL
                process.arguments = [mode, configured.environmentProfileID!.uuidString]
                process.environment = ["MCP_MANAGER_TEST_PROFILE_DIRECTORY": storage.directory.path, "UNRELATED_SECRET": "must-not-leak"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            }
            let probe = try launch("--check")
            try check(probe.0 == 0 && probe.1 == "MCP_MANAGER_ENV_OK\n", "Real helper verifies child environment without printing values")
            let normal = try launch("--profile")
            try check(normal.0 == 0 && normal.1.contains("PUBLIC_VALUE=literal ; $(not-a-command)\n") && !normal.1.contains("UNRELATED_SECRET"),
                "Exec preserves literal value and filters unrelated variable")
            passed.append("Exécutable réel : transmission au processus fils, pas d’interprétation shell ni fuite ambiante")
        }
        return passed
    }
}
