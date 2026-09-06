import SwiftUI

struct LocalMCPDiscoveryView: View {
    let result: LocalMCPScanResult
    let existingServers: [MCPServer]
    let onImport: ([DiscoveredMCPServer]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []

    private var existingSignatures: Set<String> {
        Set(existingServers.map(\.discoverySignature))
    }

    private var selectedDiscoveries: [DiscoveredMCPServer] {
        result.discoveries.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if result.discoveries.isEmpty {
                    ContentUnavailableView {
                        Label(Constants.noMcpServersFound, systemImage: "magnifyingglass")
                    } description: {
                        Text(Constants.inspectedLocations(result.inspectedLocations))
                    }
                } else {
                    List(result.discoveries) { discovery in
                        discoveryRow(discovery)
                    }
                }
            }
            .navigationTitle(Constants.mcpServersFoundOnThisMac)
            .frame(minWidth: 680, minHeight: 470)
            .safeAreaInset(edge: .bottom) {
                if !result.unreadableLocations.isEmpty {
                    Label(
                        "\(result.unreadableLocations.count) configuration(s) n’ont pas pu être lues.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Constants.close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importButtonTitle) { onImport(selectedDiscoveries) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedDiscoveries.isEmpty)
                }
            }
            .onAppear {
                selection = Set(result.discoveries.compactMap { discovery in
                    existingSignatures.contains(discovery.server.discoverySignature) ? nil : discovery.id
                })
            }
        }
    }

    private var importButtonTitle: String {
        let count = selectedDiscoveries.count
        return count == 0 ? Constants.importServers : Constants.importSelection(count)
    }

    private func discoveryRow(_ discovery: DiscoveredMCPServer) -> some View {
        let alreadyImported = existingSignatures.contains(discovery.server.discoverySignature)
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selection.contains(discovery.id) },
                set: { selected in
                    if selected { selection.insert(discovery.id) }
                    else { selection.remove(discovery.id) }
                }
            ))
            .labelsHidden()
            .disabled(alreadyImported)

            Image(systemName: discovery.server.transport == .stdio ? "terminal" : "network")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(discovery.server.name)
                        .font(.headline)
                    if alreadyImported {
                        Text(Constants.alreadyImported)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Text(connectionDescription(discovery.server))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                ForEach(discovery.sources) { source in
                    Label("\(source.kind.title) · \(source.location)", systemImage: source.kind.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(discovery.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 7)
    }

    private func connectionDescription(_ server: MCPServer) -> String {
        switch server.transport {
        case .stdio: ([server.command] + server.arguments).joined(separator: " ")
        case .streamableHTTP: server.url
        }
    }
}

private extension LocalMCPDiscoveryView {
    enum Constants {
        static func inspectedLocations(_ count: Int) -> String {
            String(localized: "\(count) emplacements et outils système ont été vérifiés.", table: "Localizable")
        }

        static func importSelection(_ count: Int) -> String {
            String(localized: "Importer (\(count))", table: "Localizable")
        }

        static let noMcpServersFound = String(localized: "Aucun MCP détecté", table: "Localizable")
        static let mcpServersFoundOnThisMac = String(localized: "MCP détectés sur ce Mac", table: "Localizable")
        static let close = String(localized: "Fermer", table: "Localizable")
        static let importServers = String(localized: "Importer", table: "Localizable")
        static let alreadyImported = String(localized: "Déjà importé", table: "Localizable")
    }
}
