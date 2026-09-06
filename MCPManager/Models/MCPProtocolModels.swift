import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

struct MCPTool: Identifiable, Codable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let title: String?
    let description: String?
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let annotations: JSONValue?

    init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue = .object(["type": .string("object")]),
        outputSchema: JSONValue? = nil,
        annotations: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }
}

struct MCPServerIdentity: Equatable, Sendable {
    enum Era: String, Sendable {
        case modern = "MCP moderne"
        case legacy = "MCP avec handshake"
        var title: String {
            self == .modern ? String(localized: "MCP moderne") : String(localized: "MCP avec handshake")
        }
    }

    let name: String
    let version: String
    let protocolVersion: String
    let instructions: String?
    let era: Era
}

enum MCPClientError: LocalizedError, Equatable, Sendable {
    case closed
    case invalidMessage(String)
    case rpc(code: Int, message: String)
    case timeout(String)
    case processTerminated(Int32)
    case processFailure(code: Int32, detail: String)
    case httpStatus(Int, String)
    case unsupportedProtocol
    case remoteFailure(detail: String)
    case xcodeServiceUnavailable(detail: String)
    case xcodeTargetMissing(detail: String)

    var errorDescription: String? {
        switch self {
        case .closed: String(localized: "Connexion MCP fermée.")
        case .invalidMessage(let message): message
        case .rpc(let code, let message): String(localized: "Erreur MCP \(code) : \(message)")
        case .timeout(let method): String(localized: "Délai dépassé pour \(method).")
        case .processTerminated(let code): String(localized: "Le serveur s’est arrêté avec le code \(code).")
        case .processFailure(let code, _): String(localized: "Le serveur s’est arrêté avec le code \(code). Consultez le détail du diagnostic de démarrage.")
        case .httpStatus(let code, let message): "HTTP \(code) : \(message)"
        case .unsupportedProtocol: String(localized: "Version du protocole MCP non prise en charge.")
        case .remoteFailure: String(localized: "Le serveur MCP a refusé la demande. Son détail est masqué pour protéger les secrets.")
        case .xcodeServiceUnavailable: String(localized: "Le bridge ne peut pas joindre le service Xcode. Vérifiez que Xcode est ouvert et que le PID et la session de la configuration source sont encore valides.")
        case .xcodeTargetMissing: String(localized: "L’ancien processus Xcode n’existe plus. Ouvrez Xcode, puis utilisez « Relier à Xcode » pour créer une nouvelle connexion locale.")
        }
    }

    var protectedDescription: String {
        switch self {
        case .closed, .processTerminated, .processFailure, .unsupportedProtocol, .remoteFailure, .xcodeServiceUnavailable, .xcodeTargetMissing:
            return errorDescription ?? String(localized: "Échec MCP.")
        case .timeout: return String(localized: "Le serveur MCP n’a pas répondu dans le délai prévu.")
        case .invalidMessage: return String(localized: "Réponse MCP invalide ou inattendue. Le détail est masqué pour protéger les secrets.")
        case .rpc(let code, _): return String(localized: "Le serveur a renvoyé une erreur MCP (code \(code)). Le détail est masqué pour protéger les secrets.")
        case .httpStatus(let code, _): return String(localized: "Le serveur a renvoyé HTTP \(code). Le détail est masqué pour protéger les secrets.")
        }
    }

    /// Only for the explicitly confirmed, in-memory diagnostic viewer.
    var diagnosticDescription: String {
        switch self {
        case .processFailure(_, let detail): return detail
        case .remoteFailure(let detail), .xcodeServiceUnavailable(let detail), .xcodeTargetMissing(let detail): return detail
        default: return errorDescription ?? String(localized: "Erreur MCP sans détail.")
        }
    }

    var allowsLegacyFallback: Bool {
        switch self {
        case .rpc(let code, _): [-32601, -32020, -32021, -32022].contains(code)
        case .httpStatus(let code, _): code == 400
        case .timeout, .processTerminated, .unsupportedProtocol: true
        default: false
        }
    }
}
