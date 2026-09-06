import SwiftUI

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: ServerEditorViewModel

    let onSave: (MCPServer) -> Void

    init(server: MCPServer, onSave: @escaping (MCPServer) -> Void) {
        _model = StateObject(wrappedValue: ServerEditorViewModel(server: server))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(Constants.identity) {
                    TextField(Constants.name, text: $model.draft.name, prompt: Text(Constants.serverNamePlaceholder))
                    Picker(Constants.scope, selection: $model.draft.scope) {
                        ForEach(MCPServer.Scope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    Toggle(Constants.enabled, isOn: $model.draft.enabled)
                }

                Section(Constants.transport) {
                    Picker(Constants.type, selection: $model.draft.transport) {
                        ForEach(MCPServer.Transport.allCases) { transport in
                            Text(transport.title).tag(transport)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.draft.transport == .stdio {
                        TextField(Constants.command, text: $model.draft.command, prompt: Text(Constants.npx))
                        TextField(Constants.argumentsOnePerLine, text: $model.argumentsText, axis: .vertical)
                            .lineLimit(3...7)
                        TextField(Constants.variablesToPassOnePerLine, text: $model.environmentText, axis: .vertical)
                            .lineLimit(2...5)
                    } else {
                        TextField(Constants.url, text: $model.draft.url, prompt: Text(Constants.serverURLPlaceholder))
                        TextField(
                            Constants.bearerTokenVariable,
                            text: $model.draft.bearerTokenEnvironmentVariable,
                            prompt: Text(Constants.tokenVariablePlaceholder)
                        )
                    }
                }

                if !model.preparedDraft.validationIssues.isEmpty {
                    Section(Constants.needsFixing) {
                        ForEach(model.preparedDraft.validationIssues, id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(Constants.cancel, role: .cancel) { dismiss() }
                Spacer()
                Button(Constants.save) {
                    onSave(model.preparedDraft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.preparedDraft.isValid)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
    }

}

private extension ServerEditorView {
    enum Constants {
        static let identity = String(localized: "Identité", table: "Localizable")
        static let name = String(localized: "Nom", table: "Localizable")
        static let serverNamePlaceholder = String(localized: "ex. GitHub", table: "Localizable")
        static let scope = String(localized: "Portée", table: "Localizable")
        static let enabled = String(localized: "Activé", table: "Localizable")
        static let transport = String(localized: "Transport", table: "Localizable")
        static let type = String(localized: "Type", table: "Localizable")
        static let command = String(localized: "Commande", table: "Localizable")
        static let argumentsOnePerLine = String(localized: "Arguments — un par ligne", table: "Localizable")
        static let variablesToPassOnePerLine = String(localized: "Variables à transmettre — une par ligne", table: "Localizable")
        static let url = String(localized: "URL", table: "Localizable")
        static let bearerTokenVariable = String(localized: "Variable du bearer token", table: "Localizable")
        static let needsFixing = String(localized: "À corriger", table: "Localizable")
        static let cancel = String(localized: "Annuler", table: "Localizable")
        static let save = String(localized: "Enregistrer", table: "Localizable")
        static let npx = String(localized: "npx", table: "Localizable")
        static let serverURLPlaceholder = String(localized: "https://example.com/mcp", table: "Localizable")
        static let tokenVariablePlaceholder = String(localized: "MCP_API_TOKEN", table: "Localizable")
    }
}
