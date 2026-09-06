import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

@MainActor
enum MCPOAuthScenarios {
    final class Vault: MCPOAuthVault, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: Data] = [:]
        private var rejectWrites = false
        func failWrites(_ value: Bool) { lock.withLock { rejectWrites = value } }
        func read(_ account: String) throws -> Data { try lock.withLock { guard let value = records[account] else { throw MCPOAuthError.storage }; return value } }
        func write(_ data: Data, account: String) throws { try lock.withLock { if rejectWrites { throw MCPOAuthError.storage }; records[account] = data } }
        func remove(_ account: String) throws { _ = lock.withLock { records.removeValue(forKey: account) } }
    }

    actor Network: MCPOAuthNetworking {
        var requests: [URLRequest] = []
        var mode = "normal"
        func setMode(_ value: String) { mode = value }
        func snapshot() -> [URLRequest] { requests }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            let path = request.url!.path
            var body: [String: Any]
            if path.contains("oauth-protected-resource") {
                body = ["resource": "https://mcp.sentry.dev/mcp", "authorization_servers": ["https://mcp.sentry.dev"], "scopes_supported": ["org:read"]]
            } else if path.contains("oauth-authorization-server") {
                body = ["issuer": mode == "badIssuer" ? "https://evil.example" : "https://mcp.sentry.dev",
                    "authorization_endpoint": "https://mcp.sentry.dev/oauth/authorize", "token_endpoint": "https://mcp.sentry.dev/oauth/token",
                    "registration_endpoint": "https://mcp.sentry.dev/oauth/register", "code_challenge_methods_supported": [mode == "noPKCE" ? "plain" : "S256"],
                    "response_types_supported": ["code"], "token_endpoint_auth_methods_supported": ["none"], "authorization_response_iss_parameter_supported": true]
            } else if path == "/oauth/register" {
                let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                guard input["application_type"] as? String == "native", input["token_endpoint_auth_method"] as? String == "none" else { throw MCPOAuthError.registration }
                body = ["client_id": "fixture-client", "token_endpoint_auth_method": "none", "redirect_uris": input["redirect_uris"]!]
            } else {
                body = ["access_token": mode == "badToken" ? "unsafe\r\nheader" : "synthetic-oauth-token", "token_type": "Bearer", "expires_in": 3600]
                let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                guard form.contains("resource=https%3A%2F%2Fmcp.sentry.dev%2Fmcp"), !request.url!.absoluteString.contains("synthetic") else { throw MCPOAuthError.token }
                if !form.contains("grant_type=refresh_token") { body["refresh_token"] = "synthetic-refresh-token" }
                try await Task.sleep(for: .milliseconds(20))
            }
            return (try JSONSerialization.data(withJSONObject: body), 200)
        }
    }

    static func run(includeLoopback: Bool = true) async throws -> [String] {
        let check = XcodeManagementScenarios.check
        let server = MCPServer(name: "Sentry fixture", transport: .streamableHTTP, url: "https://mcp.sentry.dev/mcp")
        try check(MCPOAuthSecurity.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE RFC 7636 reference vector")
        let verifier = try MCPOAuthSecurity.random()
        try check(verifier.count == 43 && verifier != MCPOAuthSecurity.random(), "Independent secure verifier")
        for address in ["http://mcp.sentry.dev/mcp", "https://mcp.sentry.dev.evil.example/mcp", "https://x@mcp.sentry.dev/mcp", "https://mcp.sentry.dev/mcp?token=secret", "https://mcp.sentry.dev/mcp#fragment", "https://127.0.0.1/mcp", "https://mcp.sentry.dev/mcp/../oauth/token"] {
            var invalid = server; invalid.url = address
            do { _ = try MCPOAuthSecurity.resource(invalid); throw XcodeManagementScenarios.Failure(description: "Unsafe OAuth resource") }
            catch MCPOAuthError.unsupported { }
        }
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback/fixture")!
        func url(_ query: String) -> URL { URL(string: redirect.absoluteString + "?" + query)! }
        let issuerQuery = "&iss=https%3A%2F%2Fmcp.sentry.dev"
        try check(try MCPOAuthSecurity.callbackCode(url("state=state&code=fixture" + issuerQuery), redirect: redirect, state: "state", issuer: MCPOAuthSecurity.issuer, requiresIssuer: true) == "fixture", "Exact callback accepted")
        for query in ["state=wrong&code=x" + issuerQuery, "state=state&state=state&code=x" + issuerQuery, "state=state&code=x", "state=state&code=x&iss=https%3A%2F%2Fevil.example"] {
            do { _ = try MCPOAuthSecurity.callbackCode(url(query), redirect: redirect, state: "state", issuer: MCPOAuthSecurity.issuer, requiresIssuer: true); throw XcodeManagementScenarios.Failure(description: "Forged callback accepted") }
            catch MCPOAuthError.callback { }
        }
        var passed = ["OAuth : PKCE S256, state, issuer, retours falsifiés et URL hors périmètre"]
        let network = Network(); let client = MCPOAuthClient(network: network)
        for mode in ["badIssuer", "noPKCE"] {
            await network.setMode(mode)
            do { _ = try await client.discover(server); throw XcodeManagementScenarios.Failure(description: "Unsafe metadata accepted") }
            catch MCPOAuthError.metadata { }
        }
        await network.setMode("normal")
        let discovery = try await client.discover(server)
        let id = try await client.register(discovery, redirect: redirect)
        let authURL = try client.authorizationURL(discovery, clientID: id, redirect: redirect, state: "state", verifier: verifier)
        let params = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!
        try check(params.first { $0.name == "code_challenge_method" }?.value == "S256" && !authURL.absoluteString.contains(verifier), "Verifier not sent through browser")
        try check(params.first { $0.name == "resource" }?.value == server.url, "Resource bound in authorization")
        let record = try await client.exchange(discovery: discovery, server: server, clientID: id, redirect: redirect, code: "code", verifier: verifier)
        try check(record.accessToken == "synthetic-oauth-token", "Authorization exchange works")
        await network.setMode("badToken")
        do { _ = try await client.exchange(discovery: discovery, server: server, clientID: id, redirect: redirect, code: "code", verifier: verifier); throw XcodeManagementScenarios.Failure(description: "Header injection token accepted") }
        catch MCPLocalCredentialError.unsafeHTTP { }
        await network.setMode("normal")
        passed.append("OAuth simulé : découverte, client natif, code et jetons liés à la ressource")

        let suite = "MCPManager-oauth-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = Vault()
        let controller = MCPOAuthController(vault: vault, defaults: defaults, client: client)
        let expired = MCPOAuthRecord(binding: record.binding, resource: record.resource, issuer: record.issuer, tokenEndpoint: record.tokenEndpoint,
            clientID: record.clientID, accessToken: record.accessToken, refreshToken: record.refreshToken, expiresAt: .distantPast)
        try controller.save(expired, server: server)
        let before = await network.snapshot().count
        async let first = controller.credentials(server)
        async let second = controller.credentials(server)
        let (a,b) = try await (first, second)
        try check(a.headers == b.headers && a.headers["Authorization"] == "Bearer synthetic-oauth-token", "Refreshed token used")
        let after = await network.snapshot().count
        try check(after == before + 1, "Concurrent refresh is deduplicated")
        let representation = String(describing: defaults.dictionaryRepresentation())
        try check(!representation.contains("synthetic-oauth-token") && !representation.contains("synthetic-refresh-token"), "Tokens absent from preference files")
        try check(!String(decoding: JSONEncoder().encode(server), as: UTF8.self).contains(record.accessToken), "Token absent from catalogue")
        var changed = server; changed.url = "https://mcp.sentry.dev/mcp/another"
        do { try client.validate(record, server: changed); throw XcodeManagementScenarios.Failure(description: "Token reused for different resource") }
        catch MCPOAuthError.metadata { }
        controller.disconnect(server)
        try check(!controller.hasStored(server), "Local disconnect clears marker")
        do { _ = try await controller.credentials(server); throw XcodeManagementScenarios.Failure(description: "Forgotten authorization reused") }
        catch MCPOAuthError.expired { }
        try controller.save(expired, server: server)
        vault.failWrites(true)
        let failedFirst = Task { try await controller.credentials(server) }
        let failedSecond = Task { try await controller.credentials(server) }
        for task in [failedFirst, failedSecond] {
            do { _ = try await task.value; throw XcodeManagementScenarios.Failure(description: "Refreshed credential used after failed persistence") }
            catch MCPOAuthError.storage { }
        }
        vault.failWrites(false)
        try controller.save(expired, server: server)
        let pending = Task { try await controller.credentials(server) }
        try await Task.sleep(for: .milliseconds(5))
        controller.disconnect(server)
        do { _ = try await pending.value; throw XcodeManagementScenarios.Failure(description: "Refresh resurrected forgotten session") }
        catch is CancellationError { }
        catch MCPOAuthError.cancelled { }
        try check(!controller.hasStored(server), "Refresh cannot resurrect disconnected session")
        passed.append("OAuth : coffre simulé, absence de secrets dans le catalogue, renouvellement unique et oubli local")

        if includeLoopback {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let receiver = try MCPOAuthCallback(state: "synthetic-state", issuer: MCPOAuthSecurity.issuer, requiresIssuer: true)
            let redirect = try await receiver.start()
            defer { receiver.cancel() }
            var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "state", value: "wrong"), .init(name: "code", value: "synthetic-code"), .init(name: "iss", value: MCPOAuthSecurity.issuer)]
            let (_, rejected) = try await session.data(from: parts.url!)
            try check((rejected as? HTTPURLResponse)?.statusCode == 400, "Loopback rejects wrong state without ending attempt")
            parts.queryItems![0] = .init(name: "state", value: "synthetic-state")
            let (body, accepted) = try await session.data(from: parts.url!)
            try check((accepted as? HTTPURLResponse)?.statusCode == 200 && !String(decoding: body, as: UTF8.self).contains("synthetic-code"), "Loopback page never reflects callback secrets")
            let callbackCode = try await receiver.waitForCode()
            try check(callbackCode == "synthetic-code", "Loopback delivers authorization code")
            let cancelled = try MCPOAuthCallback(state: "state", issuer: MCPOAuthSecurity.issuer, requiresIssuer: false)
            _ = try await cancelled.start(); cancelled.cancel()
            do { _ = try await cancelled.waitForCode(); throw XcodeManagementScenarios.Failure(description: "Cancelled listener completed") }
            catch MCPOAuthError.cancelled { }
            passed.append("OAuth : retour HTTP réel sur loopback, rejet d’un faux retour, page sans secret et annulation")
        }
        return passed
    }
}
