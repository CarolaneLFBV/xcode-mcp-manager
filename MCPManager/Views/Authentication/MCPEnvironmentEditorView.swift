import SwiftUI

/// Renders a secret draft; persistence and validation belong to the view model.
struct MCPEnvironmentEditorView: View {
    let server: MCPServer
    let onSaved: (MCPServer) -> Void
    @StateObject private var model: EnvironmentEditorViewModel
    @Environment(\.dismiss) private var dismiss

    init(server: MCPServer, onSaved: @escaping (MCPServer) -> Void) {
        self.server = server
        self.onSaved = onSaved
        _model = StateObject(wrappedValue: EnvironmentEditorViewModel(server: server))
    }

    private func saveDraft() {
        Task {
            if let saved = await model.save() {
                onSaved(saved)
                dismiss()
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(Constants.server, value: server.name)
                    LabeledContent(Constants.scopeOfThisSave, value: model.scope)
                    Text(Constants.secretStorageDescription)
                        .font(.callout).foregroundStyle(.secondary)
                    if model.isProject {
                        Label(Constants.readOnlyProjectDescription, systemImage: "folder")
                    } else if model.isHTTP {
                        Label(Constants.httpTokenDescription, systemImage: "info.circle")
                    } else {
                        Text(Constants.applyEnvironmentDescription)
                            .font(.callout)
                    }
                }
                Section(model.isHTTP ? Constants.authenticationToken : Constants.serverVariables) {
                    ForEach($model.drafts) { $draft in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField(Constants.variableNamePlaceholder, text: $draft.name)
                                    .textFieldStyle(.roundedBorder)
                                if !model.isHTTP {
                                    Toggle(Constants.secret, isOn: $draft.isSecret).toggleStyle(.checkbox)
                                    Button(Constants.removeFromThisProfile, systemImage: "minus.circle", role: .destructive) {
                                        model.drafts.removeAll { $0.id == draft.id }
                                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                            }
                            if draft.isSecret {
                                SecureField(draft.wasStored ? Constants.leaveEmptyToKeepTheSavedSecret : Constants.secretValue, text: $draft.value)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField(Constants.value, text: $draft.value).textFieldStyle(.roundedBorder)
                            }
                            Text(draft.wasStored && draft.isSecret && draft.value.isEmpty ? Constants.savedInKeychainAccessNeedsChecking : Constants.notSavedYet)
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                    if !model.isHTTP {
                        Button(Constants.addAVariable, systemImage: "plus") { model.drafts.append(MCPEnvironmentDraft(name: "")) }
                    }
                    if model.drafts.isEmpty {
                        Text(Constants.emptyVariablesDescription)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(Constants.profileVersioningDescription)
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    if model.isSaving { ProgressView(Constants.savingToKeychain) }
                }
            }
            .formStyle(.grouped)
            .disabled(model.isSaving)
            .navigationTitle(Constants.variablesAndSecrets)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Constants.cancel) { dismiss() }.disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Constants.saveToCatalog, action: saveDraft).disabled(model.isSaving || !model.didLoad)
                }
            }
        }
        .frame(minWidth: 690, minHeight: 560)
        .interactiveDismissDisabled(model.isSaving)
        .task { model.loadIfNeeded() }
        .onDisappear { model.discard() }
    }
}

private extension MCPEnvironmentEditorView {
    enum Constants {
        static let server = String(localized: "Serveur", table: "Localizable")
        static let scopeOfThisSave = String(localized: "Portée de cette sauvegarde", table: "Localizable")
        static let secretStorageDescription = String(localized: "Les valeurs secrètes sont stockées dans le Trousseau de ce Mac. Les variables ordinaires sont enregistrées dans un fichier privé. Aucun secret n’est placé dans les arguments du lanceur.", table: "Localizable")
        static let readOnlyProjectDescription = String(localized: "Projet en lecture seule : ces valeurs serviront uniquement aux tests locaux. Le fichier du projet ne sera pas modifié.", table: "Localizable")
        static let httpTokenDescription = String(localized: "Token HTTP : tests locaux uniquement, en HTTPS. Pour Sentry OAuth, utilisez la rubrique Connexion OAuth sans profil de token manuel. La transmission HTTP à Xcode n’est pas disponible.", table: "Localizable")
        static let applyEnvironmentDescription = String(localized: "Après enregistrement, choisissez Installer / Mettre à jour globalement pour appliquer ces variables à un agent Xcode. Une copie indépendante sera créée pour cet agent.", table: "Localizable")
        static let authenticationToken = String(localized: "Token d’authentification", table: "Localizable")
        static let serverVariables = String(localized: "Variables du serveur", table: "Localizable")
        static let variableNamePlaceholder = String(localized: "Nom, ex. API_TOKEN", table: "Localizable")
        static let secret = String(localized: "Secret", table: "Localizable")
        static let removeFromThisProfile = String(localized: "Retirer de ce profil", table: "Localizable")
        static let leaveEmptyToKeepTheSavedSecret = String(localized: "Laisser vide pour conserver le secret enregistré", table: "Localizable")
        static let secretValue = String(localized: "Valeur secrète", table: "Localizable")
        static let value = String(localized: "Valeur", table: "Localizable")
        static let savedInKeychainAccessNeedsChecking = String(localized: "Enregistrée dans le Trousseau · accès à vérifier", table: "Localizable")
        static let notSavedYet = String(localized: "À enregistrer", table: "Localizable")
        static let addAVariable = String(localized: "Ajouter une variable", table: "Localizable")
        static let emptyVariablesDescription = String(localized: "Ajoutez les variables attendues par le serveur. Ne collez pas vos clés dans sa commande ou ses arguments.", table: "Localizable")
        static let profileVersioningDescription = String(localized: "Retirer ou remplacer une variable crée une nouvelle version. Les anciens profils restent conservés pour les installations existantes et leur restauration ; ceci ne révoque pas une clé auprès de son fournisseur.", table: "Localizable")
        static let savingToKeychain = String(localized: "Enregistrement dans le Trousseau…", table: "Localizable")
        static let variablesAndSecrets = String(localized: "Variables et secrets", table: "Localizable")
        static let cancel = String(localized: "Annuler", table: "Localizable")
        static let saveToCatalog = String(localized: "Enregistrer au catalogue", table: "Localizable")
    }
}
