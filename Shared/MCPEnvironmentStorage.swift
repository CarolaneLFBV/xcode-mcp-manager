// No UI dependency: the launcher reads the same scoped profiles as the app.
import Foundation
import Security
import Darwin

protocol MCPSecretStorage: Sendable {
    func read(_ id: UUID) throws -> Data
    func write(_ data: Data, id: UUID) throws
    func remove(_ id: UUID) throws
}

struct MCPKeychainStorage: MCPSecretStorage {
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.example.mcpmanager.environment.v1",
         kSecAttrAccount as String: id.uuidString]
    }

    func read(_ id: UUID) throws -> Data {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw MCPEnvironmentError.keychain(status) }
        return data
    }

    func write(_ data: Data, id: UUID) throws {
        var item = query(id)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MCP Manager — variables du serveur"
        // Use the macOS login Keychain, not the entitlement-based Data Protection
        // Keychain. Its default ACL can prompt separately for the app and the CLI.
        // kSecAttrAccessible is not valid for this file-based Keychain.
        // Profiles are immutable: never replace a live credential in place.
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw MCPEnvironmentError.keychain(status) }
    }

    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MCPEnvironmentError.keychain(status) }
    }
}

struct MCPEnvironmentStorage: Sendable {
    struct Envelope: Codable { let fingerprint: String; let values: [String: String] }
    let directory: URL
    let vault: any MCPSecretStorage

    init(directory: URL? = nil, vault: any MCPSecretStorage = MCPKeychainStorage()) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MCPManager/EnvironmentProfiles")
        self.vault = vault
    }

    func profile(_ id: UUID) throws -> MCPEnvironmentProfile {
        let url = directory.appending(path: "\(id.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw MCPEnvironmentError.invalid(String(localized: "Profil de variables non sûr ou illisible.", bundle: MCPLocalization.bundle))
        }
        let profile = try JSONDecoder().decode(MCPEnvironmentProfile.self, from: Data(contentsOf: url))
        guard profile.id == id else { throw MCPEnvironmentError.invalid(String(localized: "Identité de profil incorrecte.", bundle: MCPLocalization.bundle)) }
        try MCPEnvironmentRuntime.validate(profile.variables)
        return profile
    }

    func secrets(_ profile: MCPEnvironmentProfile) throws -> [String: String] {
        guard profile.variables.contains(where: \.isSecret) else { return [:] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: vault.read(profile.id))
        guard envelope.fingerprint == profile.fingerprint else {
            throw MCPEnvironmentError.invalid(String(localized: "Le profil a changé hors de l’app. Accès aux secrets refusé ; enregistrez à nouveau les variables.", bundle: MCPLocalization.bundle))
        }
        return envelope.values
    }

    func save(_ profile: MCPEnvironmentProfile, secrets: [String: String]) throws {
        _ = try MCPEnvironmentRuntime.environment(profile: profile, secrets: secrets, inherited: [:])
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw MCPEnvironmentError.invalid(String(localized: "Le dossier des profils doit être privé et appartenir à votre compte.", bundle: MCPLocalization.bundle))
        }
        let destination = directory.appending(path: "\(profile.id.uuidString).json")
        guard !manager.fileExists(atPath: destination.path) else { throw MCPEnvironmentError.invalid(String(localized: "Ce profil existe déjà.", bundle: MCPLocalization.bundle)) }
        let secretValues = secrets.filter { key, _ in profile.variables.contains { $0.name == key && $0.isSecret } }
        let hasSecrets = profile.variables.contains(where: \.isSecret)
        if hasSecrets {
            try vault.write(JSONEncoder().encode(Envelope(fingerprint: profile.fingerprint, values: secretValues)), id: profile.id)
        }
        do {
            let data = try JSONEncoder().encode(profile)
            guard manager.createFile(atPath: destination.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw MCPEnvironmentError.invalid(String(localized: "Impossible d’enregistrer les références des variables.", bundle: MCPLocalization.bundle))
            }
        } catch {
            if hasSecrets { try? vault.remove(profile.id) }
            throw error
        }
    }

    func environment(_ profile: MCPEnvironmentProfile, inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        try MCPEnvironmentRuntime.environment(profile: profile, secrets: secrets(profile), inherited: inherited)
    }
}
