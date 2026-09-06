import Foundation

struct HTTPMCPTransport: Sendable {
    struct Reply: Sendable {
        let result: JSONValue
        let statusCode: Int
        let sessionID: String?
    }

    let server: MCPServer
    var sourceCredentials: MCPLocalCredentials? = nil

    func request(
        id: Int,
        method: String,
        params: JSONValue,
        protocolVersion: String? = nil,
        sessionID: String? = nil
    ) async throws -> Reply {
        let body = try MCPWire.requestData(id: id, method: method, params: params)
        let (data, response) = try await send(
            data: body,
            method: method,
            protocolVersion: protocolVersion,
            sessionID: sessionID
        )
        let value = try decodeResponse(data)
        return Reply(
            result: try MCPWire.result(from: value),
            statusCode: response.statusCode,
            sessionID: response.value(forHTTPHeaderField: "Mcp-Session-Id")
        )
    }

    func notify(method: String, params: JSONValue, protocolVersion: String, sessionID: String?) async throws {
        let body = try MCPWire.notificationData(method: method, params: params)
        _ = try await send(data: body, method: method, protocolVersion: protocolVersion, sessionID: sessionID)
    }

    private func send(
        data: Data,
        method: String,
        protocolVersion: String?,
        sessionID: String?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: server.url) else {
            throw MCPClientError.invalidMessage("URL MCP invalide.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if protocolVersion == MCPWire.modernProtocolVersion {
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let source = try sourceCredentials ?? MCPLocalCredentialResolver().resolve(server)
        try MCPLocalCredentialResolver.validateHeaders(source.headers, url: server.url)
        for (name, value) in source.headers { request.setValue(value, forHTTPHeaderField: name) }
        var token: String?
        if server.environmentProfileID != nil {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
                throw MCPEnvironmentError.invalid(String(localized: "Un token du Trousseau ne peut être envoyé qu’à une URL HTTPS sans identifiants dans l’adresse."))
            }
            let service = MCPEnvironmentService()
            guard let profile = try service.profile(for: server) else { throw MCPEnvironmentError.invalid(String(localized: "Profil manquant.")) }
            token = try service.storage.environment(profile)[server.bearerTokenEnvironmentVariable]
            guard let value = token, !value.isEmpty else {
                throw MCPEnvironmentError.invalid(String(localized: "Token HTTP manquant ou invalide."))
            }
            try MCPLocalCredentialResolver.validateHeaders(["Authorization": "Bearer \(value)"], url: server.url)
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let protected = server.environmentProfileID != nil || !source.headers.isEmpty || token != nil
        let session = !protected ? URLSession.shared
            : URLSession(configuration: .ephemeral, delegate: MCPNoRedirectDelegate(), delegateQueue: nil)
        defer { if protected { session.invalidateAndCancel() } }
        let (responseData, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw MCPClientError.invalidMessage(String(localized: "Réponse HTTP invalide."))
        }
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                if source.oauth { throw response.statusCode == 403 ? MCPOAuthError.permissions : MCPOAuthError.expired }
                throw MCPLocalCredentialError.authentication
            }
            if protected {
                throw MCPClientError.httpStatus(response.statusCode, String(localized: "Réponse masquée pour protéger le token."))
            }
            if let value = try? decodeResponse(responseData), let error = value["error"]?.objectValue {
                throw MCPClientError.rpc(
                    code: error["code"]?.integerValue ?? -32000,
                    message: error["message"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                )
            }
            let message = String(data: responseData, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw MCPClientError.httpStatus(response.statusCode, message)
        }
        return (responseData, response)
    }

    private func decodeResponse(_ data: Data) throws -> JSONValue {
        if let value = try? MCPWire.decode(data) { return value }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidMessage(String(localized: "Corps de réponse MCP illisible."))
        }
        for event in text.components(separatedBy: "\n\n") {
            let payload = event.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            if let payloadData = payload.data(using: .utf8),
               let value = try? MCPWire.decode(payloadData),
               MCPWire.responseID(from: value) != nil {
                return value
            }
        }
        throw MCPClientError.invalidMessage(String(localized: "Aucune réponse JSON-RPC trouvée dans le flux HTTP."))
    }
}

private final class MCPNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
