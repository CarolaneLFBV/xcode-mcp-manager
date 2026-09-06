import XCTest
@testable import MCPManager

final class MCPManagerTests: XCTestCase {
    @MainActor func testExitDiagnosticsDrainBeforeFailure() async throws {
        try await MCPExitDiagnosticScenarios.run()
    }
    @MainActor func testToolCachePersistenceAndInvalidation() throws {
        try MCPToolCacheScenarios.run()
    }
    @MainActor func testBridgeInBandErrorFallsBackWithoutLeakingSecrets() async throws {
        try await MCPBridgeScenarios.run()
    }
    private func installationFixture(codex: String = "", claude: String = "{}") throws -> (URL, XcodeMCPInstaller) {
        let root = FileManager.default.temporaryDirectory.appending(path: "MCPManagerTests-\(UUID().uuidString)")
        for directory in ["codex", "ClaudeAgentConfig"] {
            try FileManager.default.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true)
        }
        try Data(codex.utf8).write(to: root.appending(path: "codex/config.toml"))
        try Data(claude.utf8).write(to: root.appending(path: "ClaudeAgentConfig/.claude.json"))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, XcodeMCPInstaller(codingAssistantDirectory: root))
    }

    func testDetectsXcodeAliasAndPreservesItsSettingsOnUpdate() async throws {
        let (root, installer) = try installationFixture(codex: #"""
        model = "test"
        [mcp_servers.xcode-tools] # existing alias
        command = "/usr/bin/xcrun"
        args = ["mcpbridge"]
        enabled = false
        startup_timeout_sec = 45
        [mcp_servers.xcode-tools.env]
        DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
        [mcp_servers.other]
        command = "/usr/bin/true"
        """#)
        let server = MCPServer(name: "Xcode Tools", command: "xcrun", arguments: ["mcpbridge"])
        let target = try XCTUnwrap(installer.detectTargets(for: server).first { $0.kind == .codex })
        XCTAssertTrue(target.isAlreadyConfigured)
        XCTAssertEqual(target.configuredServerName, "xcode-tools")
        XCTAssertTrue(target.isDisabled)
        XCTAssertEqual(target.actionTitle, "Mettre à jour")
        XCTAssertTrue(installer.preview(for: server, target: .codex).contains("[mcp_servers.\"xcode-tools\"]"))
        let receipt = try await installer.install(server, into: target)
        XCTAssertTrue(receipt.replacedExistingEntry)
        let updated = try String(contentsOf: root.appending(path: "codex/config.toml"), encoding: .utf8)
        XCTAssertFalse(updated.contains("[mcp_servers.\"Xcode Tools\"]"))
        XCTAssertTrue(updated.contains("startup_timeout_sec = 45"))
        XCTAssertTrue(updated.contains("[mcp_servers.xcode-tools.env]"))
        XCTAssertTrue(updated.contains("DEVELOPER_DIR = \"/Applications/Xcode.app/Contents/Developer\""))
        XCTAssertTrue(updated.contains("[mcp_servers.other]"))
        XCTAssertFalse(updated.contains("enabled = false"))
    }

    func testInstallationStatusIsPerAgentAndRefreshesAfterInstallation() async throws {
        let (_, installer) = try installationFixture(codex: "[mcp_servers.sample]\ncommand = \"/usr/bin/true\"\n")
        let server = MCPServer(name: "sample", command: "/usr/bin/true")
        let targets = installer.detectTargets(for: server)
        XCTAssertTrue(targets.first { $0.kind == .codex }!.isAlreadyConfigured)
        let claude = try XCTUnwrap(targets.first { $0.kind == .claude })
        XCTAssertFalse(claude.isAlreadyConfigured)
        XCTAssertEqual(claude.actionTitle, "Installer")
        _ = try await installer.install(server, into: claude)
        XCTAssertTrue(installer.detectTargets(for: server).allSatisfy(\.isAlreadyConfigured))
    }

    func testRecognizesResolvedXcodeToolWithoutMatchingUnrelatedExecutable() throws {
        let (root, _) = try installationFixture(codex: "[mcp_servers.xcode-tools]\ncommand = \"/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge\"\nargs = []\n")
        let installer = XcodeMCPInstaller(codingAssistantDirectory: root, developerToolPaths: ["mcpbridge": "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge"])
        let server = MCPServer(name: "Xcode Tools", command: "xcrun", arguments: ["mcpbridge"])
        XCTAssertEqual(installer.detectTargets(for: server).first?.configuredServerName, "xcode-tools")
        let unrelated = MCPServer(name: "Other", command: "/tmp/mcpbridge")
        XCTAssertFalse(installer.detectTargets(for: unrelated).first!.isAlreadyConfigured)
    }

    func testInvalidClaudeConfigurationShowsUnknownAndPreventsOverwrite() async throws {
        let (root, installer) = try installationFixture(claude: #"{"mcpServers": []}"#)
        let server = MCPServer(name: "sample", command: "/usr/bin/true")
        let target = try XCTUnwrap(installer.detectTargets(for: server).first { $0.kind == .claude })
        XCTAssertNotNil(target.detectionError)
        XCTAssertEqual(target.statusTitle, "État à vérifier")
        do {
            _ = try await installer.install(server, into: target)
            XCTFail("Invalid configuration must not be overwritten")
        } catch { }
        XCTAssertEqual(try String(contentsOf: root.appending(path: "ClaudeAgentConfig/.claude.json"), encoding: .utf8), #"{"mcpServers": []}"#)
    }

    func testAmbiguousAliasesDoNotSelectAnArbitraryEntry() throws {
        let (_, installer) = try installationFixture(claude: #"{"mcpServers":{"one":{"url":"https://example.com/mcp"},"two":{"url":"https://example.com/mcp"}}}"#)
        let server = MCPServer(name: "remote", transport: .streamableHTTP, url: "https://example.com/mcp")
        let target = try XCTUnwrap(installer.detectTargets(for: server).first { $0.kind == .claude })
        XCTAssertNotNil(target.detectionError)
        XCTAssertNil(target.configuredServerName)
    }

    func testClaudeAliasUpdatePreservesEnvironmentAndOtherEntries() async throws {
        let (root, installer) = try installationFixture(claude: #"{"theme":"dark","mcpServers":{"alias":{"command":"/usr/bin/true","env":{"SETTING":"keep"}},"other":{"command":"/usr/bin/false"}}}"#)
        let server = MCPServer(name: "Pretty name", command: "/usr/bin/true")
        let target = try XCTUnwrap(installer.detectTargets(for: server).first { $0.kind == .claude })
        XCTAssertEqual(target.configuredServerName, "alias")
        _ = try await installer.install(server, into: target)
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "ClaudeAgentConfig/.claude.json"))) as? [String: Any])
        let entries = try XCTUnwrap(rootJSON["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries["alias"]?["env"] as? [String: String], ["SETTING": "keep"])
        XCTAssertEqual(rootJSON["theme"] as? String, "dark")
    }

    func testNestedCodexTableIsNotAnotherServer() throws {
        let (_, installer) = try installationFixture(codex: "[mcp_servers.'real']\ncommand = \"/usr/bin/true\"\n[mcp_servers.'real'.env]\nSETTING = \"keep\"\n")
        let target = try XCTUnwrap(installer.detectTargets(for: MCPServer(name: "real", command: "/usr/bin/true")).first { $0.kind == .codex })
        XCTAssertNil(target.detectionError)
        XCTAssertTrue(target.isAlreadyConfigured)
    }

    func testSTDIOValidationRequiresCommand() {
        let server = MCPServer(name: "Local", transport: .stdio)
        XCTAssertFalse(server.isValid)
        XCTAssertTrue(server.validationIssues.contains("La commande STDIO est obligatoire."))
    }

    func testHTTPValidationRejectsNonHTTPURL() {
        let server = MCPServer(name: "Remote", transport: .streamableHTTP, url: "file:///tmp/mcp")
        XCTAssertFalse(server.isValid)
    }

    func testCodexSTDIOConfiguration() {
        let server = MCPServer(
            name: "context7",
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@upstash/context7-mcp"],
            environmentVariableNames: ["CONTEXT7_TOKEN"]
        )

        let rendered = CodexConfigRenderer.render(server)
        XCTAssertTrue(rendered.contains("[mcp_servers.\"context7\"]"))
        XCTAssertTrue(rendered.contains("command = \"npx\""))
        XCTAssertTrue(rendered.contains("env_vars = [\"CONTEXT7_TOKEN\"]"))
    }

    func testCodexHTTPConfigurationDoesNotExposeSecret() {
        let server = MCPServer(
            name: "remote",
            transport: .streamableHTTP,
            url: "https://example.com/mcp",
            bearerTokenEnvironmentVariable: "REMOTE_MCP_TOKEN"
        )

        let rendered = CodexConfigRenderer.render(server)
        XCTAssertTrue(rendered.contains("bearer_token_env_var = \"REMOTE_MCP_TOKEN\""))
        XCTAssertFalse(rendered.contains("Authorization"))
    }

    func testToolsListDecoding() throws {
        let result: JSONValue = .object([
            "tools": .array([
                .object([
                    "name": .string("search"),
                    "description": .string("Search the index"),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object(["type": .string("string")])
                        ])
                    ])
                ])
            ])
        ])

        let (tools, cursor) = try MCPWire.tools(from: result)
        XCTAssertEqual(tools.map(\.name), ["search"])
        XCTAssertEqual(tools.first?.description, "Search the index")
        XCTAssertNil(cursor)
    }

    func testRPCErrorDecoding() throws {
        let response: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "error": .object([
                "code": .number(-32601),
                "message": .string("Method not found")
            ])
        ])

        XCTAssertThrowsError(try MCPWire.result(from: response)) { error in
            XCTAssertEqual(error as? MCPClientError, .rpc(code: -32601, message: "Method not found"))
        }
    }

    func testModernMetadataCarriesProtocolVersion() {
        XCTAssertEqual(
            MCPWire.modernMetadata["io.modelcontextprotocol/protocolVersion"]?.stringValue,
            "2026-07-28"
        )
    }

    func testDiscoversJSONConfigurationWithoutCopyingSecrets() throws {
        let configuration = #"""
        {
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "--api-key", "very-secret"],
              "env": { "FILES_ROOT": "/tmp", "ACCESS_TOKEN": "very-secret" }
            },
            "remote": {
              "url": "https://example.com/mcp",
              "headers": { "Authorization": "Bearer ${REMOTE_MCP_TOKEN}" }
            }
          }
        }
        """#
        let source = MCPDiscoverySource(kind: .cursor, location: "~/.cursor/mcp.json")
        let discoveries = try LocalMCPDiscoveryService(includeDeveloperTools: false)
            .parseJSONConfiguration(Data(configuration.utf8), source: source)

        XCTAssertEqual(discoveries.count, 2)
        let filesystem = try XCTUnwrap(discoveries.first { $0.server.name == "filesystem" })
        XCTAssertEqual(filesystem.server.environmentVariableNames, ["ACCESS_TOKEN", "FILES_ROOT"])
        XCTAssertFalse(filesystem.server.arguments.contains("very-secret"))
        XCTAssertTrue(filesystem.warnings.contains { $0.contains("masqué") })
        let remote = try XCTUnwrap(discoveries.first { $0.server.name == "remote" })
        XCTAssertEqual(remote.server.bearerTokenEnvironmentVariable, "REMOTE_MCP_TOKEN")
    }

    func testDiscoversCodexTOMLConfiguration() throws {
        let configuration = #"""
        model = "gpt-test"

        [mcp_servers."xcode"]
        command = "xcrun"
        args = ["mcpbridge"]
        env_vars = ["DEVELOPER_DIR"]

        [mcp_servers.remote]
        url = "https://example.com/mcp"
        bearer_token_env_var = "REMOTE_TOKEN"
        enabled = false
        """#
        let source = MCPDiscoverySource(kind: .codex, location: "~/.codex/config.toml")
        let discoveries = try LocalMCPDiscoveryService(includeDeveloperTools: false)
            .parseCodexConfiguration(Data(configuration.utf8), source: source)

        XCTAssertEqual(discoveries.count, 2)
        XCTAssertEqual(discoveries.first { $0.server.name == "xcode" }?.server.arguments, ["mcpbridge"])
        XCTAssertEqual(discoveries.first { $0.server.name == "xcode" }?.server.environmentVariableNames, ["DEVELOPER_DIR"])
        XCTAssertEqual(discoveries.first { $0.server.name == "remote" }?.server.bearerTokenEnvironmentVariable, "REMOTE_TOKEN")
        XCTAssertEqual(discoveries.first { $0.server.name == "remote" }?.server.enabled, false)
    }

    @MainActor
    func testImportSkipsAnExistingConnection() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "servers.json")
        let store = MCPServerStore(fileURL: fileURL)
        let server = MCPServer(name: "Xcode", command: "xcrun", arguments: ["mcpbridge"])

        XCTAssertEqual(store.importServers([server]).count, 1)
        XCTAssertEqual(store.importServers([server]).count, 0)
        XCTAssertEqual(store.servers.count, 1)
    }

    func testXcodeCodexInstallationPreservesConfigurationAndCreatesBackup() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codexDirectory = base.appending(path: "codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let configurationURL = codexDirectory.appending(path: "config.toml")
        try Data("model = \"gpt-test\"\n".utf8).write(to: configurationURL)

        let installer = XcodeMCPInstaller(codingAssistantDirectory: base)
        let server = MCPServer(name: "xcode-test", command: "xcrun", arguments: ["mcpbridge"])
        let target = try XCTUnwrap(installer.detectTargets(for: server).first { $0.kind == .codex })
        let receipt = try await installer.install(server, into: target)

        let installed = try String(contentsOf: configurationURL, encoding: .utf8)
        XCTAssertTrue(installed.contains("model = \"gpt-test\""))
        XCTAssertTrue(installed.contains("[mcp_servers.\"xcode-test\"]"))
        XCTAssertNotNil(receipt.backupURL)
        XCTAssertTrue(receipt.backupURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)

        let updatedTarget = try XCTUnwrap(installer.detectTargets(for: server).first { $0.kind == .codex })
        _ = try await installer.install(server, into: updatedTarget)
        let reinstalled = try String(contentsOf: configurationURL, encoding: .utf8)
        XCTAssertEqual(reinstalled.components(separatedBy: "[mcp_servers.\"xcode-test\"]").count - 1, 1)
    }

    func testXcodeClaudeInstallationPreservesExistingJSON() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let claudeDirectory = base.appending(path: "ClaudeAgentConfig", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let configurationURL = claudeDirectory.appending(path: ".claude.json")
        try Data(#"{"theme":"dark"}"#.utf8).write(to: configurationURL)

        let installer = XcodeMCPInstaller(codingAssistantDirectory: base)
        let server = MCPServer(name: "local-test", command: "/usr/bin/true")
        let target = try XCTUnwrap(installer.detectTargets(for: server).first { $0.kind == .claude })
        _ = try await installer.install(server, into: target)

        let data = try Data(contentsOf: configurationURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "dark")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["local-test"])
    }
}
