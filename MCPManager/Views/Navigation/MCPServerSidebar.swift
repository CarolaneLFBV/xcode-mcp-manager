import AppKit
import SwiftUI

struct MCPServerSidebar: View {
    @Binding var selection: UUID?
    @Binding var mode: MCPSidebarMode
    let inventory: XcodeInventory
    @ObservedObject var supervisor: MCPProcessSupervisor
    let onAdd: () -> Void
    let onAddProject: () -> Void

    @State private var query = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var showingDiagnostics = false

    private var groups: [MCPSidebarGroup] { MCPSidebarModel.groups(in: inventory, query: query) }
    private var visibleCount: Int { groups.reduce(0) { $0 + $1.entries.count } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(MCPSidebarMode.allCases) { item in
                    MCPNavigationButton(
                        title: item == .xcode ? Constants.myXcodeMcpServers : Constants.catalog,
                        symbol: item == .xcode ? "hammer" : "square.grid.2x2",
                        isSelected: mode == item
                    ) {
                        mode = item
                    }
                }
                Text(Constants.xcodeConfigurations).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 8)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(Constants.serverProjectOrAgent, text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel(Constants.searchXcodeConfigurations)
                    if !query.isEmpty {
                        Button(Constants.clearSearch, systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.primary.opacity(0.045), in: Capsule())
            }
            .padding(14)

            List(selection: Binding<UUID?>(get: { mode == .xcode ? selection : nil }, set: { id in
                guard let id else { return }
                mode = .xcode
                selection = id
            })) {
                    ForEach(groups) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { !query.isEmpty || !collapsedGroups.contains(group.id) },
                            set: { expanded in
                                if expanded { collapsedGroups.remove(group.id) }
                                else { collapsedGroups.insert(group.id) }
                            }
                        )) {
                            ForEach(group.entries) { entry in
                                ServerRow(server: entry.server, status: supervisor.status(for: entry.server),
                                    targets: [entry.target], inXcode: true)
                                    .tag(entry.id)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: group.symbol).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title).fontWeight(.medium).lineLimit(1)
                                    if let location = group.location, groups.filter({ $0.title == group.title }).count > 1 {
                                        Text(URL(fileURLWithPath: location).deletingLastPathComponent().path)
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text("\(group.entries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .help(group.location ?? Constants.globalXcodeAgentConfigurations)
                            .accessibilityLabel(Text(verbatim: "\(group.title), \(Constants.serverCount(group.entries.count))"))
                        }
                    }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if visibleCount == 0 {
                    VStack(spacing: 10) {
                        Image(systemName: query.isEmpty ? "server.rack" : "magnifyingglass")
                            .font(.title2).foregroundStyle(.secondary)
                        Text(query.isEmpty ? Constants.noMcpServersFound : Constants.noResults)
                            .font(.headline)
                        if query.isEmpty {
                            Text(Constants.addAServerOrAProjectFolder)
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button(Constants.addAServer, action: onAdd)
                            Button(Constants.chooseAProject, action: onAddProject)
                        } else {
                            Button(Constants.clearSearch) { query = "" }
                        }
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary).font(.caption)
                Text(Constants.xcodeServerCount(visibleCount))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !inventory.errors.isEmpty {
                    Button {
                        showingDiagnostics = true
                    } label: {
                        Label(Constants.alertCount(inventory.errors.count), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }.buttonStyle(.plain)
                    .popover(isPresented: $showingDiagnostics) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(Constants.xcodeDiagnostics).font(.headline)
                                ForEach(Array(inventory.errors.enumerated()), id: \.offset) { _, error in
                                    Text(error).font(.callout).textSelection(.enabled)
                                }
                            }.padding(20)
                        }.frame(width: 420, height: 260)
                    }
                }
            }.padding(.horizontal, 18).padding(.vertical, 16)
        }
    }
}

private extension MCPServerSidebar {
    enum Constants {
        static func serverCount(_ count: Int) -> String {
            String(localized: "\(count) serveurs", table: "Localizable")
        }

        static func xcodeServerCount(_ count: Int) -> String {
            String(localized: "\(count) MCP Xcode", table: "Localizable")
        }

        static func alertCount(_ count: Int) -> String {
            String(localized: "\(count) alertes", table: "Localizable")
        }

        static let myXcodeMcpServers = String(localized: "Mes MCP Xcode", table: "Localizable")
        static let catalog = String(localized: "Catalogue", table: "Localizable")
        static let xcodeConfigurations = String(localized: "Configurations Xcode", table: "Localizable")
        static let serverProjectOrAgent = String(localized: "Serveur, projet ou agent", table: "Localizable")
        static let searchXcodeConfigurations = String(localized: "Rechercher dans les configurations Xcode", table: "Localizable")
        static let clearSearch = String(localized: "Effacer la recherche", table: "Localizable")
        static let globalXcodeAgentConfigurations = String(localized: "Configurations globales des agents Xcode", table: "Localizable")
        static let noMcpServersFound = String(localized: "Aucun MCP détecté", table: "Localizable")
        static let noResults = String(localized: "Aucun résultat", table: "Localizable")
        static let addAServerOrAProjectFolder = String(localized: "Ajoutez un serveur ou un dossier de projet.", table: "Localizable")
        static let addAServer = String(localized: "Ajouter un serveur", table: "Localizable")
        static let chooseAProject = String(localized: "Choisir un projet…", table: "Localizable")
        static let xcodeDiagnostics = String(localized: "Diagnostic Xcode", table: "Localizable")
    }
}
