import Foundation
import CryptoKit
import Security

enum MCPOAuthError: LocalizedError {
    case unsupported, metadata, callback, cancelled, timeout, registration, token, expired, permissions, storage, network
    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Ce premier parcours prend en charge Sentry MCP en HTTPS, sans paramètres d’URL. Les autres fournisseurs seront ajoutés après validation.")
        case .metadata: String(localized: "Les métadonnées OAuth ne correspondent pas au fournisseur attendu ou aux protections requises.")
        case .callback: String(localized: "Retour OAuth invalide. La connexion n’a pas été acceptée.")
        case .cancelled: String(localized: "Connexion annulée ou autorisation refusée.")
        case .timeout: String(localized: "Le délai de connexion est écoulé. Vous pouvez réessayer.")
        case .registration: String(localized: "Sentry n’a pas accepté l’enregistrement de cette app native. Aucun compte n’a été connecté.")
        case .token: String(localized: "L’échange OAuth a échoué. Reconnectez-vous ; aucun détail contenant des identifiants n’est affiché.")
        case .expired: String(localized: "L’autorisation doit être renouvelée. Cliquez sur Se reconnecter.")
        case .permissions: String(localized: "Sentry a refusé l’accès (403). Vérifiez les permissions autorisées et vos droits sur l’organisation ou le projet.")
        case .storage: String(localized: "Le Trousseau n’a pas permis de conserver ou de lire cette connexion. Aucun stockage en clair n’est utilisé.")
        case .network: String(localized: "Le service OAuth est inaccessible ou a refusé la requête. Réessayez plus tard.")
        }
    }
}

struct MCPOAuthMetadata: Codable, Sendable {
    let issuer: String
    let authorization_endpoint: String
    let token_endpoint: String
    let registration_endpoint: String?
    let code_challenge_methods_supported: [String]?
    let response_types_supported: [String]?
    let token_endpoint_auth_methods_supported: [String]?
    let authorization_response_iss_parameter_supported: Bool?
}

struct MCPOAuthDiscovery: Sendable {
    let resource: String
    let metadata: MCPOAuthMetadata
    let scopes: [String]
}

/// Credentials are encoded only for our Keychain, never for the catalogue.
struct MCPOAuthRecord: Codable, Sendable {
    let binding: String
    let resource: String
    let issuer: String
    let tokenEndpoint: String
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

enum MCPOAuthSecurity {
    static let issuer = "https://mcp.sentry.dev"

    static func resource(_ server: MCPServer) throws -> String {
        guard server.transport == .streamableHTTP, server.environmentProfileID == nil,
              server.bearerTokenEnvironmentVariable.isEmpty,
              let url = URL(string: server.url), url.scheme == "https", url.host == "mcp.sentry.dev",
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: #"^/mcp(?:/[A-Za-z0-9_-]+){0,2}$"#, options: .regularExpression) != nil,
              !server.url.utf8.contains(where: { $0 < 32 || $0 == 127 }),
              url.absoluteString == issuer + url.path else { throw MCPOAuthError.unsupported }
        return url.absoluteString
    }

    static func binding(_ server: MCPServer) -> String {
        SHA256.hash(data: Data((server.id.uuidString + "\n" + server.url).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPOAuthError.callback }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func validate(_ metadata: MCPOAuthMetadata) throws {
        // A deliberate provider allowlist for this first release. No arbitrary metadata URLs,
        // redirects or endpoints can receive a code or token. Broader discovery comes later.
        guard metadata.issuer == issuer,
              metadata.authorization_endpoint == issuer + "/oauth/authorize",
              metadata.token_endpoint == issuer + "/oauth/token",
              metadata.registration_endpoint == issuer + "/oauth/register",
              metadata.code_challenge_methods_supported?.contains("S256") == true,
              metadata.response_types_supported?.contains("code") == true,
              metadata.token_endpoint_auth_methods_supported?.contains("none") == true else { throw MCPOAuthError.metadata }
    }

    static func callbackCode(_ url: URL, redirect: URL, state: String, issuer: String, requiresIssuer: Bool) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == redirect.scheme, parts.host == redirect.host, parts.port == redirect.port,
              parts.path == redirect.path, parts.user == nil, parts.password == nil, parts.fragment == nil else { throw MCPOAuthError.callback }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else { throw MCPOAuthError.callback }
        let responseIssuer = items.first(where: { $0.name == "iss" })?.value
        if requiresIssuer || responseIssuer != nil { guard responseIssuer == issuer else { throw MCPOAuthError.callback } }
        if items.contains(where: { $0.name == "error" }) { throw MCPOAuthError.cancelled }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4096, !code.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw MCPOAuthError.callback }
        return code
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
}

protocol MCPOAuthNetworking: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct MCPOAuthNetwork: MCPOAuthNetworking {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        // All requests, including metadata, are ephemeral and reject redirects.
        guard request.url?.scheme == "https", request.url?.host == "mcp.sentry.dev",
              request.url?.user == nil, request.url?.password == nil, request.url?.port == nil else { throw MCPOAuthError.metadata }
        let session = URLSession(configuration: .ephemeral, delegate: MCPOAuthNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw MCPOAuthError.network }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 131_072 else { throw MCPOAuthError.network }
                data.append(byte)
            }
            return (data, response.statusCode)
        } catch is CancellationError { throw MCPOAuthError.cancelled }
        catch let error as MCPOAuthError { throw error }
        catch { throw MCPOAuthError.network }
    }
}

private final class MCPOAuthNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct MCPOAuthClient: Sendable {
    var network: any MCPOAuthNetworking = MCPOAuthNetwork()

    func discover(_ server: MCPServer) async throws -> MCPOAuthDiscovery {
        struct Resource: Decodable { let resource: String; let authorization_servers: [String]; let scopes_supported: [String]? }
        let resource = try MCPOAuthSecurity.resource(server)
        let path = URL(string: resource)!.path
        let info: Resource = try await json(MCPOAuthSecurity.issuer + "/.well-known/oauth-protected-resource" + path)
        guard info.resource == resource, info.authorization_servers == [MCPOAuthSecurity.issuer] else { throw MCPOAuthError.metadata }
        let metadata: MCPOAuthMetadata = try await json(MCPOAuthSecurity.issuer + "/.well-known/oauth-authorization-server")
        try MCPOAuthSecurity.validate(metadata)
        let scopes = info.scopes_supported ?? []
        guard scopes.count <= 40, scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count < 128 && $0.utf8.allSatisfy { $0 > 32 && $0 < 127 && $0 != 34 && $0 != 92 } }) else { throw MCPOAuthError.metadata }
        return .init(resource: resource, metadata: metadata, scopes: scopes)
    }

    func register(_ discovery: MCPOAuthDiscovery, redirect: URL) async throws -> String {
        struct Registration: Decodable { let client_id: String; let token_endpoint_auth_method: String?; let redirect_uris: [String]? }
        try MCPOAuthSecurity.validate(discovery.metadata)
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil,
              redirect.user == nil, redirect.password == nil, redirect.query == nil, redirect.fragment == nil,
              redirect.path.hasPrefix("/oauth/callback/") else { throw MCPOAuthError.callback }
        let data = try JSONSerialization.data(withJSONObject: [
            "client_name": "MCP Manager (prototype local)", "application_type": "native",
            "redirect_uris": [redirect.absoluteString], "response_types": ["code"],
            "grant_types": ["authorization_code", "refresh_token"], "token_endpoint_auth_method": "none"
        ])
        let response: Registration = try await json(discovery.metadata.registration_endpoint!, body: data, contentType: "application/json", failure: .registration)
        guard !response.client_id.isEmpty, response.client_id.utf8.count <= 2048,
              response.token_endpoint_auth_method == "none",
              response.redirect_uris == [redirect.absoluteString] else { throw MCPOAuthError.registration }
        return response.client_id
    }

    func authorizationURL(_ discovery: MCPOAuthDiscovery, clientID: String, redirect: URL, state: String, verifier: String) throws -> URL {
        try MCPOAuthSecurity.validate(discovery.metadata)
        var components = URLComponents(string: discovery.metadata.authorization_endpoint)!
        components.queryItems = ["response_type": "code", "client_id": clientID, "redirect_uri": redirect.absoluteString,
            "state": state, "code_challenge": MCPOAuthSecurity.challenge(verifier), "code_challenge_method": "S256",
            "resource": discovery.resource, "scope": discovery.scopes.joined(separator: " ")].sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw MCPOAuthError.metadata }
        return url
    }

    func exchange(discovery: MCPOAuthDiscovery, server: MCPServer, clientID: String, redirect: URL, code: String, verifier: String) async throws -> MCPOAuthRecord {
        try MCPOAuthSecurity.validate(discovery.metadata)
        guard try MCPOAuthSecurity.resource(server) == discovery.resource else { throw MCPOAuthError.metadata }
        return try await token(endpoint: discovery.metadata.token_endpoint, values: ["grant_type": "authorization_code", "client_id": clientID,
            "code": code, "redirect_uri": redirect.absoluteString, "code_verifier": verifier, "resource": discovery.resource],
            binding: MCPOAuthSecurity.binding(server), resource: discovery.resource, clientID: clientID, oldRefresh: nil)
    }

    func refresh(_ record: MCPOAuthRecord, server: MCPServer) async throws -> MCPOAuthRecord {
        try validate(record, server: server)
        guard let refresh = record.refreshToken, !refresh.isEmpty else { throw MCPOAuthError.expired }
        return try await token(endpoint: record.tokenEndpoint, values: ["grant_type": "refresh_token", "client_id": record.clientID,
            "refresh_token": refresh, "resource": record.resource], binding: record.binding, resource: record.resource, clientID: record.clientID, oldRefresh: refresh)
    }

    func validate(_ record: MCPOAuthRecord, server: MCPServer) throws {
        guard record.binding == MCPOAuthSecurity.binding(server), record.resource == (try MCPOAuthSecurity.resource(server)),
              record.issuer == MCPOAuthSecurity.issuer, record.tokenEndpoint == MCPOAuthSecurity.issuer + "/oauth/token" else { throw MCPOAuthError.metadata }
        try MCPLocalCredentialResolver.validateHeaders(["Authorization": "Bearer \(record.accessToken)"], url: server.url)
    }

    private func token(endpoint: String, values: [String: String], binding: String, resource: String, clientID: String, oldRefresh: String?) async throws -> MCPOAuthRecord {
        struct Token: Decodable { let access_token: String; let token_type: String; let refresh_token: String?; let expires_in: Double? }
        let response: Token = try await json(endpoint, body: MCPOAuthSecurity.form(values), contentType: "application/x-www-form-urlencoded", failure: .token)
        guard response.token_type.lowercased() == "bearer", !response.access_token.isEmpty,
              response.access_token.utf8.count <= 16384, let lifetime = response.expires_in,
              lifetime.isFinite, lifetime > 0, lifetime <= 315_360_000 else { throw MCPOAuthError.token }
        try MCPLocalCredentialResolver.validateHeaders(["Authorization": "Bearer \(response.access_token)"], url: resource)
        if let refresh = response.refresh_token { guard !refresh.isEmpty, refresh.utf8.count <= 16384 else { throw MCPOAuthError.token } }
        return .init(binding: binding, resource: resource, issuer: MCPOAuthSecurity.issuer, tokenEndpoint: endpoint,
            clientID: clientID, accessToken: response.access_token, refreshToken: response.refresh_token ?? oldRefresh, expiresAt: Date().addingTimeInterval(lifetime))
    }

    private func json<T: Decodable>(_ address: String, body: Data? = nil, contentType: String? = nil, failure: MCPOAuthError = .metadata) async throws -> T {
        guard let url = URL(string: address) else { throw failure }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, code) = try await network.send(request)
        guard (200...299).contains(code), data.count <= 131_072 else { throw failure }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw failure }
    }
}
