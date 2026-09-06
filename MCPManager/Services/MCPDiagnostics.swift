import Foundation

/// Pure diagnostic policy. Sensitive details are bounded and never persisted here.
enum MCPDiagnostics {
    static func appending(_ message: String, to logs: [String], at date: Date = .now) -> [String] {
        guard !message.isEmpty else { return logs }
        let timestamp = date.formatted(date: .omitted, time: .standard)
        return Array((logs + ["[\(timestamp)] \(message)"]).suffix(250))
    }

    static func detail(_ error: Error) -> String? {
        (error as? MCPClientError).map { String($0.diagnosticDescription.prefix(8000)) }
    }

    static func needsXcodeRelink(_ error: Error) -> Bool {
        switch error as? MCPClientError {
        case .xcodeTargetMissing, .xcodeServiceUnavailable: true
        default: false
        }
    }

    static func message(_ error: Error, protected: Bool) -> String {
        if let error = error as? MCPOAuthError { return error.localizedDescription }
        if let error = error as? MCPLocalCredentialError { return error.localizedDescription }
        if protected, let error = error as? MCPClientError { return error.protectedDescription }
        return protected
            ? String(localized: "Échec de la communication avec le serveur MCP. Le détail est masqué pour protéger les secrets.")
            : error.localizedDescription
    }
}
