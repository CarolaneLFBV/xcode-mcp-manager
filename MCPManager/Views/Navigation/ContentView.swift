import AppKit
import SwiftUI

/// Renders the main window. Application operations belong to ManagerViewModel;
/// the native folder picker stays here because it is a presentation concern.
struct ContentView: View {
    @ObservedObject var store: MCPServerStore
    @ObservedObject var supervisor: MCPProcessSupervisor
    @StateObject private var model: ManagerViewModel

    init(store: MCPServerStore, supervisor: MCPProcessSupervisor) {
        self.store = store
        self.supervisor = supervisor
        _model = StateObject(wrappedValue: ManagerViewModel(store: store, supervisor: supervisor))
    }

    var body: some View {
        NavigationSplitView {
            MCPServerSidebar(
                selection: $model.selection,
                mode: Binding(get: { model.sidebarMode }, set: model.switchSidebarMode),
                inventory: model.inventory, supervisor: supervisor,
                onAdd: { model.editingServer = .blank }, onAddProject: addProjectDirectory
            )
            .navigationTitle(Constants.mcpManager)
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section(Constants.add) {
                        Button(Constants.newServer, systemImage: "server.rack") { model.editingServer = .blank }
                        Button(Constants.projectFolder, systemImage: "folder.badge.plus", action: addProjectDirectory)
                        Button(Constants.importFromThisMac, systemImage: "magnifyingglass") {
                            Task { await model.scanLocalServers(alwaysPresent: true) }
                        }.disabled(model.isScanningLocal)
                        }
                        Section(Constants.xcode) {
                        Button(Constants.refreshConfigurations, systemImage: "arrow.clockwise") { model.refreshXcodeTargets() }
                            .disabled(model.isLoadingInventory)
                        Button(Constants.linkXcode, systemImage: "link") { model.showingXcodeWelcome = true }
                        Button(Constants.xcodeHistory, systemImage: "clock.arrow.circlepath") { model.showingHistory = true }
                        }
                        if model.sidebarMode == .catalog, let server = store.server(id: model.selection) {
                            Divider()
                            Button(Constants.removeFromCatalog, role: .destructive) { model.serverPendingDeletion = server }
                        }
                    } label: {
                        Label(Constants.managerActions, systemImage: "ellipsis")
                    }
                    .labelStyle(.iconOnly)
                    .help(Constants.addAnMcpServerRefreshOrLinkXcode)
                }
            }
        } detail: {
            if model.sidebarMode == .catalog && model.selectedServer == nil {
                MCPCatalogView(servers: store.servers, inventory: model.inventory, targets: model.xcodeTargets, isLoadingInventory: model.isLoadingInventory, filters: $model.catalogFilters,
                    onPrepare: { recipe in
                        model.editingServer = recipe.makeDraft()
                        model.managementMessage = "\(recipe.name) : \(recipe.displayRequirements) \(recipe.displayCaution)"
                    }, onOpen: { match in
                        model.switchSidebarMode(match.mode)
                        model.selection = match.server.id
                    }, onDelete: { model.serverPendingDeletion = $0 }, onAdd: { model.editingServer = .blank })
            } else if let server = model.selectedServer {
                ServerDetailView(
                    server: server,
                    status: supervisor.status(for: server),
                    logs: supervisor.logs[server.id, default: []],
                    diagnosticDetail: supervisor.diagnosticDetails[server.id],
                    tools: supervisor.tools[server.id],
                    toolsUpdatedAt: supervisor.toolsUpdatedAt[server.id],
                    toolsAreVerified: supervisor.verifiedToolIDs.contains(server.id),
                    identity: supervisor.identities[server.id],
                    xcodeTargets: model.inventory.entries.first(where: { $0.id == server.id }).map { [$0.target] } ?? model.xcodeTargets[server.id],
                    isManaging: model.isManaging,
                    onManage: { action, target in
                        if action == .uninstall { model.pendingUninstall = XcodeInventoryEntry(server: server, target: target) }
                        else { model.manage(action, server: server, target: target) }
                    },
                    onEdit: { model.editingServer = server },
                    onInstallInXcode: { kind in
                        model.preferredXcodeTarget = kind
                        model.installingInXcode = server
                    },
                    onRefreshXcode: { model.refreshXcodeTargets() },
                    onToggleEnabled: { store.setEnabled($0, for: server.id) },
                    onStartOrCheck: { supervisor.startOrCheck(server) },
                    onRefreshTools: { supervisor.startOrCheck(server) },
                    onRelinkXcode: { supervisor.relinkXcode(server, processID: $0) },
                    canRelinkXcode: supervisor.canRelinkXcode(server),
                    onStop: { supervisor.stop(server) },
                    onClearLogs: { supervisor.clearLogs(for: server.id) },
                    onEnvironment: { model.environmentServer = server },
                    onCheckEnvironment: { model.checkEnvironment(server) },
                    environmentMessage: model.environmentMessages[server.id],
                    isCheckingEnvironment: model.checkingEnvironmentID != nil
                )
                .task(id: server) { supervisor.restoreCachedTools(for: server) }
                .toolbar {
                    if model.sidebarMode == .catalog {
                        ToolbarItem(placement: .navigation) {
                            Button(Constants.catalog, systemImage: "chevron.left") { model.selection = nil }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(Constants.yourToolsAllInOnePlace, systemImage: "square.stack.3d.up")
                } description: {
                    Text(Constants.emptySelectionDescription)
                } actions: {
                    Button(Constants.exploreTheCatalog, systemImage: "square.grid.2x2") { model.switchSidebarMode(.catalog) }
                        .mcpActionStyle(prominent: true).controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { MCPCanvas() }
            }
        }
        .sheet(isPresented: $model.showingXcodeWelcome, onDismiss: {
            Task { await model.runInitialDiscovery() }
        }) {
            XcodeWelcomeView(supervisor: supervisor) {
                model.didSeeXcodeWelcome = true
                model.showingXcodeWelcome = false
            }
        }
        .sheet(item: $model.environmentServer) { server in
            MCPEnvironmentEditorView(server: server) { saved in
                model.saveEnvironment(saved, replacing: server)
            }
        }
        .sheet(item: $model.editingServer) { server in
            ServerEditorView(server: server) { saved in
                model.saveEditorDraft(saved)
            }
        }
        .sheet(isPresented: $model.showingLocalDiscovery) {
            if let localScanResult = model.localScanResult {
                LocalMCPDiscoveryView(
                    result: localScanResult,
                    existingServers: store.servers
                ) { selectedDiscoveries in
                    model.importServers(selectedDiscoveries.map(\.server))
                }
            }
        }
        .sheet(item: $model.installingInXcode, onDismiss: { model.refreshXcodeTargets() }) { server in
            XcodeInstallationView(
                server: server,
                knownToolCount: supervisor.tools[server.id]?.count,
                preferredTarget: model.preferredXcodeTarget,
                onServerUpdated: { saved in
                    model.saveInstallationDraft(saved, replacing: server)
                },
                onInstalled: { model.refreshXcodeTargets() }
            )
        }
        .sheet(isPresented: $model.showingHistory) {
            XcodeManagementHistoryView(receipts: model.receipts, isWorking: model.isManaging, error: model.managementError, onRestore: model.restore)
        }
        .confirmationDialog(Constants.uninstallThisServerFromXcode, isPresented: Binding(
            get: { model.pendingUninstall != nil }, set: { if !$0 { model.pendingUninstall = nil } }
        ), presenting: model.pendingUninstall) { entry in
            Button(Constants.uninstall(from: entry.target.kind.shortTitle), role: .destructive) {
                model.manage(.uninstall, server: entry.server, target: entry.target)
                model.pendingUninstall = nil
            }
        } message: { entry in
            Text(Constants.uninstallDescription(name: entry.target.configuredServerName ?? entry.server.name, agent: entry.target.kind.title))
        }
        .safeAreaInset(edge: .bottom) {
            if model.isManaging || model.managementMessage != nil || model.managementError != nil {
                HStack {
                    if model.isManaging { ProgressView().controlSize(.small) }
                    Text(model.managementError ?? model.managementMessage ?? Constants.applyingChanges)
                        .font(.callout).foregroundStyle(model.managementError == nil ? Color.secondary : .red)
                    Spacer()
                    Button(Constants.history) { model.showingHistory = true }
                    Button(Constants.close) { model.managementMessage = nil; model.managementError = nil }.disabled(model.isManaging)
                }.padding(14).mcpGlass(radius: 18).padding(12)
            }
        }
        .confirmationDialog(
            Constants.deleteThisServer,
            isPresented: Binding(
                get: { model.serverPendingDeletion != nil },
                set: { if !$0 { model.serverPendingDeletion = nil } }
            ),
            presenting: model.serverPendingDeletion
        ) { server in
            Button(Constants.delete(server.name), role: .destructive) {
                model.deleteCatalogServer(server)
            }
        } message: { server in
            Text(Constants.deleteDescription(server.name))
        }
        .alert(Constants.storageError, isPresented: Binding(
            get: { store.persistenceError != nil },
            set: { if !$0 { store.dismissPersistenceError() } }
        )) {
            Button(Constants.ok) { store.dismissPersistenceError() }
        } message: {
            Text(store.persistenceError ?? Constants.unknownError)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMCPServer)) { _ in
            model.editingServer = .blank
        }
        .task {
            if !model.didSeeXcodeWelcome { model.showingXcodeWelcome = true }
            else { await model.runInitialDiscovery() }
        }
        .task(id: store.servers) { model.refreshXcodeTargets() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshXcodeTargets()
        }
    }

    private func addProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = Constants.discoverProjectServers
        panel.message = Constants.projectDirectoryDescription
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        model.addProjectDirectories(panel.urls)
    }
}

private extension ContentView {
    enum Constants {
        static func uninstall(from agent: String) -> String {
            String(localized: "Désinstaller de \(agent)", table: "Localizable")
        }

        static func uninstallDescription(name: String, agent: String) -> String {
            String(localized: "L’entrée « \(name) » sera retirée de \(agent). Vous pourrez la restaurer depuis l’historique. Les autres agents ne sont pas concernés.", table: "Localizable")
        }

        static func delete(_ name: String) -> String {
            String(localized: "Supprimer \(name)", table: "Localizable")
        }

        static func deleteDescription(_ name: String) -> String {
            String(localized: "La définition de \(name) sera retirée du catalogue local.", table: "Localizable")
        }

        static let add = String(localized: "Ajouter", table: "Localizable")
        static let newServer = String(localized: "Nouveau serveur", table: "Localizable")
        static let projectFolder = String(localized: "Dossier de projet…", table: "Localizable")
        static let importFromThisMac = String(localized: "Importer depuis ce Mac…", table: "Localizable")
        static let refreshConfigurations = String(localized: "Actualiser les configurations", table: "Localizable")
        static let linkXcode = String(localized: "Relier Xcode…", table: "Localizable")
        static let xcodeHistory = String(localized: "Historique Xcode", table: "Localizable")
        static let removeFromCatalog = String(localized: "Retirer du catalogue", table: "Localizable")
        static let managerActions = String(localized: "Actions du Manager", table: "Localizable")
        static let addAnMcpServerRefreshOrLinkXcode = String(localized: "Ajouter un MCP, actualiser ou relier Xcode", table: "Localizable")
        static let catalog = String(localized: "Catalogue", table: "Localizable")
        static let yourToolsAllInOnePlace = String(localized: "Vos outils, au même endroit", table: "Localizable")
        static let emptySelectionDescription = String(localized: "Sélectionnez un MCP dans la barre latérale pour le gérer, ou découvrez de nouveaux outils dans le catalogue.", table: "Localizable")
        static let exploreTheCatalog = String(localized: "Explorer le catalogue", table: "Localizable")
        static let uninstallThisServerFromXcode = String(localized: "Désinstaller ce serveur de Xcode ?", table: "Localizable")
        static let applyingChanges = String(localized: "Application de la modification…", table: "Localizable")
        static let history = String(localized: "Historique", table: "Localizable")
        static let close = String(localized: "Fermer", table: "Localizable")
        static let deleteThisServer = String(localized: "Supprimer ce serveur ?", table: "Localizable")
        static let storageError = String(localized: "Erreur de stockage", table: "Localizable")
        static let unknownError = String(localized: "Erreur inconnue", table: "Localizable")
        static let discoverProjectServers = String(localized: "Détecter les MCP d’un projet", table: "Localizable")
        static let projectDirectoryDescription = String(localized: "Choisissez le dossier du projet contenant .codex/config.toml. Aucun fichier ne sera modifié.", table: "Localizable")
        static let mcpManager = String(localized: "MCP Manager", table: "Localizable")
        static let xcode = String(localized: "Xcode", table: "Localizable")
        static let ok = String(localized: "OK", table: "Localizable")
    }
}
