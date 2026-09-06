import Foundation
import Combine

/// Owns an in-memory secret draft. Loading and editing never update Xcode.
/// Injected operations allow tests without Keychain access. Only save persists;
/// cancelling discards the draft, not an already-started persistence operation.
@MainActor
final class EnvironmentEditorViewModel: ObservableObject {
    let server: MCPServer
    @Published var drafts: [MCPEnvironmentDraft] = []
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    @Published private(set) var didLoad = false
    private let loadDrafts: (MCPServer) throws -> [MCPEnvironmentDraft]
    private let persist: @Sendable (MCPServer, [MCPEnvironmentDraft], String) async throws -> MCPServer

    init(server: MCPServer,
         loadDrafts: @escaping (MCPServer) throws -> [MCPEnvironmentDraft] = { try MCPEnvironmentService().drafts(for: $0) },
         persist: @escaping @Sendable (MCPServer, [MCPEnvironmentDraft], String) async throws -> MCPServer = { server, drafts, scope in
             try await Task.detached { try MCPEnvironmentService().save(server: server, drafts: drafts, scope: scope) }.value
         }) {
        self.server = server
        self.loadDrafts = loadDrafts
        self.persist = persist
    }

    var isHTTP: Bool { server.transport == .streamableHTTP }
    var isProject: Bool { server.xcodeBinding?.projectDirectoryURL != nil }
    var scope: String {
        if let project = server.xcodeBinding?.projectDirectoryURL {
            return String(localized: "Test local du projet · \(project.path)")
        }
        return String(localized: "Catalogue local · \(server.name)")
    }

    func loadIfNeeded() {
        guard !didLoad, !isSaving else { return }
        do {
            drafts = try loadDrafts(server)
            if isHTTP, drafts.isEmpty { drafts = [MCPEnvironmentDraft(name: "MCP_API_TOKEN")] }
            didLoad = true
            error = nil
        } catch {
            self.error = String(localized: "Le profil précédent est illisible. Rétablissez-le avant de modifier les variables.")
        }
    }

    func save() async -> MCPServer? {
        guard didLoad, !isSaving else { return nil }
        isSaving = true
        error = nil
        defer { isSaving = false }
        var prepared = server
        if isHTTP, let draft = drafts.first {
            prepared.bearerTokenEnvironmentVariable = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let saved = try await persist(prepared, drafts, scope)
            drafts.removeAll()
            return saved
        } catch {
            self.error = (error as? MCPEnvironmentError)?.localizedDescription
                ?? String(localized: "Impossible d’enregistrer le profil. Aucun secret n’a été affiché.")
            return nil
        }
    }

    /// Called when the sheet closes. Does not erase saved profiles or revoke credentials.
    func discard() {
        drafts.removeAll()
    }
}
