import Foundation

struct XcodeMCPInstaller: Sendable {
    private let codingAssistantDirectory: URL
    private let developerToolPaths: [String: String]?
    private let environmentService: MCPEnvironmentService

    init(codingAssistantDirectory: URL? = nil, developerToolPaths: [String: String]? = nil,
         environmentService: MCPEnvironmentService = MCPEnvironmentService()) {
        self.environmentService = environmentService
        self.developerToolPaths = developerToolPaths
        self.codingAssistantDirectory = codingAssistantDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Developer/Xcode/CodingAssistant", directoryHint: .isDirectory)
    }

    func detectTargets(for server: MCPServer) -> [XcodeInstallationTarget] {
        let commandName = URL(fileURLWithPath: server.command).lastPathComponent
        let toolPaths = developerToolPaths ?? (["xcrun", "mcpbridge", "lldb-mcp"].contains(commandName)
            ? Self.currentDeveloperToolPaths : [:])
        return XcodeInstallationTarget.Kind.allCases.map { kind in
            let url = configurationURL(for: kind)
            var match: MCPServer?
            var matchedTarget: XcodeInstallationTarget?
            var detectionError: String?
            if server.xcodeBinding?.projectDirectoryURL != nil {
                return XcodeInstallationTarget(kind: kind, configurationURL: url,
                    isAvailable: false, isAlreadyConfigured: false,
                    detectionError: String(localized: "Cette définition appartient à un projet et reste en lecture seule."))
            }
            do {
                let inventory = try XcodeMCPManagement(directory: codingAssistantDirectory, environmentService: environmentService).entries(for: kind)
                let entries = inventory.map(\.server)
                if let binding = server.xcodeBinding {
                    if binding.kind == kind { match = entries.first { $0.name == binding.name } }
                    else if entries.contains(where: { $0.name == server.name }) {
                        detectionError = String(localized: "Une entrée du même nom existe pour cet agent. Sélectionnez-la dans « Dans Xcode » pour la gérer.")
                    }
                } else {
                    match = entries.first { $0.name == server.name }
                }
                if match == nil && server.xcodeBinding == nil {
                    let aliases = entries.filter { sameConnection($0, server, toolPaths: toolPaths) }
                    if aliases.count == 1 { match = aliases.first }
                    if aliases.count > 1 {
                        detectionError = String(localized: "Plusieurs entrées correspondent à cette connexion. Vérifiez la configuration.")
                    }
                }
                matchedTarget = inventory.first { $0.server.name == match?.name }?.target
                detectionError = detectionError ?? matchedTarget?.detectionError
            } catch {
                detectionError = String(localized: "Impossible de lire cette configuration. Vérifiez le fichier avant l’installation.")
            }
            return XcodeInstallationTarget(
                kind: kind,
                configurationURL: url,
                isAvailable: FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
                isAlreadyConfigured: match != nil,
                configuredServerName: match?.name,
                isDisabled: match?.enabled == false,
                detectionError: detectionError,
                revision: matchedTarget?.revision
            )
        }
    }

    /// Read-only project matches are separate from the global installation destinations.
    func projectTargets(for server: MCPServer, in inventory: XcodeInventory) -> [XcodeInstallationTarget] {
        let toolPaths = developerToolPaths ?? [:]
        return inventory.entries.filter { entry in
            guard entry.target.isProjectConfiguration else { return false }
            if let binding = server.xcodeBinding {
                return binding == entry.server.xcodeBinding
            }
            guard entry.server.isValid, server.isValid else { return false }
            return sameConnection(entry.server, server, toolPaths: toolPaths)
        }.map(\.target)
    }

    func preview(for original: MCPServer, target: XcodeInstallationTarget.Kind) -> String {
        var server = original
        if let name = detectTargets(for: original).first(where: { $0.kind == target })?.configuredServerName {
            server.name = name
        }
        server = environmentService.wrapped(server)
        switch target {
        case .codex:
            return CodexConfigRenderer.render(server)
        case .claude:
            guard let data = try? JSONSerialization.data(
                withJSONObject: ["mcpServers": [server.name: claudeDefinition(for: server)]],
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    func preflight(for server: MCPServer, target: XcodeInstallationTarget) -> [XcodePreflightIssue] {
        var issues: [XcodePreflightIssue] = []
        if let error = target.detectionError {
            issues.append(.init(severity: .error, message: error))
        }
        if target.kind == .claude && target.isDisabled {
            issues.append(.init(severity: .error, message: String(localized: "Réactivez ce serveur avant de mettre à jour sa configuration Claude.")))
        }
        if !target.isAvailable {
            issues.append(.init(
                severity: .error,
                message: String(localized: "Activez d’abord \(target.kind.title) dans Xcode → Réglages → Intelligence.")
            ))
        }
        for validationIssue in server.validationIssues {
            issues.append(.init(severity: .error, message: validationIssue))
        }
        if server.transport == .stdio, !commandAppearsAvailable(server.command) {
            issues.append(.init(
                severity: .warning,
                message: String(localized: "La commande « \(server.command) » n’a pas été trouvée dans les emplacements habituels.")
            ))
        }

        let requiredVariables = Set(server.environmentVariableNames + [server.bearerTokenEnvironmentVariable])
            .filter { !$0.isEmpty }
            .sorted()
        if server.environmentProfileID != nil {
            do {
                _ = try environmentService.profile(for: server)
                if server.transport != .stdio {
                    issues.append(.init(severity: .error, message: String(localized: "Le token HTTP du Trousseau est utilisable pour les tests locaux seulement. La transmission des identifiants du Manager à Xcode n’est pas prise en charge.")))
                } else if !FileManager.default.isExecutableFile(atPath: environmentService.helperURL.path) {
                    issues.append(.init(severity: .error, message: String(localized: "Lanceur sécurisé introuvable. Utilisez l’app compilée complète.")))
                } else {
                    issues.append(.init(severity: .warning, message: String(localized: "Xcode utilisera le lanceur de MCP Manager. macOS peut demander l’accès au Trousseau. Ne déplacez pas l’app après installation. Les anciennes valeurs déjà présentes dans la configuration ne sont pas effacées automatiquement.")))
                }
            } catch {
                issues.append(.init(severity: .error, message: String(localized: "Profil de variables invalide ou modifié. Enregistrez à nouveau Variables et secrets.")))
            }
        } else if !requiredVariables.isEmpty {
            issues.append(.init(
                severity: .warning,
                message: String(localized: "Variables non gérées par MCP Manager : \(requiredVariables.joined(separator: ", ")). Leur présence dans l’environnement de Xcode n’est pas vérifiée.")
            ))
        }
        if target.kind == .claude, !requiredVariables.isEmpty, server.environmentProfileID == nil {
            issues.append(.init(
                severity: .error,
                message: String(localized: "L’installation Claude avec secrets n’est pas activée afin d’éviter leur écriture en clair.")
            ))
        }
        if target.isAlreadyConfigured {
            issues.append(.init(
                severity: .warning,
                message: String(localized: "L’entrée « \(target.configuredServerName ?? server.name) » sera mise à jour après sauvegarde.")
            ))
        }
        return issues
    }

    func install(
        _ server: MCPServer,
        into target: XcodeInstallationTarget
    ) async throws -> XcodeInstallationReceipt {
        try await Task.detached(priority: .userInitiated) {
            try installSynchronously(server, into: target)
        }.value
    }

    private func installSynchronously(
        _ original: MCPServer,
        into requestedTarget: XcodeInstallationTarget
    ) throws -> XcodeInstallationReceipt {
        guard !requestedTarget.isProjectConfiguration, original.xcodeBinding?.projectDirectoryURL == nil else {
            throw XcodeManagementError.unsupported(String(localized: "les configurations de projet sont en lecture seule."))
        }
        XcodeConfigurationLock.shared.lock()
        defer { XcodeConfigurationLock.shared.unlock() }
        if try XcodeMCPManagement(directory: codingAssistantDirectory).history().contains(where: {
            (!$0.completed || $0.restoring) && !$0.restored && $0.binding.kind == requestedTarget.kind
        }) { throw XcodeManagementError.incomplete }
        // Re-read immediately before writing: the sheet may have remained open while Xcode changed the file.
        guard let target = detectTargets(for: original).first(where: { $0.kind == requestedTarget.kind }) else {
            throw XcodeInstallationError.targetUnavailable
        }
        guard requestedTarget.isAlreadyConfigured == target.isAlreadyConfigured,
              requestedTarget.configuredServerName == target.configuredServerName,
              requestedTarget.revision == target.revision else { throw XcodeManagementError.conflict }
        var server = original
        server.name = target.configuredServerName ?? original.name
        guard target.isAvailable else { throw XcodeInstallationError.targetUnavailable }
        let issues = preflight(for: server, target: target)
        if target.kind == .claude,
           issues.contains(where: { $0.severity == .error && $0.message.contains("secrets") }) {
            throw XcodeInstallationError.unsupportedSecretConfiguration
        }
        if issues.contains(where: { $0.severity == .error }) {
            throw XcodeInstallationError.invalidConfiguration(
                issues.filter { $0.severity == .error }.map(\.message).joined(separator: " ")
            )
        }

        // A new immutable, agent-specific profile leaves other agents and rollback history intact.
        server = environmentService.wrapped(try environmentService.scopedCopy(server, target: target))
        // Keychain authorization can take time. Recheck the entry after that interaction.
        guard let latest = detectTargets(for: original).first(where: { $0.kind == target.kind }),
              latest.detectionError == nil,
              latest.isAlreadyConfigured == target.isAlreadyConfigured,
              latest.configuredServerName == target.configuredServerName,
              latest.revision == target.revision else { throw XcodeManagementError.conflict }

        let fileManager = FileManager.default
        let existed = fileManager.fileExists(atPath: target.configurationURL.path)
        let backupURL = try existed ? backup(target.configurationURL) : nil
        try fileManager.createDirectory(
            at: target.configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch target.kind {
        case .codex:
            let existing = existed
                ? (try String(contentsOf: target.configurationURL, encoding: .utf8))
                : ""
            let updated = try upsertCodexServer(server, in: existing)
            try Data(updated.utf8).write(to: target.configurationURL, options: .atomic)
        case .claude:
            let existingData = existed ? try Data(contentsOf: target.configurationURL) : Data("{}".utf8)
            let updated = try upsertClaudeServer(server, in: existingData)
            try updated.write(to: target.configurationURL, options: .atomic)
        }

        guard containsServer(named: server.name, in: target.configurationURL, target: target.kind) else {
            throw XcodeInstallationError.invalidConfiguration(String(localized: "la vérification après écriture a échoué"))
        }
        return XcodeInstallationReceipt(
            target: target.kind,
            configurationURL: target.configurationURL,
            backupURL: backupURL,
            replacedExistingEntry: target.isAlreadyConfigured
        )
    }

    private func configurationURL(for target: XcodeInstallationTarget.Kind) -> URL {
        switch target {
        case .codex:
            codingAssistantDirectory.appending(path: "codex/config.toml")
        case .claude:
            codingAssistantDirectory.appending(path: "ClaudeAgentConfig/.claude.json")
        }
    }

    private func upsertCodexServer(_ server: MCPServer, in existing: String) throws -> String {
        let document = try TOMLServerDocument(Data(existing.utf8))
        let block = CodexConfigRenderer.render(server).components(separatedBy: .newlines)
        guard let root = document.sections.first(where: { $0.path == ["mcp_servers", server.name] }) else {
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            return existing + separator + block.joined(separator: "\n") + "\n"
        }
        // Table and assignment boundaries come from the same scanner as lifecycle operations.
        // In particular, a bracketed line inside a multiline string is never a section.
        let managedKeys: Set<String> = ["command", "args", "url", "env_vars", "bearer_token_env_var", "enabled"]
        let assignments = root.range.filter { document.assignmentLines.contains($0) }
        var removed = Set<Int>()
        for (offset, index) in assignments.enumerated() {
            let rawKey = document.lines[index].split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if managedKeys.contains(key) {
                let end = offset + 1 < assignments.count ? assignments[offset + 1] : root.range.upperBound
                removed.formUnion(index..<end)
            }
        }
        let retained = root.range.dropFirst().filter { !removed.contains($0) }.map { document.lines[$0] }
        var header = document.lines[root.range.lowerBound]
        if !header.hasSuffix("\n") { header += "\n" }
        var updated = document.lines
        updated.replaceSubrange(root.range, with: [header, block.dropFirst().joined(separator: "\n") + "\n"] + retained)
        return updated.joined()
    }

    private func upsertClaudeServer(_ server: MCPServer, in existing: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw XcodeInstallationError.invalidConfiguration(String(localized: "racine JSON incorrecte"))
        }
        if let value = root["mcpServers"], !(value is [String: Any]) {
            throw XcodeInstallationError.invalidConfiguration(String(localized: "mcpServers doit être un objet JSON"))
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        var definition = servers[server.name] as? [String: Any] ?? [:]
        for key in ["type", "command", "args", "url"] { definition.removeValue(forKey: key) }
        definition.merge(claudeDefinition(for: server)) { _, new in new }
        servers[server.name] = definition
        root["mcpServers"] = servers
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func claudeDefinition(for server: MCPServer) -> [String: Any] {
        switch server.transport {
        case .stdio:
            var definition: [String: Any] = [
                "type": "stdio",
                "command": server.command
            ]
            if !server.arguments.isEmpty { definition["args"] = server.arguments }
            return definition
        case .streamableHTTP:
            return ["type": "http", "url": server.url]
        }
    }

    private func containsServer(
        named name: String,
        in url: URL,
        target: XcodeInstallationTarget.Kind
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        switch target {
        case .codex:
            guard let data = try? Data(contentsOf: url), let document = try? TOMLServerDocument(data) else { return false }
            return document.sections.contains { $0.path == ["mcp_servers", name] }
        case .claude:
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any] else { return false }
            return servers[name] != nil
        }
    }

    private func sameConnection(_ lhs: MCPServer, _ rhs: MCPServer, toolPaths: [String: String]) -> Bool {
        guard lhs.transport == rhs.transport else { return false }
        switch lhs.transport {
        case .streamableHTTP:
            return lhs.url == rhs.url && lhs.bearerTokenEnvironmentVariable == rhs.bearerTokenEnvironmentVariable
        case .stdio:
            func invocation(_ server: MCPServer) -> [String] {
                if ["xcrun", "/usr/bin/xcrun"].contains(server.command),
                   let tool = server.arguments.first,
                   ["mcpbridge", "lldb-mcp"].contains(tool),
                   let path = toolPaths[tool] {
                    return [path] + server.arguments.dropFirst()
                }
                let command = server.command == "/usr/bin/xcrun" ? "xcrun" : server.command
                return [command] + server.arguments
            }
            return invocation(lhs) == invocation(rhs)
                && !lhs.arguments.contains("<secret non importé>")
        }
    }

    private static var currentDeveloperToolPaths: [String: String] {
        var paths: [String: String] = [:]
        for tool in ["mcpbridge", "lldb-mcp"] {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["--find", tool]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   let path = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   path.hasPrefix("/") {
                    paths[tool] = path
                }
            } catch { continue }
        }
        return paths
    }

    private func backup(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
            .appending(path: ".mcp-manager-backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let suffix = UUID().uuidString.prefix(8)
        let backupURL = directory.appending(
            path: "\(url.lastPathComponent).\(formatter.string(from: .now))-\(suffix).backup"
        )
        try FileManager.default.copyItem(at: url, to: backupURL)
        return backupURL
    }

    private func commandAppearsAvailable(_ command: String) -> Bool {
        if command.contains("/") { return FileManager.default.isExecutableFile(atPath: command) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let searchDirectories = [
            home.appending(path: ".local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin")
        ]
        return searchDirectories.contains {
            FileManager.default.isExecutableFile(atPath: $0.appending(path: command).path)
        }
    }
}
