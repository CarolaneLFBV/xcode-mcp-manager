import Combine
import Foundation

@MainActor
final class MCPServerStore: ObservableObject {
    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var persistenceError: String?

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    func server(id: UUID?) -> MCPServer? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    func save(_ server: MCPServer) {
        var updated = server
        updated.updatedAt = .now

        if let index = servers.firstIndex(where: { $0.id == updated.id }) {
            servers[index] = updated
        } else {
            servers.append(updated)
        }
        sortAndPersist()
    }

    @discardableResult
    func importServers(_ candidates: [MCPServer]) -> [UUID] {
        var knownSignatures = Set(servers.map(\.discoverySignature))
        var knownNames = Set(servers.map { $0.name.lowercased() })
        var importedIDs: [UUID] = []

        for candidate in candidates where !knownSignatures.contains(candidate.discoverySignature) {
            var imported = candidate
            imported.id = UUID()
            imported.name = uniqueName(candidate.name, knownNames: knownNames)
            imported.createdAt = .now
            imported.updatedAt = .now
            servers.append(imported)
            knownSignatures.insert(imported.discoverySignature)
            knownNames.insert(imported.name.lowercased())
            importedIDs.append(imported.id)
        }

        if !importedIDs.isEmpty { sortAndPersist() }
        return importedIDs
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].enabled = enabled
        servers[index].updatedAt = .now
        persist()
    }

    func delete(id: UUID) {
        servers.removeAll { $0.id == id }
        persist()
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            servers = try decoder.decode([MCPServer].self, from: Data(contentsOf: fileURL))
            servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            persistenceError = String(localized: "Impossible de charger le catalogue : \(error.localizedDescription)")
        }
    }

    private func sortAndPersist() {
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    private func uniqueName(_ requestedName: String, knownNames: Set<String>) -> String {
        let base = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Serveur MCP"
            : requestedName
        guard knownNames.contains(base.lowercased()) else { return base }
        var suffix = 2
        while knownNames.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(servers).write(to: fileURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = String(localized: "Impossible d’enregistrer le catalogue : \(error.localizedDescription)")
        }
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MCPManager", directoryHint: .isDirectory)
            .appending(path: "servers.json")
    }
}
