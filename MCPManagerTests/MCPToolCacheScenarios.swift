import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum MCPToolCacheScenarios {
    @MainActor static func run() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tool-cache-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MCPToolCache(directory: root)
        var server = MCPServer(name: "Fixture", command: "/usr/bin/true")
        let first = [MCPTool(name: "alpha", description: "Description", inputSchema: .object(["type": .string("object")]))]
        let date = Date(timeIntervalSince1970: 1000)
        try cache.save(first, for: server, at: date)
        precondition(MCPToolCache(directory: root).load(for: server)?.tools == first)
        precondition(cache.load(for: server)?.savedAt == date)
        server.name = "Renamed"
        server.updatedAt = .now
        server.enabled = false
        precondition(cache.load(for: server)?.tools == first)
        var changed = server
        changed.command = "/usr/bin/false"
        precondition(cache.load(for: changed) == nil)
        changed = server; changed.environmentProfileID = UUID()
        precondition(cache.load(for: changed) == nil)
        var sourced = server
        sourced.configurationSource = .init(url: root.appending(path: "source.toml"), name: "fixture", format: .toml)
        try cache.save(first, for: sourced)
        sourced.id = UUID()
        precondition(cache.load(for: sourced)?.tools == first)
        var otherSource = sourced
        otherSource.configurationSource = .init(url: root.appending(path: "other.toml"), name: "fixture", format: .toml)
        precondition(cache.load(for: otherSource) == nil)
        try cache.save([], for: server)
        precondition(cache.load(for: server)?.tools == [])
        let url = root.appending(path: MCPToolCache.key(for: server) + ".json")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        precondition(perms?.intValue == 0o600)
        try Data("invalid json".utf8).write(to: url)
        precondition(cache.load(for: server) == nil)
        let supervisor = MCPProcessSupervisor(toolCache: cache)
        supervisor.restoreCachedTools(for: server)
        precondition(supervisor.tools[server.id] == nil)
        print("OK · Cache persistant, date, changement de configuration, liste vide, fichier corrompu et permissions privées")
    }
}
