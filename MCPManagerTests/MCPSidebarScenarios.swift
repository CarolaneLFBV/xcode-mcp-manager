import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum MCPSidebarScenarios {
    static func run() throws -> [String] {
        func entry(_ name: String, kind: XcodeInstallationTarget.Kind = .codex, project: String? = nil) -> XcodeInventoryEntry {
            let directory = project.map { URL(fileURLWithPath: $0, isDirectory: true) }
            return XcodeInventoryEntry(server: MCPServer(name: name, command: "/usr/bin/true"),
                target: XcodeInstallationTarget(kind: kind,
                    configurationURL: URL(fileURLWithPath: (project ?? "/global") + "/config.toml"),
                    isAvailable: true, isAlreadyConfigured: true, projectDirectoryURL: directory))
        }
        let source = [entry("Zulu"), entry("Sentry", project: "/client-b/ExampleApp"),
            entry("Alpha", kind: .claude), entry("Sentry", project: "/client-a/ExampleApp"),
            entry("Database", project: "/client-a/ExampleApp")]
        let inventory = XcodeInventory(entries: source, errors: ["An unreadable project"])
        let groups = MCPSidebarModel.groups(in: inventory, query: "")
        try XcodeManagementScenarios.check(groups.count == 3, "Global and two project groups")
        try XcodeManagementScenarios.check(groups.first?.title == "Globaux", "Global group comes first")
        try XcodeManagementScenarios.check(groups.first?.entries.map(\.server.name) == ["Alpha", "Zulu"], "Alphabetical server order")
        try XcodeManagementScenarios.check(groups[1].location == "/client-a/ExampleApp", "Same-named projects sorted by full path")
        try XcodeManagementScenarios.check(Set(groups.flatMap(\.entries).map(\.id)) == Set(source.map(\.id)), "No entry merged or lost")
        try XcodeManagementScenarios.check(groups.map(\.id) == MCPSidebarModel.groups(in: inventory, query: " ").map(\.id), "Whitespace query matches all")

        let byProject = MCPSidebarModel.groups(in: inventory, query: "exampleapp SENTry")
        try XcodeManagementScenarios.check(byProject.count == 2 && byProject.flatMap(\.entries).count == 2, "Multiword search across project and server, case insensitive")
        let byAgent = MCPSidebarModel.groups(in: inventory, query: "claude")
        try XcodeManagementScenarios.check(byAgent.flatMap(\.entries).map(\.server.name) == ["Alpha"], "Agent search")
        let byPath = MCPSidebarModel.groups(in: inventory, query: "client-a")
        try XcodeManagementScenarios.check(byPath.count == 1 && byPath[0].entries.count == 2, "Path search disambiguates projects")
        try XcodeManagementScenarios.check(MCPSidebarModel.groups(in: inventory, query: "not-found").isEmpty, "No empty groups in results")

        let catalog = [MCPServer(name: "Zulu"), MCPServer(name: "Éléphant"), MCPServer(name: "Sentry")]
        try XcodeManagementScenarios.check(MCPSidebarModel.catalog(catalog, query: "elephant").map(\.name) == ["Éléphant"], "Accent-insensitive catalogue search")
        try XcodeManagementScenarios.check(MCPSidebarModel.catalog(catalog, query: "").map(\.name) == ["Éléphant", "Sentry", "Zulu"], "Catalogue alphabetized independently")
        try XcodeManagementScenarios.check(inventory.entries.map(\.id) == source.map(\.id) && catalog.count == 3, "Presentation does not change underlying data")
        return ["Groupes Global/Projets, tri stable et identités conservées",
            "Recherche par serveur, projet, chemin ou agent et résultats vides",
            "Catalogue séparé, recherche sans accents et données inchangées"]
    }
}
