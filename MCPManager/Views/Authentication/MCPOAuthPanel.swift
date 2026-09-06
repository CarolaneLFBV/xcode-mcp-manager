import SwiftUI

struct MCPOAuthPanel: View {
    let server: MCPServer
    let onAuthorized: () -> Void
    @ObservedObject private var oauth = MCPOAuthController.shared
    @State private var showingConnection = false
    @State private var showingDisconnect = false

    private var supported: Bool { (try? MCPOAuthSecurity.resource(server)) != nil }
    private var busy: Bool { oauth.activeBinding == MCPOAuthSecurity.binding(server) }

    var body: some View {
        GroupBox(Constants.oauthConnection) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(oauth.hasStored(server) ? Constants.authorizationSavedOnThisMac : Constants.noAccountConnectedToManager,
                          systemImage: oauth.hasStored(server) ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    Spacer()
                    if busy {
                        Button(Constants.cancel) { oauth.cancel() }
                    } else {
                        Button(oauth.hasStored(server) ? Constants.reconnect : Constants.signIn) { showingConnection = true }
                            .mcpActionStyle(prominent: true)
                            .disabled(!supported || oauth.activeBinding != nil)
                        if oauth.hasStored(server) {
                            Button(Constants.forgetConnection) { showingDisconnect = true }
                                .disabled(oauth.activeBinding != nil)
                        }
                    }
                }
                Text(Constants.accountIsolationDescription)
                    .font(.caption).foregroundStyle(.secondary)
                if !supported {
                    Text(Constants.supportedProvidersDescription)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if busy { ProgressView().controlSize(.small) }
                if let message = oauth.message(server) { Text(message).font(.callout).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingConnection) {
            MCPOAuthConnectionSheet(server: server) { discovery in
                showingConnection = false
                oauth.connect(server, discovery: discovery, onAuthorized: { onAuthorized() })
            }
        }
        .confirmationDialog(Constants.forgetThisConnectionOnThisMac, isPresented: $showingDisconnect) {
            Button(Constants.forgetConnection, role: .destructive) { oauth.disconnect(server) }
        } message: {
            Text(Constants.disconnectDescription)
        }
    }
}

private struct MCPOAuthConnectionSheet: View {
    let server: MCPServer
    let onContinue: (MCPOAuthDiscovery) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var discovery: MCPOAuthDiscovery?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Constants.connect(server.name)).font(.title2.bold())
            Text(Constants.authorizationDescription)
            if let discovery {
                LabeledContent(Constants.provider, value: discovery.metadata.issuer)
                LabeledContent(Constants.mcpServer, value: discovery.resource)
                Text(Constants.permissionsAnnouncedByTheServer).font(.headline)
                Text(discovery.scopes.isEmpty ? Constants.theProviderWillSpecifyThePermissions : discovery.scopes.joined(separator: ", "))
                    .font(.callout.monospaced()).textSelection(.enabled)
                if discovery.scopes.contains(where: { $0.contains("write") || $0.contains("admin") }) {
                    Label(Constants.writePermissionsWarning, systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
                Text(Constants.registrationDescription)
                    .font(.caption).foregroundStyle(.secondary)
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else { ProgressView(Constants.checkingPublicOauthInformation) }
            Divider()
            HStack {
                Button(Constants.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(Constants.continueToSentry) { if let discovery { onContinue(discovery) } }
                    .buttonStyle(.borderedProminent).disabled(discovery == nil)
            }
        }
        .padding(26).frame(width: 570)
        .task(id: server) {
            do { discovery = try await MCPOAuthController.shared.discover(server) }
            catch { failure = MCPOAuthController.safeMessage(error) }
        }
    }
}

private extension MCPOAuthPanel {
    enum Constants {
        static let oauthConnection = String(localized: "Connexion OAuth", table: "Localizable")
        static let authorizationSavedOnThisMac = String(localized: "Autorisation enregistrée sur ce Mac", table: "Localizable")
        static let noAccountConnectedToManager = String(localized: "Compte non connecté au Manager", table: "Localizable")
        static let cancel = String(localized: "Annuler", table: "Localizable")
        static let reconnect = String(localized: "Se reconnecter", table: "Localizable")
        static let signIn = String(localized: "Se connecter", table: "Localizable")
        static let forgetConnection = String(localized: "Oublier la connexion", table: "Localizable")
        static let accountIsolationDescription = String(localized: "Le compte du Manager reste distinct de celui de Xcode. Aucun fichier Xcode n’est modifié et aucun jeton n’est copié depuis l’agent.", table: "Localizable")
        static let supportedProvidersDescription = String(localized: "Premier lot : Sentry MCP en HTTPS, sans paramètres d’URL ni profil de token manuel. Les autres fournisseurs ne sont pas encore pris en charge.", table: "Localizable")
        static let forgetThisConnectionOnThisMac = String(localized: "Oublier cette connexion sur ce Mac ?", table: "Localizable")
        static let disconnectDescription = String(localized: "Les jetons du Manager seront supprimés du Trousseau. Cela ne déconnecte pas Xcode et ne révoque pas l’autorisation sur le site de Sentry.", table: "Localizable")
    }
}

private extension MCPOAuthConnectionSheet {
    enum Constants {
        static func connect(_ name: String) -> String {
            String(localized: "Connecter \(name)", table: "Localizable")
        }

        static let authorizationDescription = String(localized: "Vous allez autoriser MCP Manager à accéder à ce serveur. La connexion se fera sur le site officiel, dans votre navigateur.", table: "Localizable")
        static let provider = String(localized: "Fournisseur", table: "Localizable")
        static let mcpServer = String(localized: "Serveur MCP", table: "Localizable")
        static let permissionsAnnouncedByTheServer = String(localized: "Permissions annoncées par le serveur", table: "Localizable")
        static let theProviderWillSpecifyThePermissions = String(localized: "Le fournisseur précisera les permissions.", table: "Localizable")
        static let writePermissionsWarning = String(localized: "Ces permissions incluent des actions d’écriture. Vérifiez l’écran de consentement et refusez si elles ne vous conviennent pas.", table: "Localizable")
        static let registrationDescription = String(localized: "Continuer vérifiera le Trousseau, enregistrera un client OAuth natif auprès de Sentry, puis ouvrira le navigateur. Ce prototype utilise l’enregistrement dynamique ; chaque nouvelle tentative crée un client. Le retour local expire après trois minutes.", table: "Localizable")
        static let checkingPublicOauthInformation = String(localized: "Vérification des informations publiques OAuth…", table: "Localizable")
        static let cancel = String(localized: "Annuler", table: "Localizable")
        static let continueToSentry = String(localized: "Continuer vers Sentry", table: "Localizable")
    }
}
