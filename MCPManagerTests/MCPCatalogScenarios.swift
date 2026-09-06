import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum MCPCatalogScenarios {
    static func run(data: Data) throws -> [String] {
        let check = XcodeManagementScenarios.check
        let catalog = try MCPCatalog.decode(data)
        try check(catalog.recipes.map(\.id) == ["context7", "github", "sentry", "figma", "revenuecat", "firebase", "supabase", "linear"], "Stable official selection")
        for recipe in catalog.recipes {
            try check(recipe.official == true && recipe.iconAsset == "brand-" + recipe.id, "Official provenance and bundled brand icon")
            let first = recipe.makeDraft(), second = recipe.makeDraft()
            try check(first.isValid && first.id != second.id, "Drafts are valid and independent")
            try check(first.xcodeBinding == nil && first.configurationSource == nil && first.environmentProfileID == nil,
                "Recommendations contain no installed binding or secret profile")
            try check(!recipe.requirements.isEmpty && !recipe.caution.isEmpty && recipe.sourceURL.scheme == "https", "Requirements, limits and primary source provided")
            try check(recipe.recognizes(first), "Every recipe recognizes its own connection")
        }
        let github = catalog.recipes.first { $0.id == "github" }!
        try check(github.arguments.contains("GITHUB_READ_ONLY=1") && github.environmentNames == ["GITHUB_PERSONAL_ACCESS_TOKEN"], "GitHub read-only recipe requests a variable name, not a token")
        var wrongVersion = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        wrongVersion["schemaVersion"] = 999
        do { _ = try MCPCatalog.decode(JSONSerialization.data(withJSONObject: wrongVersion)); throw XcodeManagementScenarios.Failure(description: "Unknown schema accepted") }
        catch MCPCatalog.CatalogError.invalid { }
        var duplicate = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let recipes = duplicate["recipes"] as! [[String: Any]]
        duplicate["recipes"] = recipes + [recipes[0]]
        do { _ = try MCPCatalog.decode(JSONSerialization.data(withJSONObject: duplicate)); throw XcodeManagementScenarios.Failure(description: "Duplicate recipe ID accepted") }
        catch MCPCatalog.CatalogError.invalid { }
        var result = ["Catalogue JSON validé, recettes indépendantes, sources et prérequis, schéma inconnu et doublons refusés"]

        let sentry = catalog.recipes.first { $0.id == "sentry" }!
        var alias = sentry.makeDraft(); alias.name = "Observabilité iOS"; alias.url += "/my-org/my-project"
        let target = XcodeInstallationTarget(kind: .codex, configurationURL: URL(fileURLWithPath: "/tmp/catalog-fixture/config.toml"),
            isAvailable: true, isAlreadyConfigured: true, isDisabled: true, projectDirectoryURL: URL(fileURLWithPath: "/tmp/catalog-fixture"))
        let inventory = XcodeInventory(entries: [.init(server: alias, target: target)], errors: [])
        let personal = [sentry.makeDraft()]
        let matches = MCPCatalogModel.matches(sentry, servers: personal, inventory: inventory)
        try check(matches.count == 2 && Set(matches.map(\.id)).count == 2, "Local and project definitions remain distinct")
        try check(matches[0].mode == .xcode && matches[0].location.contains(String(localized: " · désactivé")) && matches[1].mode == .catalog,
            "Exact navigation destination and disabled state retained")
        let imposter = MCPServer(name: "Sentry", transport: .streamableHTTP, url: "https://mcp.sentry.dev.evil.example/mcp")
        try check(!sentry.recognizes(imposter), "Name and lookalike hostname do not count as installed")
        var wrongPath = alias; wrongPath.url = "https://mcp.sentry.dev/mcp-not-sentry"
        try check(!sentry.recognizes(wrongPath), "Path boundary required")
        var docker = github.makeDraft(); docker.arguments[docker.arguments.count - 1] += ":v-test"
        try check(github.recognizes(docker), "Versioned Docker image recognized")
        docker.arguments[docker.arguments.count - 1] = "ghcr.io/github/github-mcp-server-unrelated"
        try check(!github.recognizes(docker), "Different image is not a match")
        let legacyGitHub = MCPServer(name: "Dépôts", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"])
        try check(github.recognizes(legacyGitHub), "Existing legacy GitHub service remains discoverable, without replacing its settings")
        result.append("Présence par service et alias, projet désactivé, séparation Manager/Xcode et refus des faux positifs")

        var filters = MCPCatalogFilters()
        filters.query = "documentation dependances"
        try check(MCPCatalogModel.filter(catalog.recipes, filters: filters, servers: [], inventory: .init()).map(\.id) == ["context7"], "Multiword accent-insensitive search")
        filters.query = ""; filters.category = "Design"
        try check(MCPCatalogModel.filter(catalog.recipes, filters: filters, servers: [], inventory: .init()).map(\.id) == ["figma"], "Category filter")
        filters.category = "Toutes"; filters.onlyMissing = true
        let missing = MCPCatalogModel.filter(catalog.recipes, filters: filters, servers: personal, inventory: inventory)
        try check(missing.count == catalog.recipes.count - 1 && !missing.contains { $0.id == "sentry" }, "Hide known providers, including disabled configurations")
        filters.query = "zzzz-no-match"
        try check(MCPCatalogModel.filter(catalog.recipes, filters: filters, servers: [], inventory: .init()).isEmpty, "Empty search results")
        try check(inventory.entries[0].server.id == alias.id && personal.count == 1, "Filtering and browsing never mutate user configurations")
        result.append("Recherche, catégories et filtre à découvrir sans modification des données utilisateur")
        return result
    }
}
