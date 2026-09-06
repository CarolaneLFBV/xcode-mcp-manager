import SwiftUI

struct MCPCatalogView: View {
    let servers: [MCPServer]
    let inventory: XcodeInventory
    let targets: [UUID: [XcodeInstallationTarget]]
    let isLoadingInventory: Bool
    @Binding var filters: MCPCatalogFilters
    let onPrepare: (MCPCatalogRecipe) -> Void
    let onOpen: (MCPCatalogMatch) -> Void
    let onDelete: (MCPServer) -> Void
    let onAdd: () -> Void
    @StateObject private var model = CatalogViewModel()

    private var recipes: [MCPCatalogRecipe] {
        MCPCatalogModel.filter(model.catalog?.recipes ?? [], filters: filters, servers: servers, inventory: inventory)
    }
    private var personal: [MCPServer] { MCPSidebarModel.catalog(servers, query: filters.query) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Label(Constants.mcpWorkspace, systemImage: "square.stack.3d.up")
                            .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        Button(Constants.createAConfiguration, systemImage: "plus", action: onAdd)
                            .mcpActionStyle().controlSize(.large)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Constants.aLittleMorePowerForXcode)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text(Constants.catalogSubtitle)
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                }
                HStack {
                    Picker(Constants.catalogContent, selection: $filters.section) {
                        ForEach(MCPCatalogSection.allCases) { section in Text(section.title).tag(section) }
                    }.pickerStyle(.segmented).labelsHidden()
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: 360, alignment: .leading)
                    Spacer()
                    Text(filters.section == .discover ? Constants.recommendationCount(recipes.count) : Constants.configurationCount(personal.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if filters.section == .discover {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            categoryPicker
                            Spacer()
                            missingToggle
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            categoryPicker
                            missingToggle
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Label(Constants.catalogPurposeDescription, systemImage: "sparkle")
                        .font(.callout).foregroundStyle(.secondary)
                    if isLoadingInventory { ProgressView(Constants.checkingExistingConfigurations).controlSize(.small) }
                    if !inventory.errors.isEmpty {
                        Label(Constants.incompleteInventoryWarning, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if let failure = model.failure {
                        ContentUnavailableView(Constants.catalogUnavailable, systemImage: "exclamationmark.triangle", description: Text(failure))
                    } else if model.catalog == nil {
                        ProgressView(Constants.loadingTheBundledCatalog)
                    } else if recipes.isEmpty {
                        emptyResults
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), alignment: .top)], alignment: .leading, spacing: 18) {
                            ForEach(recipes) { recipe in
                                MCPCatalogCard(recipe: recipe, matches: MCPCatalogModel.matches(recipe, servers: servers, inventory: inventory),
                                    isLoadingInventory: isLoadingInventory, onPrepare: { onPrepare(recipe) }, onOpen: onOpen)
                            }
                        }
                    }
                    if let catalog = model.catalog {
                        Text(Constants.editorialReview(catalog.reviewedAt))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(Constants.personalConfigurationsDescription)
                        .font(.callout).foregroundStyle(.secondary)
                    if personal.isEmpty {
                        if servers.isEmpty {
                            ContentUnavailableView {
                                Label(Constants.noPersonalConfigurations, systemImage: "tray")
                            } description: {
                                Text(Constants.emptyConfigurationsDescription)
                            } actions: {
                                Button(Constants.discoverMcpServers) { filters.section = .discover; filters.query = "" }
                            }
                        } else { emptyResults }
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(personal) { server in
                                HStack(spacing: 14) {
                                    Image(systemName: server.transport == .stdio ? "terminal" : "network")
                                        .font(.system(size: 18, weight: .medium))
                                        .frame(width: 44, height: 44)
                                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(server.name).font(.headline)
                                        Text(server.transport.title + (server.enabled ? "" : Constants.testsDisabled))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let statuses = targets[server.id] {
                                            let configured = statuses.filter(\.isAlreadyConfigured)
                                            Text(configured.isEmpty ? (statuses.contains { $0.detectionError != nil } ? Constants.checkXcodeStatus : Constants.noXcodeConfigurationFound)
                                                : configured.map { "\($0.kind.shortTitle) · \($0.statusTitle)" }.joined(separator: " / "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        } else { Text(Constants.readingXcodeStatus).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Button(Constants.open) { onOpen(.init(server: server, mode: .catalog, location: Constants.personalConfiguration)) }
                                        .mcpActionStyle()
                                    Menu(Constants.actions, systemImage: "ellipsis") {
                                        Button(Constants.removeFromManager, role: .destructive) { onDelete(server) }
                                    }.labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                                }.padding(20).mcpCard()
                            }
                        }
                    }
                }
            }.padding(32).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            searchBar
                .frame(maxWidth: 360, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 32).padding(.vertical, 8)
                .frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .background { MCPCanvas() }
        .navigationTitle(Constants.catalog)
        .task { model.loadIfNeeded() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField(filters.section == .discover ? Constants.searchForAToolOrUseCase : Constants.searchMyConfigurations, text: $filters.query)
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(Constants.searchTheCatalog)
            if !filters.query.isEmpty {
                Button(Constants.clearSearch, systemImage: "xmark.circle.fill") { filters.query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.primary.opacity(0.035), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }

    private var categoryPicker: some View {
        HStack(spacing: 10) {
            Text(Constants.category)
            Picker(Constants.category, selection: $filters.category) {
                Text(Constants.all).tag("Toutes")
                ForEach(Array(Set(model.catalog?.recipes.map(\.category) ?? [])).sorted(), id: \.self) { Text(Bundle.main.localizedString(forKey: $0, value: $0, table: nil)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 180, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: 270, alignment: .leading)
    }

    private var missingToggle: some View {
        Toggle(Constants.onlyUndiscovered, isOn: $filters.onlyMissing)
            .toggleStyle(.switch).controlSize(.small).fixedSize()
            .help(Constants.missingServicesFilterHint)
    }

    private var emptyResults: some View {
        ContentUnavailableView {
            Label(Constants.noResults, systemImage: "magnifyingglass")
        } description: { Text(Constants.tryAnotherSearchTermOrBroadenTheFilters) }
        actions: {
            Button(Constants.resetFilters) { filters.query = ""; filters.category = "Toutes"; filters.onlyMissing = false }
        }
    }
}

private extension MCPCatalogView {
    enum Constants {
        static func recommendationCount(_ count: Int) -> String {
            String(localized: "\(count) recommandations", table: "Localizable")
        }

        static func configurationCount(_ count: Int) -> String {
            String(localized: "\(count) configurations", table: "Localizable")
        }

        static func editorialReview(_ date: String) -> String {
            String(localized: "Sélection éditoriale embarquée · sources consultées le \(date). Pas de synchronisation distante ni de classement de popularité. Présence dans une configuration ≠ connexion vérifiée.", table: "Localizable")
        }

        static let mcpWorkspace = String(localized: "ESPACE MCP", table: "Localizable")
        static let createAConfiguration = String(localized: "Créer une configuration", table: "Localizable")
        static let aLittleMorePowerForXcode = String(localized: "Un peu plus de pouvoir pour Xcode.", table: "Localizable")
        static let catalogSubtitle = String(localized: "Découvrez les bons outils. Retrouvez vos configurations. Tout commence ici.", table: "Localizable")
        static let catalogContent = String(localized: "Contenu du catalogue", table: "Localizable")
        static let catalogPurposeDescription = String(localized: "Des compléments aux outils de build et de test déjà fournis par Xcode.", table: "Localizable")
        static let checkingExistingConfigurations = String(localized: "Vérification des configurations déjà présentes…", table: "Localizable")
        static let incompleteInventoryWarning = String(localized: "L’inventaire est incomplet : certains services peuvent ne pas être reconnus. Consultez les alertes dans la barre latérale.", table: "Localizable")
        static let catalogUnavailable = String(localized: "Catalogue indisponible", table: "Localizable")
        static let loadingTheBundledCatalog = String(localized: "Chargement du catalogue embarqué…", table: "Localizable")
        static let personalConfigurationsDescription = String(localized: "Ces définitions sont enregistrées dans le Manager. Elles ne sont pas nécessairement installées dans Xcode.", table: "Localizable")
        static let noPersonalConfigurations = String(localized: "Aucune configuration personnelle", table: "Localizable")
        static let emptyConfigurationsDescription = String(localized: "Préparez un ajout depuis Découvrir, créez une configuration ou importez-en une depuis ce Mac.", table: "Localizable")
        static let discoverMcpServers = String(localized: "Découvrir les MCP", table: "Localizable")
        static let testsDisabled = String(localized: " · tests désactivés", table: "Localizable")
        static let checkXcodeStatus = String(localized: "État Xcode à vérifier", table: "Localizable")
        static let noXcodeConfigurationFound = String(localized: "Pas de configuration Xcode détectée", table: "Localizable")
        static let readingXcodeStatus = String(localized: "Lecture de l’état Xcode…", table: "Localizable")
        static let open = String(localized: "Ouvrir", table: "Localizable")
        static let personalConfiguration = String(localized: "Configuration personnelle", table: "Localizable")
        static let actions = String(localized: "Actions", table: "Localizable")
        static let removeFromManager = String(localized: "Retirer du Manager", table: "Localizable")
        static let catalog = String(localized: "Catalogue", table: "Localizable")
        static let searchForAToolOrUseCase = String(localized: "Rechercher un outil ou un usage…", table: "Localizable")
        static let searchMyConfigurations = String(localized: "Rechercher dans mes configurations…", table: "Localizable")
        static let searchTheCatalog = String(localized: "Rechercher dans le catalogue", table: "Localizable")
        static let clearSearch = String(localized: "Effacer la recherche", table: "Localizable")
        static let category = String(localized: "Catégorie", table: "Localizable")
        static let onlyUndiscovered = String(localized: "À découvrir uniquement", table: "Localizable")
        static let missingServicesFilterHint = String(localized: "Masque les services reconnus dans Xcode ou dans vos configurations personnelles.", table: "Localizable")
        static let noResults = String(localized: "Aucun résultat", table: "Localizable")
        static let tryAnotherSearchTermOrBroadenTheFilters = String(localized: "Essayez un autre terme ou élargissez les filtres.", table: "Localizable")
        static let resetFilters = String(localized: "Réinitialiser les filtres", table: "Localizable")
        static let all = String(localized: "Toutes", table: "Localizable")
    }
}
