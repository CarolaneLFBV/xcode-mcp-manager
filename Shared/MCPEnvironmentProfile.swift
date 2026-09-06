// Shared by the app and its standalone environment launcher.
import Foundation
import CryptoKit

struct MCPEnvironmentVariable: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var isSecret: Bool
    var value: String?
    var id: String { name }
}

struct MCPEnvironmentProfile: Codable, Sendable {
    let id: UUID
    let scope: String
    let command: String
    let arguments: [String]
    let url: String
    let transport: String
    let bearerVariable: String
    let variables: [MCPEnvironmentVariable]

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try! encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

struct MCPEnvironmentDraft: Identifiable, Sendable {
    var id = UUID()
    var name: String
    var isSecret = true
    var value = ""
    var wasStored = false
}

enum MCPEnvironmentError: LocalizedError {
    case invalid(String)
    case keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .keychain(-50): String(localized: "Le Trousseau a refusé la requête (code -50). Le stockage sécurisé n’a pas pu être validé dans ce contexte d’exécution.", bundle: MCPLocalization.bundle)
        case .keychain(-25300): String(localized: "Le secret n’a pas été trouvé dans le Trousseau. Saisissez à nouveau sa valeur.", bundle: MCPLocalization.bundle)
        case .keychain(let code): String(localized: "Le Trousseau n’est pas accessible (code \(code)). Autorisez l’accès ou déverrouillez votre session.", bundle: MCPLocalization.bundle)
        }
    }
}

enum MCPEnvironmentRuntime {
    static func validate(_ variables: [MCPEnvironmentVariable]) throws {
        guard Set(variables.map(\.name)).count == variables.count else {
            throw MCPEnvironmentError.invalid(String(localized: "Chaque variable doit avoir un nom unique.", bundle: MCPLocalization.bundle))
        }
        for variable in variables {
            guard variable.name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                throw MCPEnvironmentError.invalid(String(localized: "Nom de variable invalide : utilisez lettres, chiffres et traits de soulignement.", bundle: MCPLocalization.bundle))
            }
            guard !variable.name.hasPrefix("DYLD_"), !variable.name.hasPrefix("LD_"),
                  !["BASH_ENV", "ENV"].contains(variable.name) else {
                throw MCPEnvironmentError.invalid(String(localized: "Les variables d’injection du chargeur ou du shell ne sont pas autorisées.", bundle: MCPLocalization.bundle))
            }
            if let value = variable.value, value.utf8.contains(0) || value.utf8.count > 65_536 {
                throw MCPEnvironmentError.invalid(String(localized: "Valeur invalide ou trop longue.", bundle: MCPLocalization.bundle))
            }
            guard !variable.isSecret || variable.value == nil else {
                throw MCPEnvironmentError.invalid(String(localized: "Un secret ne doit pas figurer dans les métadonnées du profil.", bundle: MCPLocalization.bundle))
            }
        }
    }

    static func baseEnvironment(_ inherited: [String: String]) -> [String: String] {
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL"]
        var result = inherited.filter { allowed.contains($0.key) }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let home = result["HOME"] { result["PATH"] = home + "/.local/bin:" + result["PATH"]! }
        return result
    }

    static func environment(profile: MCPEnvironmentProfile, secrets: [String: String], inherited: [String: String]) throws -> [String: String] {
        try validate(profile.variables)
        var result = baseEnvironment(inherited)
        for variable in profile.variables {
            guard let value = variable.isSecret ? secrets[variable.name] : variable.value,
                  !value.utf8.contains(0), value.utf8.count <= 65_536,
                  !variable.isSecret || !value.isEmpty else {
                throw MCPEnvironmentError.invalid(String(localized: "Une variable est manquante ou invalide. Ouvrez Variables et secrets dans MCP Manager.", bundle: MCPLocalization.bundle))
            }
            result[variable.name] = value
        }
        return result
    }
}
