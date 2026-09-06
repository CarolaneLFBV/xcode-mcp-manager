import Foundation

enum MCPWire {
    static let modernProtocolVersion = "2026-07-28"
    static let latestLegacyProtocolVersion = "2025-11-25"

    static var modernMetadata: JSONValue {
        .object([
            "io.modelcontextprotocol/protocolVersion": .string(modernProtocolVersion),
            "io.modelcontextprotocol/clientInfo": .object([
                "name": .string("MCP Manager"),
                "version": .string(MCPAppVersion.current)
            ]),
            "io.modelcontextprotocol/clientCapabilities": .object([:])
        ])
    }

    static func requestData(id: Int, method: String, params: JSONValue) throws -> Data {
        try encode(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ]))
    }

    static func notificationData(method: String, params: JSONValue) throws -> Data {
        try encode(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ]))
    }

    static func result(from response: JSONValue) throws -> JSONValue {
        guard let object = response.objectValue else {
            throw MCPClientError.invalidMessage(String(localized: "Réponse JSON-RPC invalide."))
        }
        if let error = object["error"]?.objectValue {
            throw MCPClientError.rpc(
                code: error["code"]?.integerValue ?? -32000,
                message: error["message"]?.stringValue ?? "Erreur inconnue"
            )
        }
        guard let result = object["result"] else {
            throw MCPClientError.invalidMessage(String(localized: "La réponse MCP ne contient aucun résultat."))
        }
        return result
    }

    static func responseID(from response: JSONValue) -> Int? { response["id"]?.integerValue }
    static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
    static func encode(_ value: JSONValue) throws -> Data { try JSONEncoder().encode(value) }

    static func params(cursor: String?, modern: Bool) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let cursor { object["cursor"] = .string(cursor) }
        if modern { object["_meta"] = modernMetadata }
        return .object(object)
    }

    static func tools(from result: JSONValue) throws -> ([MCPTool], String?) {
        try validateSuccess(result)
        guard let values = result["tools"]?.arrayValue else {
            throw MCPClientError.invalidMessage(String(localized: "Le serveur n’a pas renvoyé de liste d’outils."))
        }
        let decoder = JSONDecoder()
        let tools = try values.map { try decoder.decode(MCPTool.self, from: encode($0)) }
        return (tools, result["nextCursor"]?.stringValue)
    }

    /// Some bridges encode protocol failures inside result, not JSON-RPC error.
    static func validateDiscovery(_ result: JSONValue) throws {
        if result["isError"] == .bool(true),
           errorText(result).contains("unknown method 'server/discover'") {
            throw MCPClientError.rpc(code: -32601, message: String(localized: "server/discover non pris en charge."))
        }
        try validateSuccess(result)
        guard let versions = result["supportedVersions"]?.arrayValue,
              versions.contains(.string(modernProtocolVersion)) else {
            throw MCPClientError.unsupportedProtocol
        }
    }

    static func validateSuccess(_ result: JSONValue) throws {
        guard result["isError"] == .bool(true) else { return }
        let text = errorText(result)
        if text.contains("RBSAssertionErrorDomain Code=2"), text.contains("does not exist") {
            throw MCPClientError.xcodeTargetMissing(detail: String(text.prefix(8000)))
        }
        if text.contains("Error Domain=NSCocoaErrorDomain Code=4099"),
           text.contains("helper application") {
            throw MCPClientError.xcodeServiceUnavailable(detail: String(text.prefix(8000)))
        }
        let detail = text.isEmpty ? String(data: (try? encode(result)) ?? Data(), encoding: .utf8) ?? String(localized: "Erreur sans détail.") : text
        throw MCPClientError.remoteFailure(detail: String(detail.prefix(8000)))
    }

    private static func errorText(_ result: JSONValue) -> String {
        (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    static func identity(from result: JSONValue, era: MCPServerIdentity.Era) -> MCPServerIdentity {
        let object = result.objectValue ?? [:]
        let metadataInfo = object["_meta"]?["io.modelcontextprotocol/serverInfo"]?.objectValue
        let directInfo = object["serverInfo"]?.objectValue
        let info = metadataInfo ?? directInfo ?? [:]

        let protocolVersion: String
        if era == .modern {
            protocolVersion = object["supportedVersions"]?.arrayValue?
                .compactMap(\.stringValue)
                .first(where: { $0 == modernProtocolVersion }) ?? modernProtocolVersion
        } else {
            protocolVersion = object["protocolVersion"]?.stringValue ?? latestLegacyProtocolVersion
        }

        return MCPServerIdentity(
            name: info["name"]?.stringValue ?? "Serveur MCP",
            version: info["version"]?.stringValue ?? "Version inconnue",
            protocolVersion: protocolVersion,
            instructions: object["instructions"]?.stringValue,
            era: era
        )
    }
}
