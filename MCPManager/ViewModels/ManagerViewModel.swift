import Foundation
import Combine

/// Main-window state and application actions, isolated from SwiftUI rendering.
/// Inventory refreshes use an identity to discard late results. Selecting an
/// inventory row never writes its source configuration.
@MainActor
final class ManagerViewModel: ObservableObject {
    let store: MCPServerStore
    let supervisor: MCPProcessSupervisor
    private let defaults: UserDefaults

    init(store: MCPServerStore, supervisor: MCPProcessSupervisor, defaults: UserDefaults = .standard) {
        self.store = store
        self.supervisor = supervisor
        self.defaults = defaults
    }

    @Published var selection: UUID?
    @Published var editingServer: MCPServer?
    @Published var serverPendingDeletion: MCPServer?
    @Published var installingInXcode: MCPServer?
    @Published var preferredXcodeTarget: XcodeInstallationTarget.Kind?
    @Published var xcodeTargets: [UUID: [XcodeInstallationTarget]] = [:]
    @Published var inventory = XcodeInventory()
    @Published var isLoadingInventory = true
    @Published var receipts: [XcodeManagementReceipt] = []
    @Published var showingHistory = false
    @Published var pendingUninstall: XcodeInventoryEntry?
    @Published var isManaging = false
    @Published var managementMessage: String?
    @Published var managementError: String?
    @Published var refreshID = UUID()
    @Published var localScanResult: LocalMCPScanResult?
    @Published var showingLocalDiscovery = false
    @Published var isScanningLocal = false
    @Published var sidebarMode: MCPSidebarMode = .xcode
    @Published var catalogFilters = MCPCatalogFilters()
    @Published var environmentServer: MCPServer?
    @Published var environmentMessages: [UUID: String] = [:]
    @Published var checkingEnvironmentID: UUID?
    @Published var showingXcodeWelcome = false
    var didSeeXcodeWelcome: Bool {
        get { defaults.bool(forKey: "didSeeXcodeWelcome-v1") }
        set { defaults.set(newValue, forKey: "didSeeXcodeWelcome-v1") }
    }
    var didRunInitialLocalDiscovery: Bool {
        get { defaults.bool(forKey: "didRunInitialLocalMCPDiscovery-v1") }
        set { defaults.set(newValue, forKey: "didRunInitialLocalMCPDiscovery-v1") }
    }
    var projectPathsData: Data {
        get { defaults.data(forKey: "xcodeProjectPaths-v1") ?? Data() }
        set { defaults.set(newValue, forKey: "xcodeProjectPaths-v1") }
    }

    var selectedServer: MCPServer? {
        sidebarMode == .catalog ? store.server(id: selection) : inventory.entries.first { $0.id == selection }?.server
    }

    /// Save a personal copy; imported inventory identities must never be reused.
    func saveEditorDraft(_ saved: MCPServer) {
        var copy = saved
        if store.server(id: copy.id) == nil && inventory.entries.contains(where: { $0.id == copy.id }) {
            copy.id = UUID()
        }
        store.save(copy)
        switchSidebarMode(.catalog)
        selection = copy.id
    }

    func saveEnvironment(_ saved: MCPServer, replacing original: MCPServer) {
        var copy = saved
        if store.server(id: copy.id) == nil { copy.id = UUID() }
        supervisor.stop(original)
        store.save(copy)
        environmentMessages[copy.id] = nil
        switchSidebarMode(.catalog)
        selection = copy.id
        managementMessage = String(localized: "Variables enregistrées au catalogue. Les configurations Xcode n’ont pas été modifiées ; utilisez l’installation guidée pour les appliquer.")
    }

    func saveInstallationDraft(_ saved: MCPServer, replacing original: MCPServer) {
        supervisor.stop(original)
        var copy = saved
        if store.server(id: copy.id) == nil { copy.id = UUID() }
        store.save(copy)
    }

    func importServers(_ candidates: [MCPServer]) {
        if let firstID = store.importServers(candidates).first {
            switchSidebarMode(.catalog)
            selection = firstID
        }
        showingLocalDiscovery = false
    }

    func deleteCatalogServer(_ server: MCPServer) {
        supervisor.stop(server)
        store.delete(id: server.id)
        if selection == server.id { selection = nil }
        serverPendingDeletion = nil
    }

    func runInitialDiscovery() async {
        guard !didRunInitialLocalDiscovery, !showingXcodeWelcome else { return }
        didRunInitialLocalDiscovery = true
        await scanLocalServers(alwaysPresent: false)
    }

    func switchSidebarMode(_ mode: MCPSidebarMode) {
        selection = nil
        sidebarMode = mode
    }

    func checkEnvironment(_ server: MCPServer) {
        guard checkingEnvironmentID == nil else { return }
        checkingEnvironmentID = server.id
        environmentMessages[server.id] = nil
        Task {
            do {
                environmentMessages[server.id] = try await Task.detached {
                    try MCPEnvironmentService().checkTransmission(server)
                }.value
            } catch {
                environmentMessages[server.id] = (error as? MCPEnvironmentError)?.localizedDescription
                    ?? String(localized: "Transmission non vérifiée. Contrôlez le profil et l’accès au Trousseau.")
            }
            checkingEnvironmentID = nil
        }
    }

    func refreshXcodeTargets() {
        isLoadingInventory = true
        let id = UUID()
        refreshID = id
        let servers = store.servers
        let projectDirectories = ((try? JSONDecoder().decode([String].self, from: projectPathsData)) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let manager = XcodeMCPManagement()
                var inventory = manager.inventory()
                let projects = XcodeProjectDiscovery().inventory(additionalProjectDirectories: projectDirectories)
                inventory.entries += projects.entries
                inventory.errors += projects.errors
                let installer = XcodeMCPInstaller()
                let targets = Dictionary(uniqueKeysWithValues: servers.map {
                    ($0.id, installer.detectTargets(for: $0) + installer.projectTargets(for: $0, in: projects))
                })
                do { return (inventory, targets, try manager.history(), Optional<String>.none) }
                catch { return (inventory, targets, [], Optional(error.localizedDescription)) }
            }.value
            guard refreshID == id else { return }
            isLoadingInventory = false
            inventory = result.0
            xcodeTargets = result.1
            receipts = result.2
            if let error = result.3 { managementError = String(localized: "Historique : \(error)") }
        }
    }

    func addProjectDirectories(_ urls: [URL]) {
        let previous = (try? JSONDecoder().decode([String].self, from: projectPathsData)) ?? []
        let paths = Set(previous + urls.map { $0.standardizedFileURL.path }).sorted()
        if let data = try? JSONEncoder().encode(paths) { projectPathsData = data }
        switchSidebarMode(.xcode)
        refreshXcodeTargets()
    }

    func manage(_ action: XcodeManagementAction, server: MCPServer, target: XcodeInstallationTarget) {
        guard !target.isProjectConfiguration, !isManaging, let revision = target.revision, let name = target.configuredServerName else { return }
        isManaging = true
        managementError = nil
        managementMessage = nil
        let binding = XcodeServerBinding(kind: target.kind, name: name)
        Task {
            do {
                _ = try await Task.detached { try XcodeMCPManagement().perform(action, binding: binding, revision: revision) }.value
                managementMessage = String(localized: "\(action.title) : \(name) · \(target.kind.shortTitle). Ouvrez une nouvelle conversation Xcode pour prendre en compte la modification.")
            } catch { managementError = error.localizedDescription }
            isManaging = false
            refreshXcodeTargets()
        }
    }

    func restore(_ receipt: XcodeManagementReceipt) {
        guard !isManaging else { return }
        isManaging = true
        managementError = nil
        Task {
            do {
                try await Task.detached { try XcodeMCPManagement().restore(receipt) }.value
                managementMessage = String(localized: "Configuration de \(receipt.binding.name) restaurée pour \(receipt.binding.kind.shortTitle). Ouvrez une nouvelle conversation Xcode.")
            } catch { managementError = error.localizedDescription }
            isManaging = false
            refreshXcodeTargets()
        }
    }

    @MainActor
    func scanLocalServers(alwaysPresent: Bool) async {
        guard !isScanningLocal else { return }
        isScanningLocal = true
        let result = await LocalMCPDiscoveryService().scan()
        localScanResult = result
        isScanningLocal = false
        if alwaysPresent || !result.discoveries.isEmpty || !result.unreadableLocations.isEmpty {
            showingLocalDiscovery = true
        }
    }
}
