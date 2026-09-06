import AppKit
import SwiftUI

private extension MCPServer {
    /// Display-only summary, never used to launch a shell command.
    var commandLine: String { ([command] + arguments).joined(separator: " ") }
}

struct ServerDetailView: View {
    let server: MCPServer
    let status: MCPProcessSupervisor.Status
    let logs: [String]
    let diagnosticDetail: String?
    let tools: [MCPTool]?
    let toolsUpdatedAt: Date?
    let toolsAreVerified: Bool
    let identity: MCPServerIdentity?
    let xcodeTargets: [XcodeInstallationTarget]?
    let isManaging: Bool
    let onManage: (XcodeManagementAction, XcodeInstallationTarget) -> Void
    let onEdit: () -> Void
    let onInstallInXcode: (XcodeInstallationTarget.Kind?) -> Void
    let onRefreshXcode: () -> Void
    let onToggleEnabled: (Bool) -> Void
    let onStartOrCheck: () -> Void
    let onRefreshTools: () -> Void
    let onRelinkXcode: (Int32) -> Void
    let canRelinkXcode: Bool
    let onStop: () -> Void
    let onClearLogs: () -> Void
    let onEnvironment: () -> Void
    let onCheckEnvironment: () -> Void
    let environmentMessage: String?
    let isCheckingEnvironment: Bool

    @State private var copied = false
    @State private var confirmingRelink = false
    @AppStorage("mcp-tools-section-expanded") private var toolsExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                xcodeInstallation
                if server.transport == .streamableHTTP {
                    MCPOAuthPanel(server: server, onAuthorized: onStartOrCheck).id(server.id)
                }
                environmentPanel
                overview
                toolsPanel
                configuration
                logPanel
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { MCPCanvas() }
        .groupBoxStyle(MCPPanelStyle())
        .navigationTitle(server.name)
        .sheet(isPresented: $confirmingRelink) { XcodeRelinkSheet(onRelink: onRelinkXcode) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(server.name)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    StatusBadge(status: status)
                    Spacer(minLength: 12)
                    if server.xcodeBinding?.projectDirectoryURL == nil {
                        Button(Constants.edit, systemImage: "pencil", action: onEdit)
                            .mcpActionStyle()
                            .help(Constants.editThisMcp)
                    } else {
                        Label(Constants.readOnly, systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(Constants.projectConfigurationsAreCurrentlyReadOnly)
                    }
                }
                Text(server.transport == .stdio ? server.commandLine : server.url)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 16) {
            if let project = xcodeTargets?.first(where: { $0.isProjectConfiguration }),
               xcodeTargets?.contains(where: { !$0.isProjectConfiguration && $0.isAlreadyConfigured }) != true {
                Button(Constants.viewProjectConfiguration, systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.configurationURL])
                }.mcpActionStyle()
            } else {
                Button(xcodeActionTitle, systemImage: "hammer") { onInstallInXcode(nil) }
                    .mcpActionStyle(prominent: true)
                    .disabled(xcodeTargets == nil || isManaging)
            }
            Spacer(minLength: 0)
            Toggle(Constants.localTestsEnabled, isOn: Binding(
                get: { server.enabled },
                set: { newValue in onToggleEnabled(newValue) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(server.xcodeBinding?.projectDirectoryURL != nil)
            }
        }
    }

    private var xcodeActionTitle: String {
        guard let xcodeTargets else { return Constants.checkingXcode }
        return xcodeTargets.contains { $0.isAlreadyConfigured || $0.detectionError != nil }
            ? Constants.manageGlobally : Constants.installGlobally
    }

    private var xcodeInstallation: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(Constants.xcodeInstallation, systemImage: "hammer")
                        .font(.headline)
                    Spacer()
                    Button(Constants.refresh, systemImage: "arrow.clockwise", action: onRefreshXcode)
                }
                if let xcodeTargets {
                    ForEach(xcodeTargets) { target in
                        HStack(spacing: 12) {
                            Image(systemName: target.kind.symbolName)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(target.kind.title) · \(target.scopeTitle)").fontWeight(.medium)
                                Text(target.statusTitle)
                                    .foregroundStyle(target.detectionError != nil ? .orange : target.isAlreadyConfigured && !target.isDisabled ? .green : .secondary)
                                if let name = target.configuredServerName, name != server.name {
                                    Text(Constants.registeredAs(name)).font(.caption).foregroundStyle(.secondary)
                                }
                                if target.kind == .claude && target.isDisabled {
                                    Text(Constants.definitionKeptByMcpManagerForReEnabling)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let error = target.detectionError {
                                    Text(error).font(.caption).foregroundStyle(.orange)
                                }
                                if target.isProjectConfiguration {
                                    Text(target.configurationURL.path).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    Text(Constants.projectLoadingHint)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if target.isProjectConfiguration {
                                Button(Constants.showFile, systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([target.configurationURL])
                                }
                            } else if target.isAvailable && target.detectionError == nil {
                                Menu(Constants.actions) {
                                    if target.isAlreadyConfigured {
                        Button(target.isDisabled ? Constants.enable(in: target.kind.shortTitle) : Constants.disable(in: target.kind.shortTitle)) {
                                            onManage(target.isDisabled ? .enable : .disable, target)
                                        }.disabled(target.revision == nil)
                                        Button(Constants.uninstall(from: target.kind.shortTitle), role: .destructive) {
                                            onManage(.uninstall, target)
                                        }.disabled(target.revision == nil)
                                        Divider()
                                    }
                                    Button(target.isAlreadyConfigured ? Constants.updateGlobally : Constants.installGlobally) {
                                        onInstallInXcode(target.kind)
                                    }
                                }.disabled(isManaging)
                            } else {
                                Button(Constants.viewDetails) { onInstallInXcode(target.kind) }
                            }
                        }
                    }
                    Text(Constants.installationStatusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(Constants.readingXcodeConfigurations)
                }
            }
        }
    }

    private var overview: some View {
        GroupBox(Constants.localServerTest) {
            if case .failed(let message) = status {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let diagnosticDetail {
                    MCPDiagnosticButton(detail: diagnosticDetail).id(server.id)
                }
            }
            HStack(spacing: 12) {
                if canRelinkXcode {
                    Button(Constants.linkToXcode, systemImage: "link") { confirmingRelink = true }
                        .mcpActionStyle()
                        .disabled(!server.enabled || status == .starting || status == .checking)
                }
                if status.isActive && server.transport == .stdio {
                    Button(Constants.stop, systemImage: "stop.fill", role: .destructive, action: onStop)
                } else {
                    Button(
                        server.transport == .stdio ? Constants.start : Constants.testConnection,
                        systemImage: server.transport == .stdio ? "play.fill" : "wave.3.right",
                        action: onStartOrCheck
                    )
                    .mcpActionStyle(prominent: true)
                    .disabled(!server.enabled || !server.isValid)
                }
                Text(server.scope == .global ? Constants.globalConfiguration : Constants.projectConfiguration)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 4)

            if let identity {
                Divider()
                    .padding(.vertical, 6)
                LabeledContent(Constants.server, value: "\(identity.name) · \(identity.version)")
                LabeledContent(Constants.protocolTitle, value: "\(identity.protocolVersion) · \(identity.era.title)")
                if let instructions = identity.instructions, !instructions.isEmpty {
                    LabeledContent(Constants.instructions) {
                        Text(instructions)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var environmentPanel: some View {
        GroupBox(Constants.variablesAndSecrets) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(server.environmentProfileID == nil ? Constants.unmanagedValues : Constants.profileSavedAccessNeedsChecking,
                        systemImage: server.environmentProfileID == nil ? "key" : "lock.shield")
                    Spacer()
                    Button(Constants.configure, action: onEnvironment).disabled(isCheckingEnvironment || isManaging)
                    if server.environmentProfileID != nil {
                        Button(Constants.verifyTransmission, action: onCheckEnvironment)
                            .disabled(isCheckingEnvironment || isManaging)
                    }
                }
                let names = MCPEnvironmentService().requiredNames(server)
                if !names.isEmpty {
                    Text(names.joined(separator: ", ")).font(.callout.monospaced()).textSelection(.enabled)
                }
                Text(server.environmentProfileID == nil
                    ? Constants.sourceCredentialsDescription
                    : Constants.keychainVerificationHint)
                    .font(.caption).foregroundStyle(.secondary)
                if server.xcodeBinding?.projectDirectoryURL != nil {
                    Text(Constants.readOnlyProfileHint)
                        .font(.caption).foregroundStyle(.secondary)
                } else if server.transport == .streamableHTTP, server.environmentProfileID != nil {
                    Text(Constants.httpTokenScopeHint)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isCheckingEnvironment { ProgressView(Constants.checkingTheLauncherAndKeychain) }
                if let environmentMessage { Text(environmentMessage).font(.callout).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolsPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        toolsExpanded.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold)).frame(width: 12)
                            Label(Constants.mcpTools, systemImage: "wrench.and.screwdriver").font(.headline)
                        }
                    }.buttonStyle(.plain)
                    .accessibilityLabel(toolsExpanded ? Constants.collapseMcpTools : Constants.expandMcpTools)
                    if let tools {
                        Text("\(tools.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.14), in: Capsule())
                    }
                    Spacer()
                    Button(Constants.refresh, systemImage: "arrow.clockwise", action: onRefreshTools)
                        .disabled(!server.enabled || status == .starting || status == .checking)
                }

                if let toolsUpdatedAt {
                    Text("\(toolsAreVerified ? Constants.updatedList : Constants.lastKnownListNotReverified) · \(toolsUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if toolsExpanded {
                if let tools, !tools.isEmpty {
                    ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tools) { tool in
                            ToolDisclosure(tool: tool)
                            if tool.id != tools.last?.id { Divider() }
                        }
                    }
                    .padding(10)
                    }
                    .frame(height: min(max(CGFloat(tools.count) * 58, 140), 340))
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                } else if tools != nil {
                    Text(Constants.thisServerDoesNotPublishAnyTools)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                } else {
                    Text(Constants.connectTheServerToDiscoverItsTools)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                }
                Text(Constants.cachedToolsDescription)
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var configuration: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Constants.codexConfiguration)
                        .font(.headline)
                    Spacer()
                    Button(copied ? Constants.copied : Constants.copy, systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CodexConfigRenderer.render(server), forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    }
                }
                Text(CodexConfigRenderer.render(server))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var logPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Constants.log)
                        .font(.headline)
                    Spacer()
                    if let diagnosticDetail {
                        MCPDiagnosticButton(detail: diagnosticDetail).id(server.id)
                    }
                    Button(Constants.clear, action: onClearLogs)
                        .disabled(logs.isEmpty)
                }
                if logs.isEmpty {
                    Text(Constants.noActivityYet)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
                } else {
                    Text(logs.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                }
            }
        }
    }
}

private extension ServerDetailView {
    enum Constants {
        static func registeredAs(_ name: String) -> String {
            String(localized: "Enregistré sous « \(name) »", table: "Localizable")
        }

        static func enable(in agent: String) -> String {
            String(localized: "Activer dans \(agent)", table: "Localizable")
        }

        static func disable(in agent: String) -> String {
            String(localized: "Désactiver dans \(agent)", table: "Localizable")
        }

        static func uninstall(from agent: String) -> String {
            String(localized: "Désinstaller de \(agent)", table: "Localizable")
        }

        static let edit = String(localized: "Modifier", table: "Localizable")
        static let editThisMcp = String(localized: "Modifier ce MCP", table: "Localizable")
        static let readOnly = String(localized: "Lecture seule", table: "Localizable")
        static let projectConfigurationsAreCurrentlyReadOnly = String(localized: "Les configurations de projet sont actuellement en lecture seule.", table: "Localizable")
        static let viewProjectConfiguration = String(localized: "Voir la configuration projet", table: "Localizable")
        static let localTestsEnabled = String(localized: "Tests locaux activés", table: "Localizable")
        static let checkingXcode = String(localized: "Vérification Xcode…", table: "Localizable")
        static let manageGlobally = String(localized: "Gérer globalement", table: "Localizable")
        static let installGlobally = String(localized: "Installer globalement", table: "Localizable")
        static let xcodeInstallation = String(localized: "Installation dans Xcode", table: "Localizable")
        static let refresh = String(localized: "Actualiser", table: "Localizable")
        static let definitionKeptByMcpManagerForReEnabling = String(localized: "Définition conservée par MCP Manager pour la réactivation.", table: "Localizable")
        static let projectLoadingHint = String(localized: "Lecture seule · le chargement dépend du projet ouvert et de la confiance accordée dans Codex.", table: "Localizable")
        static let showFile = String(localized: "Afficher le fichier", table: "Localizable")
        static let actions = String(localized: "Actions", table: "Localizable")
        static let updateGlobally = String(localized: "Mettre à jour globalement", table: "Localizable")
        static let viewDetails = String(localized: "Voir les détails", table: "Localizable")
        static let installationStatusDescription = String(localized: "Ces états indiquent la présence dans la configuration de l’agent. Le chargement et la connexion dans Xcode restent à vérifier dans une conversation.", table: "Localizable")
        static let readingXcodeConfigurations = String(localized: "Lecture des configurations Xcode…", table: "Localizable")
        static let localServerTest = String(localized: "Test local du serveur", table: "Localizable")
        static let linkToXcode = String(localized: "Relier à Xcode…", table: "Localizable")
        static let stop = String(localized: "Arrêter", table: "Localizable")
        static let start = String(localized: "Démarrer", table: "Localizable")
        static let testConnection = String(localized: "Tester la connexion", table: "Localizable")
        static let globalConfiguration = String(localized: "Configuration globale", table: "Localizable")
        static let projectConfiguration = String(localized: "Configuration du projet", table: "Localizable")
        static let server = String(localized: "Serveur", table: "Localizable")
        static let protocolTitle = String(localized: "Protocole", table: "Localizable")
        static let instructions = String(localized: "Instructions", table: "Localizable")
        static let variablesAndSecrets = String(localized: "Variables et secrets", table: "Localizable")
        static let unmanagedValues = String(localized: "Valeurs non gérées", table: "Localizable")
        static let profileSavedAccessNeedsChecking = String(localized: "Profil enregistré · accès à vérifier", table: "Localizable")
        static let configure = String(localized: "Configurer", table: "Localizable")
        static let verifyTransmission = String(localized: "Vérifier la transmission", table: "Localizable")
        static let sourceCredentialsDescription = String(localized: "Le test relit les variables et en-têtes de la configuration source lorsqu’elle est identifiable. Aucune valeur n’est copiée au catalogue. Une session OAuth Xcode n’est pas une variable d’environnement.", table: "Localizable")
        static let keychainVerificationHint = String(localized: "Les secrets restent dans le Trousseau. Un test du lanceur ne prouve pas que la conversation Xcode les a chargés.", table: "Localizable")
        static let readOnlyProfileHint = String(localized: "Projet en lecture seule : ce profil ne s’applique qu’aux tests locaux.", table: "Localizable")
        static let httpTokenScopeHint = String(localized: "Token HTTP utilisable dans l’app uniquement ; transmission à Xcode non prise en charge.", table: "Localizable")
        static let checkingTheLauncherAndKeychain = String(localized: "Contrôle du lanceur et du Trousseau…", table: "Localizable")
        static let mcpTools = String(localized: "Outils MCP", table: "Localizable")
        static let collapseMcpTools = String(localized: "Replier les outils MCP", table: "Localizable")
        static let expandMcpTools = String(localized: "Déplier les outils MCP", table: "Localizable")
        static let updatedList = String(localized: "Liste actualisée", table: "Localizable")
        static let lastKnownListNotReverified = String(localized: "Dernière liste connue · non revérifiée", table: "Localizable")
        static let thisServerDoesNotPublishAnyTools = String(localized: "Ce serveur ne publie aucun outil.", table: "Localizable")
        static let connectTheServerToDiscoverItsTools = String(localized: "Connectez le serveur pour découvrir ses outils.", table: "Localizable")
        static let cachedToolsDescription = String(localized: "Les définitions d’outils sont conservées localement. Une liste enregistrée ne signifie pas que le serveur est connecté.", table: "Localizable")
        static let codexConfiguration = String(localized: "Configuration Codex", table: "Localizable")
        static let copied = String(localized: "Copié", table: "Localizable")
        static let copy = String(localized: "Copier", table: "Localizable")
        static let log = String(localized: "Journal", table: "Localizable")
        static let clear = String(localized: "Effacer", table: "Localizable")
        static let noActivityYet = String(localized: "Aucune activité pour le moment.", table: "Localizable")
    }
}
