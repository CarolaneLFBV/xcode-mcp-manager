import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum MCPLocalCredentialScenarios {
    static func run() throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appending(path: "MCPManager-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tomlURL = root.appending(path: "config.toml")
        let jsonURL = root.appending(path: "config.json")
        let parser = LocalMCPDiscoveryService(includeDeveloperTools: false)
        let resolver = MCPLocalCredentialResolver(inherited: ["FROM_PROCESS": "inherited-fixture", "UNRELATED": "do-not-use"])
        let toml = """
        [mcp_servers.local]
        command = "/usr/bin/true"
        [mcp_servers.local.env]
        TOKEN = "source-fixture-token"
        TEXT = 'commas, equals= and # inside value'
        [mcp_servers.other.env]
        WRONG_TOKEN = "not-this-server"
        [mcp_servers.remote]
        url = "https://example.com/mcp"
        http_headers = { Authorization = "Bearer source-fixture-token", 'X-Region' = 'eu,west' }
        env_http_headers = { 'X-Extra' = 'FROM_PROCESS' }
        [mcp_servers.sentry]
        url = "https://example.com/oauth"
        auth = "oauth"
        """
        try Data(toml.utf8).write(to: tomlURL)
        let source = MCPDiscoverySource(kind: .xcodeCodex, location: tomlURL.path)
        let entries = try parser.parseCodexConfiguration(Data(toml.utf8), source: source).map(\.server)
        let local = entries.first { $0.name == "local" }!
        let values = try resolver.resolve(local)
        try XcodeManagementScenarios.check(values.environment["TOKEN"] == "source-fixture-token", "Exact source env recovered")
        try XcodeManagementScenarios.check(values.environment["TEXT"] == "commas, equals= and # inside value", "Literal punctuation preserved")
        try XcodeManagementScenarios.check(values.environment["WRONG_TOKEN"] == nil && values.environment["UNRELATED"] == nil, "Other server and ambient credentials isolated")
        let encoded = try JSONEncoder().encode(local)
        try XcodeManagementScenarios.check(!String(decoding: encoded, as: UTF8.self).contains("source-fixture-token"), "Catalogue contains source reference, no secret")
        let remote = entries.first { $0.name == "remote" }!
        let headers = try resolver.resolve(remote).headers
        try XcodeManagementScenarios.check(headers["Authorization"] == "Bearer source-fixture-token" && headers["X-Region"] == "eu,west" && headers["X-Extra"] == "inherited-fixture", "TOML inline headers and env header references recovered")

        let json: [String: Any] = ["mcpServers": ["remote": ["url": "https://example.com/json", "env": ["TOKEN": "json-fixture-token"], "headers": ["Authorization": "Bearer ${TOKEN}"]]]]
        let jsonData = try JSONSerialization.data(withJSONObject: json)
        try jsonData.write(to: jsonURL)
        let jsonServer = try parser.parseJSONConfiguration(jsonData, source: .init(kind: .claudeCode, location: jsonURL.path))[0].server
        let jsonValues = try resolver.resolve(jsonServer)
        try XcodeManagementScenarios.check(jsonValues.headers["Authorization"] == "Bearer json-fixture-token", "JSON source interpolation without shell")

        let oauthServer = entries.first { $0.name == "sentry" }!
        do { _ = try resolver.resolve(oauthServer); throw XcodeManagementScenarios.Failure(description: "OAuth treated as a missing env token") }
        catch MCPLocalCredentialError.oauth { }
        var changed = remote
        changed.url = "https://different.example/mcp"
        do { _ = try resolver.resolve(changed); throw XcodeManagementScenarios.Failure(description: "Credentials sent to modified endpoint") }
        catch MCPLocalCredentialError.changed { }
        var unbound = remote
        unbound.configurationSource = nil
        try XcodeManagementScenarios.check(try resolver.resolve(unbound, candidates: [remote]).headers["Authorization"] == headers["Authorization"], "Legacy catalogue can match a unique source")
        var duplicate = remote
        duplicate.configurationSource = .init(url: root.appending(path: "another.toml"), name: "remote", format: .toml)
        do { _ = try resolver.resolve(unbound, candidates: [remote, duplicate]); throw XcodeManagementScenarios.Failure(description: "Ambiguous credentials silently chosen") }
        catch MCPLocalCredentialError.ambiguous { }
        for badHeaders in [["Authorization": "Bearer bad\r\ninjection"], ["X-Test\n": "bad"], ["Host": "elsewhere"], ["Authorization": "a", "authorization": "b"]] {
            do { try MCPLocalCredentialResolver.validateHeaders(badHeaders, url: remote.url); throw XcodeManagementScenarios.Failure(description: "Unsafe header accepted") }
            catch MCPLocalCredentialError.unsafeHTTP { }
        }
        do { try MCPLocalCredentialResolver.validateHeaders(headers, url: "http://example.com/mcp"); throw XcodeManagementScenarios.Failure(description: "Credentials accepted over HTTP") }
        catch MCPLocalCredentialError.unsafeHTTP { }
        try XcodeManagementScenarios.check(try Data(contentsOf: tomlURL) == Data(toml.utf8) && Data(contentsOf: jsonURL) == jsonData, "No source file mutation")
        return ["Valeurs env TOML/JSON et en-têtes relus sans persistance ni mélange de serveurs",
                "Diagnostic OAuth explicite, source unique et refus d’une URL modifiée ou ambiguë",
                "En-têtes dangereux et HTTP non chiffré refusés, sources inchangées"]
    }
}
