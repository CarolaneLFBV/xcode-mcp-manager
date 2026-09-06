import Foundation

struct XcodeInstallationTarget: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case codex
        case claude

        var shortTitle: String { self == .codex ? "Codex" : "Claude" }

        var title: String {
            switch self {
            case .codex: String(localized: "Codex dans Xcode")
            case .claude: String(localized: "Claude dans Xcode")
            }
        }

        var symbolName: String {
            switch self {
            case .codex: "chevron.left.forwardslash.chevron.right"
            case .claude: "sparkles"
            }
        }

        var detail: String {
            switch self {
            case .codex: String(localized: "Recommandé · configuration TOML dédiée à Xcode")
            case .claude: String(localized: "Configuration JSON dédiée à Xcode")
            }
        }
    }

    let kind: Kind
    let configurationURL: URL
    let isAvailable: Bool
    let isAlreadyConfigured: Bool
    var configuredServerName: String? = nil
    var isDisabled: Bool = false
    var detectionError: String? = nil
    var revision: String? = nil
    var projectDirectoryURL: URL? = nil

    var id: String { "\(kind.rawValue):\(configurationURL.standardizedFileURL.path)" }
    var isProjectConfiguration: Bool { projectDirectoryURL != nil }
    var scopeTitle: String { projectDirectoryURL.map { String(localized: "Projet · \($0.lastPathComponent)") } ?? "Global" }

    var statusTitle: String {
        if detectionError != nil { return String(localized: "État à vérifier") }
        if let projectDirectoryURL {
            return String(localized: "Configuré pour \(projectDirectoryURL.lastPathComponent)\(isDisabled ? String(localized: " · désactivé") : "")")
        }
        if isAlreadyConfigured { return isDisabled ? String(localized: "Installé · désactivé") : String(localized: "Installé") }
        return isAvailable ? String(localized: "Non installé") : String(localized: "Agent non détecté")
    }

    var actionTitle: String { isAlreadyConfigured ? String(localized: "Mettre à jour") : String(localized: "Installer") }
}

struct XcodePreflightIssue: Identifiable, Hashable, Sendable {
    enum Severity: Sendable {
        case warning
        case error
    }

    let severity: Severity
    let message: String
    var id: String { "\(severity)-\(message)" }
}

struct XcodeInstallationReceipt: Sendable {
    let target: XcodeInstallationTarget.Kind
    let configurationURL: URL
    let backupURL: URL?
    let replacedExistingEntry: Bool
}

enum XcodeInstallationError: LocalizedError, Sendable {
    case targetUnavailable
    case invalidConfiguration(String)
    case unsupportedSecretConfiguration

    var errorDescription: String? {
        switch self {
        case .targetUnavailable:
            String(localized: "Cet agent n’est pas encore installé dans Xcode.")
        case .invalidConfiguration(let message):
            "Configuration Xcode invalide : \(message)"
        case .unsupportedSecretConfiguration:
            String(localized: "Cette cible nécessite des secrets explicites. Choisissez Codex pour conserver des références sécurisées par variables d’environnement.")
        }
    }
}
