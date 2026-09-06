import SwiftUI

/// Presentation for guided installation; mutation and validation live in the model.
struct XcodeInstallationView: View {
    @StateObject private var model: XcodeInstallationViewModel
    @Environment(\.dismiss) private var dismiss

    init(server: MCPServer, knownToolCount: Int?, preferredTarget: XcodeInstallationTarget.Kind? = nil, onServerUpdated: @escaping (MCPServer) -> Void = { _ in }, onInstalled: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: XcodeInstallationViewModel(server: server, knownToolCount: knownToolCount, preferredTarget: preferredTarget, onServerUpdated: onServerUpdated, onInstalled: onInstalled))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction
                    targetSelection
                    diagnostic
                    preview
                    resultPanel
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .navigationTitle(Constants.installationTitle(action: model.selectedTarget?.actionTitle ?? Constants.install, server: model.server.name))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Constants.close) { dismiss() }
                        .disabled(model.isInstalling)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .installed = model.installationState {
                        Button(Constants.done) { dismiss() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(model.selectedTarget?.actionTitle ?? Constants.install, systemImage: "square.and.arrow.down") {
                            model.requestInstallation()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.hasBlockingIssue || model.selectedTarget == nil || model.isInstalling)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 680)
        .interactiveDismissDisabled(model.isInstalling)
        .sheet(isPresented: $model.showingEnvironment) {
            MCPEnvironmentEditorView(server: model.server) { saved in
                model.updateDraft(saved)
            }
        }
        .alert(Constants.installWithUnresolvedWarnings, isPresented: $model.confirmingWarnings) {
            Button(Constants.backToDiagnostics, role: .cancel) { }
            Button(Constants.installAnyway) { model.install(allowWarnings: true) }
        } message: {
            Text(model.acknowledgedWarnings.joined(separator: "\n\n") + Constants.unresolvedWarningsDescription)
        }
    }

    private var introduction: some View {
        HStack(spacing: 14) {
            Image(systemName: "hammer.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(Constants.guidedSetup)
                    .font(.title2.bold())
                Text(Constants.installationScopeDescription)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var targetSelection: some View {
        GroupBox(Constants.xcodeAgent) {
            VStack(spacing: 0) {
                ForEach(model.targets) { target in
                    Button {
                        model.selectTarget(target)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.selectedKind == target.kind ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(target.isAvailable ? Color.accentColor : .secondary)
                            Image(systemName: target.kind.symbolName)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(target.kind.title)
                                    .fontWeight(.medium)
                                Text(target.isAvailable ? target.kind.detail : Constants.notFoundInXcode)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(target.statusTitle)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(target.detectionError != nil ? .orange : target.isAlreadyConfigured && !target.isDisabled ? .green : .secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .disabled(!target.isAvailable || model.isInstalling)
                    if target.id != model.targets.last?.id { Divider() }
                }
            }
        }
    }

    private var diagnostic: some View {
        GroupBox(Constants.diagnostics) {
            VStack(alignment: .leading, spacing: 9) {
                diagnosticLine(
                    title: Constants.validMcpDefinition,
                    successful: model.server.isValid
                )
                diagnosticLine(
                    title: (!model.configurationChanged ? model.knownToolCount : nil).map { Constants.discoveredTools($0) } ?? Constants.testTheConnectionAfterInstallation,
                    successful: !model.configurationChanged && model.knownToolCount != nil
                )
                if model.issues.isEmpty {
                    Label(Constants.readyToInstall, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(model.issues) { issue in
                        Label(
                            issue.message,
                            systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                        .font(.callout)
                    }
                }
                if case .installed = model.installationState {
                    EmptyView()
                } else {
                    Button(Constants.setVariablesAndSecrets, systemImage: "key") {
                        model.showingEnvironment = true
                    }
                    .mcpActionStyle().disabled(model.isInstalling)
                    Text(Constants.environmentSetupDescription)
                        .font(.caption).foregroundStyle(.secondary)
                    if model.server.transport == .streamableHTTP {
                        Text(Constants.httpTokenWarning)
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var preview: some View {
        GroupBox(Constants.configurationPreview) {
            VStack(alignment: .leading, spacing: 8) {
                if let target = model.selectedTarget {
                    Text(abbreviatedPath(target.configurationURL.path))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(model.installer.preview(for: model.server, target: target.kind))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    @ViewBuilder
    private var resultPanel: some View {
        switch model.installationState {
        case .ready:
            EmptyView()
        case .installing:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(Constants.installingAndVerifying)
            }
        case .installed(let receipt):
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(receipt.replacedExistingEntry ? Constants.updated : Constants.installed) · \(receipt.target.title)", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text(Constants.newConversationHint)
                    if !model.acknowledgedWarnings.isEmpty {
                        Label(Constants.installationWarningsHint, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let backupURL = receipt.backupURL {
                        Text(Constants.backupPath(abbreviatedPath(backupURL.path)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func diagnosticLine(title: String, successful: Bool) -> some View {
        Label(title, systemImage: successful ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(successful ? .green : .secondary)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

private extension XcodeInstallationView {
    enum Constants {
        static let unresolvedWarningsDescription = String(localized: "\n\nLa configuration sera écrite, mais le serveur peut ne pas fonctionner tant que ces points ne sont pas résolus. Aucun test de connexion réussi n’est garanti.", table: "Localizable")

        static func installationTitle(action: String, server: String) -> String {
            String(localized: "\(action) \(server) dans Xcode", table: "Localizable")
        }

        static func discoveredTools(_ count: Int) -> String {
            String(localized: "\(count) outils MCP découverts", table: "Localizable")
        }

        static func backupPath(_ path: String) -> String {
            String(localized: "Sauvegarde : \(path)", table: "Localizable")
        }

        static let install = String(localized: "Installer", table: "Localizable")
        static let close = String(localized: "Fermer", table: "Localizable")
        static let done = String(localized: "Terminé", table: "Localizable")
        static let installWithUnresolvedWarnings = String(localized: "Installer avec des points à vérifier ?", table: "Localizable")
        static let backToDiagnostics = String(localized: "Revenir au diagnostic", table: "Localizable")
        static let installAnyway = String(localized: "Installer quand même", table: "Localizable")
        static let guidedSetup = String(localized: "Configuration guidée", table: "Localizable")
        static let installationScopeDescription = String(localized: "Cette action concerne la configuration globale de l’agent Xcode, pas les fichiers des projets. MCP Manager sauvegarde la configuration existante, ajoute le serveur puis vérifie son écriture.", table: "Localizable")
        static let xcodeAgent = String(localized: "Agent Xcode", table: "Localizable")
        static let notFoundInXcode = String(localized: "Non détecté dans Xcode", table: "Localizable")
        static let diagnostics = String(localized: "Diagnostic", table: "Localizable")
        static let validMcpDefinition = String(localized: "Définition MCP valide", table: "Localizable")
        static let testTheConnectionAfterInstallation = String(localized: "Connexion à tester après installation", table: "Localizable")
        static let readyToInstall = String(localized: "Prêt à installer", table: "Localizable")
        static let setVariablesAndSecrets = String(localized: "Compléter les variables et secrets…", table: "Localizable")
        static let environmentSetupDescription = String(localized: "Enregistrez les valeurs ici, puis le diagnostic et l’aperçu seront recalculés. Les secrets ne sont jamais affichés dans l’aperçu. Un avertissement n’est pas une preuve qu’une variable est absente : elle peut être fournie en dehors du Manager.", table: "Localizable")
        static let httpTokenWarning = String(localized: "Attention : les tokens HTTP enregistrés dans le Manager servent aux tests locaux uniquement. Leur transmission à Xcode n’est pas encore disponible.", table: "Localizable")
        static let configurationPreview = String(localized: "Aperçu des champs appliqués", table: "Localizable")
        static let installingAndVerifying = String(localized: "Installation et vérification…", table: "Localizable")
        static let updated = String(localized: "Mis à jour", table: "Localizable")
        static let installed = String(localized: "Installé", table: "Localizable")
        static let newConversationHint = String(localized: "Ouvrez une nouvelle conversation avec l’agent dans Xcode pour charger le serveur.", table: "Localizable")
        static let installationWarningsHint = String(localized: "Configuration installée avec réserves : les avertissements acceptés restent à vérifier.", table: "Localizable")
    }
}
