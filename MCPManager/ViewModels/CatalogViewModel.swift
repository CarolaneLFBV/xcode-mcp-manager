import Foundation
import Combine

/// Loads bundled recommendations without contacting providers or changing user data.
@MainActor
final class CatalogViewModel: ObservableObject {
    @Published private(set) var catalog: MCPCatalog?
    @Published private(set) var failure: String?
    private let loadCatalog: () throws -> MCPCatalog

    init(loadCatalog: @escaping () throws -> MCPCatalog = { try MCPCatalog.load() }) {
        self.loadCatalog = loadCatalog
    }

    func loadIfNeeded() {
        guard catalog == nil else { return }
        do {
            catalog = try loadCatalog()
            failure = nil
        } catch {
            // Do not surface arbitrary loader details; a future remote loader may contain secrets.
            failure = String(localized: "Les recommandations n’ont pas pu être lues. L’onglet Mes configurations reste disponible.")
        }
    }
}
