import SwiftUI

struct MCPDiagnosticButton: View {
    let detail: String
    @State private var confirming = false
    @State private var revealed: String?

    var body: some View {
        Button(Constants.showDetails, systemImage: "exclamationmark.shield") { confirming = true }
            .mcpActionStyle()
            .alert(Constants.theseDetailsMayContainSecrets, isPresented: $confirming) {
                Button(Constants.cancel, role: .cancel) {}
                Button(Constants.showAnyway) { revealed = detail }
            } message: {
                Text(Constants.sensitiveDetailsWarning)
            }
            .sheet(isPresented: Binding(get: { revealed != nil }, set: { if !$0 { revealed = nil } })) {
                VStack(alignment: .leading, spacing: 16) {
                    Label(Constants.sensitiveMcpErrorDetails, systemImage: "exclamationmark.shield")
                        .font(.title2.weight(.semibold))
                    Text(Constants.sensitiveDetailsDescription)
                        .font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        Text(revealed ?? "")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }.mcpCard()
                    HStack {
                        Text(Constants.sensitiveDetailsRetentionHint)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(Constants.hide) { revealed = nil }.keyboardShortcut(.cancelAction)
                    }
                }.padding(24).frame(width: 680, height: 440)
            }
            .onChange(of: detail) { _, _ in revealed = nil; confirming = false }
    }
}

private extension MCPDiagnosticButton {
    enum Constants {
        static let showDetails = String(localized: "Afficher le détail…", table: "Localizable")
        static let theseDetailsMayContainSecrets = String(localized: "Ce détail peut contenir des secrets", table: "Localizable")
        static let cancel = String(localized: "Annuler", table: "Localizable")
        static let showAnyway = String(localized: "Afficher quand même", table: "Localizable")
        static let sensitiveDetailsWarning = String(localized: "Le serveur peut inclure des tokens, identifiants, chemins ou données privées dans son message d’erreur. Le détail sera visible à l’écran et sélectionnable : ne le partagez pas sans le relire. Il reste uniquement en mémoire et n’est pas ajouté au journal ni enregistré sur disque.", table: "Localizable")
        static let sensitiveMcpErrorDetails = String(localized: "Détail sensible de l’erreur MCP", table: "Localizable")
        static let sensitiveDetailsDescription = String(localized: "Diagnostic non expurgé, limité à 8 000 caractères. À l’arrêt du processus, il inclut les derniers messages STDERR et les sorties STDOUT non standards disponibles. Ce panneau ne lit pas les variables d’environnement.", table: "Localizable")
        static let sensitiveDetailsRetentionHint = String(localized: "Relancer le test, arrêter le serveur ou effacer le journal supprime le détail retenu.", table: "Localizable")
        static let hide = String(localized: "Masquer", table: "Localizable")
    }
}
