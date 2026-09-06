import Foundation

/// Creates immutable environment profiles and prepares their secure STDIO launcher.
///
/// Ordinary values live in private profile files; secrets remain in Keychain.
/// HTTP profiles currently serve Manager tests only, not Xcode installation.
struct MCPEnvironmentService: Sendable {
    let storage: MCPEnvironmentStorage
    let helperURL: URL

    init(storage: MCPEnvironmentStorage = MCPEnvironmentStorage(), helperURL: URL? = nil) {
        self.storage = storage
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appending(path: "Contents/Helpers/mcp-manager-launcher")
    }

    func profile(for server: MCPServer) throws -> MCPEnvironmentProfile? {
        guard let id = server.environmentProfileID else { return nil }
        let profile = try storage.profile(id)
        guard profile.command == server.command, profile.arguments == server.arguments,
              profile.url == server.url, profile.transport == server.transport.rawValue,
              profile.bearerVariable == server.bearerTokenEnvironmentVariable,
              Set(profile.variables.map(\.name)) == Set(requiredNames(server)) else {
            throw MCPEnvironmentError.invalid(String(localized: "La connexion a changé. Enregistrez à nouveau Variables et secrets pour autoriser cette configuration."))
        }
        return profile
    }

    func requiredNames(_ server: MCPServer) -> [String] {
        Array(Set(server.environmentVariableNames + [server.bearerTokenEnvironmentVariable]).filter { !$0.isEmpty }).sorted()
    }

    func drafts(for server: MCPServer) throws -> [MCPEnvironmentDraft] {
        let profile = try server.environmentProfileID.map { try storage.profile($0) }
        return Array(Set(requiredNames(server) + (profile?.variables.map(\.name) ?? []))).sorted().map { name in
            let existing = profile?.variables.first { $0.name == name }
            return MCPEnvironmentDraft(name: name, isSecret: existing?.isSecret ?? true,
                value: existing?.value ?? "", wasStored: existing?.isSecret == true)
        }
    }

    func save(server: MCPServer, drafts: [MCPEnvironmentDraft], scope: String) throws -> MCPServer {
        let previous = try server.environmentProfileID.map { try storage.profile($0) }
        // Reading old secrets is only necessary when explicitly keeping one, never during scans.
        let needsPrevious = drafts.contains { $0.isSecret && $0.value.isEmpty && $0.wasStored }
        let oldSecrets = try needsPrevious ? previous.map { try storage.secrets($0) } ?? [:] : [:]
        let variables = drafts.map { MCPEnvironmentVariable(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
            isSecret: $0.isSecret, value: $0.isSecret ? nil : $0.value) }
        try MCPEnvironmentRuntime.validate(variables)
        var secrets: [String: String] = [:]
        for (draft, variable) in zip(drafts, variables) where draft.isSecret {
            secrets[variable.name] = draft.value.isEmpty && draft.wasStored ? oldSecrets[variable.name] : draft.value
        }
        var updated = server
        if server.transport == .streamableHTTP {
            guard variables.count == 1, variables[0].name == server.bearerTokenEnvironmentVariable,
                  variables[0].isSecret else {
                throw MCPEnvironmentError.invalid(String(localized: "Pour HTTP, configurez une seule variable secrète : celle du bearer token."))
            }
        } else {
            updated.environmentVariableNames = variables.map(\.name).sorted()
        }
        let profile = MCPEnvironmentProfile(id: UUID(), scope: scope, command: updated.command,
            arguments: updated.arguments, url: updated.url, transport: updated.transport.rawValue,
            bearerVariable: updated.bearerTokenEnvironmentVariable, variables: variables)
        try storage.save(profile, secrets: secrets)
        updated.environmentProfileID = profile.id
        return updated
    }

    func scopedCopy(_ server: MCPServer, target: XcodeInstallationTarget) throws -> MCPServer {
        guard let source = try profile(for: server) else { return server }
        let scope = "\(target.kind.shortTitle) · \(target.configurationURL.standardizedFileURL.path) · \(target.configuredServerName ?? server.name)"
        let copy = MCPEnvironmentProfile(id: UUID(), scope: scope, command: source.command, arguments: source.arguments,
            url: source.url, transport: source.transport, bearerVariable: source.bearerVariable, variables: source.variables)
        try storage.save(copy, secrets: storage.secrets(source))
        var server = server
        server.environmentProfileID = copy.id
        return server
    }

    func wrapped(_ server: MCPServer) -> MCPServer {
        guard let id = server.environmentProfileID, server.transport == .stdio else { return server }
        var wrapped = server
        wrapped.command = helperURL.path
        wrapped.arguments = ["--profile", id.uuidString]
        wrapped.environmentVariableNames = []
        wrapped.environmentProfileID = nil
        return wrapped
    }

    func unwrapped(_ server: MCPServer) throws -> MCPServer {
        guard URL(fileURLWithPath: server.command).lastPathComponent == "mcp-manager-launcher",
              server.arguments.first == "--profile" else { return server }
        guard server.arguments.count == 2, let id = UUID(uuidString: server.arguments[1]) else {
            throw MCPEnvironmentError.invalid(String(localized: "Référence du lanceur MCP Manager invalide."))
        }
        let profile = try storage.profile(id)
        guard profile.transport == MCPServer.Transport.stdio.rawValue else {
            throw MCPEnvironmentError.invalid(String(localized: "Profil incompatible avec le lanceur local."))
        }
        var result = server
        result.command = profile.command
        result.arguments = profile.arguments
        result.url = profile.url
        result.bearerTokenEnvironmentVariable = profile.bearerVariable
        result.environmentVariableNames = profile.variables.map(\.name)
        result.environmentProfileID = profile.id
        return result
    }

    func checkTransmission(_ server: MCPServer) throws -> String {
        guard let profile = try profile(for: server) else { throw MCPEnvironmentError.invalid(String(localized: "Enregistrez d’abord les variables.")) }
        if server.transport == .streamableHTTP {
            _ = try storage.environment(profile)
            return String(localized: "Secret accessible pour le test HTTP local. Transmission à Xcode non prise en charge.")
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw MCPEnvironmentError.invalid(String(localized: "Lanceur manquant. Utilisez l’app compilée complète."))
        }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--check", profile.id.uuidString]
        process.environment = MCPEnvironmentRuntime.baseEnvironment(ProcessInfo.processInfo.environment)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchSource.makeTimerSource()
        timeout.schedule(deadline: .now() + 45)
        timeout.setEventHandler { if process.isRunning { process.terminate() } }
        timeout.resume()
        defer { timeout.cancel() }
        // A locked Keychain may request user interaction; the UI calls this off the main thread.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, String(data: data, encoding: .utf8) == "MCP_MANAGER_ENV_OK\n" else {
            throw MCPEnvironmentError.invalid(String(localized: "Transmission non vérifiée. Vérifiez l’accès au Trousseau du lanceur et le profil."))
        }
        return String(localized: "Transmission locale vérifiée vers un processus de contrôle. La conversation Xcode n’a pas été testée.")
    }
}
