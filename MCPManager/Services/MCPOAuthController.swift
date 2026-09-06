import Foundation
import Security
import AppKit
import Combine

protocol MCPOAuthVault: Sendable {
    func read(_ account: String) throws -> Data
    func write(_ data: Data, account: String) throws
    func remove(_ account: String) throws
}

struct MCPOAuthKeychain: MCPOAuthVault {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.example.mcpmanager.oauth.v1", kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> Data {
        var query = query(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { throw MCPOAuthError.storage }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account); item[kSecValueData as String] = data; item[kSecAttrLabel as String] = "MCP Manager - connexion OAuth"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MCPOAuthError.storage }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MCPOAuthError.storage }
    }
}

@MainActor
final class MCPOAuthController: ObservableObject {
    static let shared = MCPOAuthController()
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var activeBinding: String?
    @Published private(set) var revision = 0
    private let vault: any MCPOAuthVault
    private let defaults: UserDefaults
    private let client: MCPOAuthClient
    private var receiver: MCPOAuthCallback?
    private var attempt: Task<Void, Never>?
    private var generations: [String: Int] = [:]
    private var refreshes: [String: Task<MCPOAuthRecord, Error>] = [:]

    init(vault: any MCPOAuthVault = MCPOAuthKeychain(), defaults: UserDefaults = .standard, client: MCPOAuthClient = MCPOAuthClient()) {
        self.vault = vault; self.defaults = defaults; self.client = client
    }

    func hasStored(_ server: MCPServer) -> Bool { defaults.bool(forKey: "oauth-v1-" + MCPOAuthSecurity.binding(server)) }
    func message(_ server: MCPServer) -> String? { messages[MCPOAuthSecurity.binding(server)] }
    func discover(_ server: MCPServer) async throws -> MCPOAuthDiscovery { try await client.discover(server) }

    func connect(_ server: MCPServer, discovery: MCPOAuthDiscovery, onAuthorized: @escaping @MainActor () -> Void) {
        guard activeBinding == nil else { return }
        let key = MCPOAuthSecurity.binding(server)
        activeBinding = key
        generations[key, default: 0] += 1
        refreshes.removeValue(forKey: key)?.cancel()
        let generation = generations[key, default: 0]
        messages[key] = String(localized: "Préparation du retour sécurisé…")
        attempt = Task { [weak self] in
            guard let self else { return }
            defer { self.receiver?.cancel(); self.receiver = nil; self.activeBinding = nil; self.attempt = nil }
            do {
                guard try MCPOAuthSecurity.resource(server) == discovery.resource else { throw MCPOAuthError.metadata }
                // Check our own Keychain before asking the user to authorize a remote service.
                let probe = "probe-" + UUID().uuidString
                let fixture = Data(UUID().uuidString.utf8)
                try vault.write(fixture, account: probe)
                do {
                    guard try vault.read(probe) == fixture else { throw MCPOAuthError.storage }
                    try vault.remove(probe)
                } catch { try? vault.remove(probe); throw MCPOAuthError.storage }
                try Task.checkCancellation()
                let state = try MCPOAuthSecurity.random(); let verifier = try MCPOAuthSecurity.random()
                let callback = try MCPOAuthCallback(state: state, issuer: discovery.metadata.issuer,
                    requiresIssuer: discovery.metadata.authorization_response_iss_parameter_supported == true)
                self.receiver = callback
                let redirect = try await callback.start()
                let clientID = try await client.register(discovery, redirect: redirect)
                try Task.checkCancellation()
                let url = try client.authorizationURL(discovery, clientID: clientID, redirect: redirect, state: state, verifier: verifier)
                messages[key] = String(localized: "Connexion dans le navigateur… Acceptez les permissions sur le site de Sentry.")
                guard NSWorkspace.shared.open(url) else { throw MCPOAuthError.network }
                let code = try await callback.waitForCode()
                try Task.checkCancellation()
                NSApp?.activate(ignoringOtherApps: true)
                messages[key] = String(localized: "Validation de l’autorisation…")
                let record = try await client.exchange(discovery: discovery, server: server, clientID: clientID, redirect: redirect, code: code, verifier: verifier)
                try Task.checkCancellation()
                guard generations[key] == generation else { throw MCPOAuthError.cancelled }
                try save(record, server: server)
                messages[key] = String(localized: "Autorisation enregistrée dans le Trousseau. Vérification du MCP…")
                onAuthorized()
            } catch {
                messages[key] = Self.safeMessage(error)
            }
        }
    }

    func cancel() { attempt?.cancel(); receiver?.cancel() }

    func disconnect(_ server: MCPServer) {
        let key = MCPOAuthSecurity.binding(server)
        if activeBinding == key { cancel() }
        generations[key, default: 0] += 1; refreshes.removeValue(forKey: key)?.cancel()
        do {
            try vault.remove(key)
            defaults.removeObject(forKey: "oauth-v1-" + key); revision += 1
            messages[key] = String(localized: "Connexion oubliée sur ce Mac. Pour révoquer l’autorisation distante, utilisez les réglages du fournisseur.")
        } catch { messages[key] = Self.safeMessage(error) }
    }

    func credentials(_ server: MCPServer) async throws -> MCPLocalCredentials {
        let key = MCPOAuthSecurity.binding(server)
        guard hasStored(server), activeBinding != key else { throw MCPOAuthError.expired }
        let generation = generations[key, default: 0]
        var record: MCPOAuthRecord
        do { record = try JSONDecoder().decode(MCPOAuthRecord.self, from: vault.read(key)) }
        catch { throw MCPOAuthError.storage }
        try client.validate(record, server: server)
        if record.expiresAt.timeIntervalSinceNow < 60 {
            if let pending = refreshes[key] { record = try await pending.value }
            else {
                let current = record
                let pending = Task {
                    let refreshed = try await client.refresh(current, server: server)
                    try Task.checkCancellation()
                    guard generations[key, default: 0] == generation, hasStored(server) else { throw MCPOAuthError.cancelled }
                    try save(refreshed, server: server)
                    return refreshed
                }
                refreshes[key] = pending
                defer { refreshes.removeValue(forKey: key) }
                record = try await pending.value
            }
        }
        guard generations[key, default: 0] == generation, hasStored(server) else { throw MCPOAuthError.cancelled }
        return .init(headers: ["Authorization": "Bearer \(record.accessToken)"], oauth: true)
    }

    func save(_ record: MCPOAuthRecord, server: MCPServer) throws {
        try client.validate(record, server: server)
        try vault.write(JSONEncoder().encode(record), account: record.binding)
        defaults.set(true, forKey: "oauth-v1-" + record.binding); revision += 1
    }

    static func safeMessage(_ error: Error) -> String {
        if let error = error as? MCPOAuthError { return error.localizedDescription }
        if error is CancellationError { return MCPOAuthError.cancelled.localizedDescription }
        return String(localized: "La connexion OAuth n’a pas abouti. Les détails sont masqués pour protéger les identifiants.")
    }
}
