import Foundation

struct MCPCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let reviewedAt: String
    let recipes: [MCPCatalogRecipe]

    static func load(bundle: Bundle = .main) throws -> MCPCatalog {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json") else { throw CatalogError.unavailable }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> MCPCatalog {
        guard data.count <= 1_000_000 else { throw CatalogError.invalid }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, !catalog.recipes.isEmpty, catalog.recipes.count <= 100,
              Set(catalog.recipes.map(\.id)).count == catalog.recipes.count,
              catalog.recipes.allSatisfy({ recipe in
                  !recipe.id.isEmpty && !recipe.name.isEmpty && !recipe.category.isEmpty && recipe.makeDraft().isValid
                      && recipe.sourceURL.scheme == "https" && recipe.sourceURL.host != nil
                      && recipe.sourceURL.user == nil && recipe.sourceURL.password == nil
              }) else { throw CatalogError.invalid }
        return catalog
    }

    enum CatalogError: LocalizedError {
        case unavailable, invalid
        var errorDescription: String? { String(localized: "Le catalogue embarqué est indisponible ou invalide. Vos configurations personnelles restent accessibles.") }
    }
}

struct MCPCatalogRecipe: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let publisher: String
    let official: Bool?
    let iconAsset: String?
    let category: String
    let symbol: String
    let summary: String
    let xcodeUse: String
    let authentication: String
    let requirements: String
    let caution: String
    let sourceURL: URL
    let transport: MCPServer.Transport
    let command: String
    let arguments: [String]
    let environmentNames: [String]
    let url: String
    let bearerVariable: String

    /// Translate bundled editorial text only. Connection fields and stable category
    /// identities remain untouched so changing language never changes a recipe.
    func localizedText(_ field: KeyPath<Self, String>, bundle: Bundle = .main) -> String {
        let source = self[keyPath: field]
        return bundle.localizedString(forKey: source, value: source, table: nil)
    }

    var displayCategory: String { localizedText(\.category) }
    var displaySummary: String { localizedText(\.summary) }
    var displayUse: String { localizedText(\.xcodeUse) }
    var displayAuthentication: String { localizedText(\.authentication) }
    var displayRequirements: String { localizedText(\.requirements) }
    var displayCaution: String { localizedText(\.caution) }

    func makeDraft() -> MCPServer {
        MCPServer(name: name, transport: transport, command: command, arguments: arguments,
            environmentVariableNames: environmentNames, url: url, bearerTokenEnvironmentVariable: bearerVariable)
    }

    /// Provider-level presence, not proof of equal permissions, authentication or connectivity.
    func recognizes(_ server: MCPServer) -> Bool {
        if server.transport == .streamableHTTP, let url = URL(string: server.url),
           url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
           url.port == nil || url.port == 443 {
            let host = url.host?.lowercased()
            let path = url.path
            switch id {
            case "revenuecat": return host == "mcp.revenuecat.ai" && (path == "/mcp" || path == "/mcp/")
            case "supabase": return host == "mcp.supabase.com" && (path == "/mcp" || path == "/mcp/")
            case "linear": return host == "mcp.linear.app" && ["/mcp", "/mcp/", "/mcp/readonly"].contains(path)
            case "sentry": return host == "mcp.sentry.dev" && (path == "/mcp" || path.hasPrefix("/mcp/"))
            case "github": return host == "api.githubcopilot.com" && (path == "/mcp" || path.hasPrefix("/mcp/"))
            case "context7": return host == "mcp.context7.com" && (path == "/mcp" || path == "/mcp/")
            case "figma": return host == "mcp.figma.com" && (path == "/mcp" || path == "/mcp/")
            default: return false
            }
        }
        guard server.transport == .stdio else { return false }
        let executable = URL(fileURLWithPath: server.command).lastPathComponent
        func package(_ value: String, _ base: String) -> Bool {
            value == base || value.hasPrefix(base + "@") || value.hasPrefix(base + ":")
        }
        if id == "github" {
            return executable == "github-mcp-server" || (executable == "docker" && server.arguments.contains("run")
                && server.arguments.contains { package($0, "ghcr.io/github/github-mcp-server") })
                || (["npx", "bunx"].contains(executable) && server.arguments.contains { package($0, "@modelcontextprotocol/server-github") })
        }
        if id == "context7" {
            return ["npx", "bunx"].contains(executable) && server.arguments.contains { package($0, "@upstash/context7-mcp") }
        }
        if id == "firebase" {
            return (executable == "firebase" && server.arguments.first == "mcp")
                || (["npx", "bunx"].contains(executable) && server.arguments.contains("mcp")
                    && server.arguments.contains { $0 == "firebase-tools" || $0.hasPrefix("firebase-tools@") })
        }
        return false
    }
}

enum MCPCatalogSection: String, CaseIterable, Identifiable {
    case discover, personal
    var id: Self { self }
    var title: String { self == .discover ? String(localized: "Découvrir") : String(localized: "Mes configurations") }
}

struct MCPCatalogFilters {
    var section: MCPCatalogSection = .discover
    var query = ""
    var category = "Toutes"
    var onlyMissing = false
}

struct MCPCatalogMatch: Identifiable {
    let server: MCPServer
    let mode: MCPSidebarMode
    let location: String
    var id: String { mode.rawValue + ":" + server.id.uuidString }
}

enum MCPCatalogModel {
    static func matches(_ recipe: MCPCatalogRecipe, servers: [MCPServer], inventory: XcodeInventory) -> [MCPCatalogMatch] {
        let installed = inventory.entries.filter { recipe.recognizes($0.server) }.map {
            MCPCatalogMatch(server: $0.server, mode: .xcode,
                location: "\($0.target.kind.shortTitle) · \($0.target.scopeTitle)\($0.target.isDisabled ? String(localized: " · désactivé") : "")")
        }
        let personal = servers.filter(recipe.recognizes).map {
            MCPCatalogMatch(server: $0, mode: .catalog, location: String(localized: "Configuration personnelle"))
        }
        return installed + personal
    }

    static func filter(_ recipes: [MCPCatalogRecipe], filters: MCPCatalogFilters, servers: [MCPServer], inventory: XcodeInventory) -> [MCPCatalogRecipe] {
        recipes.filter { recipe in
            (filters.category == "Toutes" || recipe.category == filters.category)
                && (!filters.onlyMissing || matches(recipe, servers: servers, inventory: inventory).isEmpty)
                && filters.query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
                    [recipe.name, recipe.publisher, recipe.category, recipe.summary, recipe.xcodeUse, recipe.authentication,
                     recipe.displayCategory, recipe.displaySummary, recipe.displayUse, recipe.displayAuthentication]
                        .contains { $0.localizedStandardContains(String(word)) }
                }
        }
    }
}
