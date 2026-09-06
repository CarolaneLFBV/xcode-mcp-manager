import AppKit
import SwiftUI

struct MCPCatalogCard: View {
    let recipe: MCPCatalogRecipe
    let matches: [MCPCatalogMatch]
    let isLoadingInventory: Bool
    let onPrepare: () -> Void
    let onOpen: (MCPCatalogMatch) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Group {
                    if let asset = recipe.iconAsset, let icon = NSImage(named: asset) {
                        Image(nsImage: icon).resizable().scaledToFit().padding(9)
                    } else {
                        Image(systemName: recipe.symbol).font(.system(size: 22, weight: .medium))
                    }
                }
                .frame(width: 48, height: 48)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.black.opacity(0.08)))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recipe.name).font(.system(size: 18, weight: .semibold))
                    Text(recipe.publisher + " · " + recipe.displayCategory).font(.caption).foregroundStyle(.secondary)
                    if recipe.official == true {
                        Label(Constants.officialMcp, systemImage: "checkmark.seal")
                            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .help(Constants.officialProviderHint)
                    }
                }
            }
            Text(recipe.displaySummary).font(.body)
            Text(recipe.displayUse).font(.callout).foregroundStyle(.secondary)
            Label(recipe.displayAuthentication, systemImage: "key.horizontal").font(.caption).foregroundStyle(.secondary)
            if !matches.isEmpty {
                Label(matches.contains { $0.mode == .xcode } ? Constants.serviceAlreadyPresentInXcode : Constants.serviceAlreadySavedInManager, systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                Text(Constants.recipeDifferencesHint).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(Constants.requirementsAndLimitations, isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(recipe.displayRequirements)
                    Text(recipe.displayCaution).foregroundStyle(.secondary)
                }.font(.callout).padding(.top, 8)
            }
            Spacer(minLength: 0)
            HStack {
                if matches.isEmpty {
                    Button(Constants.prepareSetup, systemImage: "plus", action: onPrepare)
                        .mcpActionStyle(prominent: true).controlSize(.large).disabled(isLoadingInventory)
                } else {
                    Menu(Constants.viewConfigurations) {
                        ForEach(matches) { match in Button("\(match.server.name) · \(match.location)") { onOpen(match) } }
                        Divider()
                        Button(Constants.prepareAnotherConfiguration, action: onPrepare).disabled(isLoadingInventory)
                    }
                }
                Spacer()
                Link(destination: recipe.sourceURL) {
                    Label(Constants.source, systemImage: "arrow.up.right").font(.caption)
                }.foregroundStyle(.secondary).help(Constants.providerDocumentation)
            }
            Text(Constants.installationConfirmationHint).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .mcpCard(radius: 24)
    }
}

private extension MCPCatalogCard {
    enum Constants {
        static let officialMcp = String(localized: "MCP officiel", table: "Localizable")
        static let officialProviderHint = String(localized: "Publié par le fournisseur. Ne signifie pas que la connexion a été validée dans le Manager.", table: "Localizable")
        static let serviceAlreadyPresentInXcode = String(localized: "Service déjà présent dans Xcode", table: "Localizable")
        static let serviceAlreadySavedInManager = String(localized: "Service déjà enregistré dans le Manager", table: "Localizable")
        static let recipeDifferencesHint = String(localized: "Les réglages et permissions peuvent différer de cette recette.", table: "Localizable")
        static let requirementsAndLimitations = String(localized: "Prérequis et limites", table: "Localizable")
        static let prepareSetup = String(localized: "Préparer l’ajout", table: "Localizable")
        static let viewConfigurations = String(localized: "Voir les configurations", table: "Localizable")
        static let prepareAnotherConfiguration = String(localized: "Préparer une autre configuration", table: "Localizable")
        static let source = String(localized: "Source", table: "Localizable")
        static let providerDocumentation = String(localized: "Documentation du fournisseur", table: "Localizable")
        static let installationConfirmationHint = String(localized: "Aucune installation au clic : la configuration sera à confirmer.", table: "Localizable")
    }
}
