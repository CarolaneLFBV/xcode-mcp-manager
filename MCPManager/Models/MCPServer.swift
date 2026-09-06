import Foundation

struct MCPServer: Identifiable, Codable, Hashable, Sendable {
    var supportsXcodeRelink: Bool {
        guard transport == .stdio, environmentProfileID == nil else { return false }
        let executable = URL(fileURLWithPath: command).lastPathComponent
        return (executable == "mcpbridge" && arguments.isEmpty)
            || (executable == "xcrun" && arguments == ["mcpbridge"])
    }
    enum Transport: String, Codable, CaseIterable, Identifiable, Sendable {
        case stdio
        case streamableHTTP

        var id: Self { self }

        var title: String {
            switch self {
            case .stdio: "STDIO"
            case .streamableHTTP: "Streamable HTTP"
            }
        }
    }

    enum Scope: String, Codable, CaseIterable, Identifiable, Sendable {
        case global
        case project

        var id: Self { self }
        var title: String { self == .global ? "Global" : String(localized: "Projet") }
    }

    var id: UUID
    var name: String
    var transport: Transport
    var command: String
    var arguments: [String]
    var environmentVariableNames: [String]
    var url: String
    var bearerTokenEnvironmentVariable: String
    var scope: Scope
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var xcodeBinding: XcodeServerBinding? = nil
    var environmentProfileID: UUID? = nil
    var configurationSource: MCPConfigurationSource? = nil

    init(
        id: UUID = UUID(),
        name: String = "",
        transport: Transport = .stdio,
        command: String = "",
        arguments: [String] = [],
        environmentVariableNames: [String] = [],
        url: String = "",
        bearerTokenEnvironmentVariable: String = "",
        scope: Scope = .global,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.environmentVariableNames = environmentVariableNames
        self.url = url
        self.bearerTokenEnvironmentVariable = bearerTokenEnvironmentVariable
        self.scope = scope
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if arguments.contains(where: { $0.contains("<secret non importé>") }) {
            issues.append(String(localized: "Complétez les arguments masqués lors de l’import avant d’installer ce serveur."))
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(String(localized: "Le nom est obligatoire."))
        }

        switch transport {
        case .stdio:
            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(String(localized: "La commande STDIO est obligatoire."))
            }
        case .streamableHTTP:
            guard let parsedURL = URL(string: url),
                  let scheme = parsedURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  parsedURL.host != nil else {
                issues.append(String(localized: "L’URL HTTP n’est pas valide."))
                return issues
            }
        }

        return issues
    }

    var isValid: Bool { validationIssues.isEmpty }

    static var blank: MCPServer { MCPServer() }
}
