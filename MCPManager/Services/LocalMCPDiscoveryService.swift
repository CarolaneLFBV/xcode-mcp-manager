import Foundation

struct LocalMCPDiscoveryService: Sendable {
    private struct Candidate: Sendable {
        let url: URL
        let source: MCPDiscoverySource.Kind
        let format: Format
    }

    private enum Format: Sendable {
        case codexTOML
        case json(rootKeys: [String])
    }

    private let homeDirectory: URL
    private let applicationSupportDirectory: URL
    private let includeDeveloperTools: Bool

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = nil,
        includeDeveloperTools: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.includeDeveloperTools = includeDeveloperTools
    }

    func scan() async -> LocalMCPScanResult {
        await Task.detached(priority: .userInitiated) {
            scanSynchronously()
        }.value
    }

    func parseJSONConfiguration(
        _ data: Data,
        source: MCPDiscoverySource
    ) throws -> [DiscoveredMCPServer] {
        try parseJSONConfiguration(data, source: source, rootKeys: ["mcpServers", "servers"])
    }

    func parseCodexConfiguration(
        _ data: Data,
        source: MCPDiscoverySource
    ) throws -> [DiscoveredMCPServer] {
        let document = try TOMLServerDocument(data)
        var discoveries: [DiscoveredMCPServer] = []
        for section in document.sections where section.path.count == 2 && section.path[0] == "mcp_servers" {
            let name = section.path[1]
            var properties: [String: String] = [:]
            let assignments = section.range.filter { document.assignmentLines.contains($0) }
            for (offset, index) in assignments.enumerated() {
                let end = offset + 1 < assignments.count ? assignments[offset + 1] : section.range.upperBound
                let line = document.lines[index..<end].map(stripTOMLComment).joined(separator: "\n")
                guard let equals = firstUnquotedEquals(in: line) else { continue }
                let rawKey = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                properties[parseTOMLString(rawKey) ?? rawKey] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard var discovery = makeCodexDiscovery(name: name, properties: properties, source: source) else { continue }
            let envSections = document.sections.filter { $0.path == ["mcp_servers", name, "env"] }
            for env in envSections {
                for index in env.range where document.assignmentLines.contains(index) {
                    let line = stripTOMLComment(document.lines[index])
                    guard let equals = firstUnquotedEquals(in: line) else { continue }
                    let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                    discovery.server.environmentVariableNames.append(parseTOMLString(key) ?? key)
                }
                discovery.warnings.append(String(localized: "Les valeurs d’environnement n’ont pas été copiées ; elles restent dans la configuration source."))
            }
            discovery.server.environmentVariableNames = Array(Set(discovery.server.environmentVariableNames)).sorted()
            discovery.server.configurationSource = MCPConfigurationSource(url: URL(fileURLWithPath: (source.location as NSString).expandingTildeInPath), name: name, format: .toml)
            discoveries.append(discovery)
        }
        return discoveries
    }

    private func scanSynchronously() -> LocalMCPScanResult {
        let candidates = configurationCandidates
        var discoveries: [DiscoveredMCPServer] = []
        var unreadable: [String] = []

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.url.path) {
            let source = MCPDiscoverySource(
                kind: candidate.source,
                location: abbreviatedPath(candidate.url.path)
            )
            do {
                let data = try Data(contentsOf: candidate.url)
                switch candidate.format {
                case .codexTOML:
                    discoveries.append(contentsOf: try parseCodexConfiguration(data, source: source))
                case .json(let rootKeys):
                    discoveries.append(contentsOf: try parseJSONConfiguration(data, source: source, rootKeys: rootKeys))
                }
            } catch {
                unreadable.append(source.location)
            }
        }

        if includeDeveloperTools {
            discoveries.append(contentsOf: discoverDeveloperTools())
        }

        for index in discoveries.indices {
            do { discoveries[index].server = try MCPEnvironmentService().unwrapped(discoveries[index].server) }
            catch {
                discoveries[index].warnings.append(String(localized: "Profil du lanceur MCP Manager introuvable. Rétablissez-le avant de tester ou modifier ce serveur."))
            }
        }

        return LocalMCPScanResult(
            discoveries: mergeDuplicates(discoveries),
            inspectedLocations: candidates.count + (includeDeveloperTools ? 2 : 0),
            unreadableLocations: unreadable
        )
    }

    private var configurationCandidates: [Candidate] {
        [
            Candidate(
                url: homeDirectory.appending(path: "Library/Developer/Xcode/CodingAssistant/codex/config.toml"),
                source: .xcodeCodex,
                format: .codexTOML
            ),
            Candidate(
                url: homeDirectory.appending(path: "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/.claude.json"),
                source: .xcodeClaude,
                format: .json(rootKeys: ["mcpServers"])
            ),
            Candidate(
                url: homeDirectory.appending(path: ".codex/config.toml"),
                source: .codex,
                format: .codexTOML
            ),
            Candidate(
                url: applicationSupportDirectory.appending(path: "Claude/claude_desktop_config.json"),
                source: .claudeDesktop,
                format: .json(rootKeys: ["mcpServers"])
            ),
            Candidate(
                url: homeDirectory.appending(path: ".claude.json"),
                source: .claudeCode,
                format: .json(rootKeys: ["mcpServers"])
            ),
            Candidate(
                url: homeDirectory.appending(path: ".cursor/mcp.json"),
                source: .cursor,
                format: .json(rootKeys: ["mcpServers"])
            ),
            Candidate(
                url: applicationSupportDirectory.appending(path: "Code/User/mcp.json"),
                source: .visualStudioCode,
                format: .json(rootKeys: ["servers", "mcpServers"])
            ),
            Candidate(
                url: homeDirectory.appending(path: ".codeium/windsurf/mcp_config.json"),
                source: .windsurf,
                format: .json(rootKeys: ["mcpServers"])
            )
        ]
    }

    private func parseJSONConfiguration(
        _ data: Data,
        source: MCPDiscoverySource,
        rootKeys: [String]
    ) throws -> [DiscoveredMCPServer] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPClientError.invalidMessage("Configuration JSON invalide.")
        }
        let container = rootKeys.compactMap { root[$0] as? [String: Any] }.first ?? [:]

        let discoveries: [DiscoveredMCPServer] = container.compactMap { name, rawValue in
            guard let value = rawValue as? [String: Any] else { return nil }
            var warnings: [String] = []
            let enabled = !(value["disabled"] as? Bool ?? false)

            if let command = value["command"] as? String, !command.isEmpty {
                let rawArguments = value["args"] as? [String] ?? []
                let arguments = sanitizedArguments(rawArguments, warnings: &warnings)
                let environmentNames = (value["env"] as? [String: Any])?.keys.sorted() ?? []
                if !environmentNames.isEmpty {
                    warnings.append(String(localized: "Les valeurs d’environnement n’ont pas été copiées ; vérifiez ces variables avant la connexion."))
                }
                return DiscoveredMCPServer(
                    server: MCPServer(
                        name: name,
                        transport: .stdio,
                        command: resolvedCommand(command, workingDirectory: value["cwd"] as? String),
                        arguments: arguments,
                        environmentVariableNames: environmentNames,
                        enabled: enabled
                    ),
                    sources: [source],
                    warnings: warnings
                )
            }

            guard let url = (value["url"] ?? value["serverUrl"]) as? String, !url.isEmpty else {
                return nil
            }
            let bearerVariable = bearerEnvironmentVariable(from: value["headers"], warnings: &warnings)
            return DiscoveredMCPServer(
                server: MCPServer(
                    name: name,
                    transport: .streamableHTTP,
                    url: url,
                    bearerTokenEnvironmentVariable: bearerVariable,
                    enabled: enabled
                ),
                sources: [source],
                warnings: warnings
            )
        }
        return discoveries.map { discovery in
            var discovery = discovery
            discovery.server.configurationSource = MCPConfigurationSource(url: URL(fileURLWithPath: (source.location as NSString).expandingTildeInPath), name: discovery.server.name, format: .json)
            return discovery
        }
    }

    private func makeCodexDiscovery(
        name: String,
        properties: [String: String],
        source: MCPDiscoverySource
    ) -> DiscoveredMCPServer? {
        var warnings: [String] = []
        let enabled = properties["enabled"].map { $0 != "false" } ?? true
        if let command = properties["command"].flatMap(parseTOMLString) {
            let rawArguments = properties["args"].map(parseTOMLStringArray) ?? []
            var environmentNames = properties["env_vars"].map(parseTOMLStringArray) ?? []
            if let inlineEnvironment = properties["env"] {
                environmentNames.append(contentsOf: parseInlineTableKeys(inlineEnvironment))
                if !environmentNames.isEmpty {
                    warnings.append(String(localized: "Les valeurs d’environnement n’ont pas été copiées ; vérifiez ces variables avant la connexion."))
                }
            }
            return DiscoveredMCPServer(
                server: MCPServer(
                    name: name,
                    transport: .stdio,
                    command: resolvedCommand(
                        command,
                        workingDirectory: properties["cwd"].flatMap(parseTOMLString)
                    ),
                    arguments: sanitizedArguments(rawArguments, warnings: &warnings),
                    environmentVariableNames: Array(Set(environmentNames)).sorted(),
                    enabled: enabled
                ),
                sources: [source],
                warnings: warnings
            )
        }
        if let url = properties["url"].flatMap(parseTOMLString) {
            let bearerVariable = properties["bearer_token_env_var"].flatMap(parseTOMLString) ?? ""
            return DiscoveredMCPServer(
                server: MCPServer(
                    name: name,
                    transport: .streamableHTTP,
                    url: url,
                    bearerTokenEnvironmentVariable: bearerVariable,
                    enabled: enabled
                ),
                sources: [source],
                warnings: warnings
            )
        }
        return nil
    }

    private func discoverDeveloperTools() -> [DiscoveredMCPServer] {
        var result: [DiscoveredMCPServer] = []
        if xcrunCanFind("mcpbridge") {
            result.append(DiscoveredMCPServer(
                server: MCPServer(
                    name: "Xcode Tools",
                    transport: .stdio,
                    command: "xcrun",
                    arguments: ["mcpbridge"]
                ),
                sources: [MCPDiscoverySource(kind: .xcode, location: "xcrun mcpbridge")]
            ))
        }
        if xcrunCanFind("lldb-mcp") {
            result.append(DiscoveredMCPServer(
                server: MCPServer(
                    name: "LLDB",
                    transport: .stdio,
                    command: "xcrun",
                    arguments: ["lldb-mcp"]
                ),
                sources: [MCPDiscoverySource(kind: .lldb, location: "xcrun lldb-mcp")]
            ))
        }
        return result
    }

    private func xcrunCanFind(_ tool: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", tool]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func mergeDuplicates(_ values: [DiscoveredMCPServer]) -> [DiscoveredMCPServer] {
        var merged: [String: DiscoveredMCPServer] = [:]
        for value in values {
            let key = value.server.discoverySignature
            if var existing = merged[key] {
                existing.sources = Array(Set(existing.sources + value.sources))
                    .sorted { $0.kind.title < $1.kind.title }
                existing.warnings = Array(Set(existing.warnings + value.warnings)).sorted()
                merged[key] = existing
            } else {
                merged[key] = value
            }
        }
        return merged.values.sorted {
            $0.server.name.localizedStandardCompare($1.server.name) == .orderedAscending
        }
    }

    private func bearerEnvironmentVariable(from rawHeaders: Any?, warnings: inout [String]) -> String {
        guard let headers = rawHeaders as? [String: Any],
              let authorization = headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame })?.value as? String else {
            return ""
        }
        let patterns = ["\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}", "\\$([A-Za-z_][A-Za-z0-9_]*)"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: authorization, range: NSRange(authorization.startIndex..., in: authorization)),
               let range = Range(match.range(at: 1), in: authorization) {
                return String(authorization[range])
            }
        }
        if !authorization.isEmpty {
            warnings.append(String(localized: "Un en-tête d’autorisation littéral a été ignoré. Utilisez une variable d’environnement."))
        }
        return ""
    }

    private func sanitizedArguments(_ arguments: [String], warnings: inout [String]) -> [String] {
        let markers = ["key", "token", "secret", "password", "credential"]
        var result = arguments
        var index = 0
        while index < result.count {
            let lowercased = result[index].lowercased()
            if markers.contains(where: lowercased.contains) {
                if let equals = result[index].firstIndex(of: "=") {
                    result[index] = String(result[index][...equals]) + "<secret non importé>"
                } else if index + 1 < result.count, !result[index + 1].hasPrefix("-") {
                    result[index + 1] = "<secret non importé>"
                    index += 1
                }
                warnings.append(String(localized: "Un argument susceptible de contenir un secret a été masqué."))
            }
            index += 1
        }
        return result
    }

    private func resolvedCommand(_ command: String, workingDirectory: String?) -> String {
        guard command.hasPrefix("./") || command.hasPrefix("../") else { return command }
        let baseURL: URL
        if let workingDirectory, !workingDirectory.isEmpty {
            baseURL = workingDirectory.hasPrefix("/")
                ? URL(fileURLWithPath: workingDirectory, isDirectory: true)
                : homeDirectory.appending(path: workingDirectory, directoryHint: .isDirectory)
        } else {
            baseURL = homeDirectory
        }
        return URL(fileURLWithPath: command, relativeTo: baseURL).standardizedFileURL.path
    }

    private func codexServerName(fromSection line: String) -> String? {
        let body = line.dropFirst().dropLast()
        let prefix = "mcp_servers."
        guard body.hasPrefix(prefix) else { return nil }
        let rawName = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if let quoted = parseTOMLString(rawName) { return quoted }
        guard !rawName.isEmpty, !rawName.contains(".") else { return nil }
        return rawName
    }

    func parseTOMLString(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    private func parseTOMLStringArray(_ raw: String) -> [String] {
        let pattern = #"\"(?:\\.|[^\"\\])*\"|'[^']*'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap { match in
            guard let range = Range(match.range, in: raw) else { return nil }
            return parseTOMLString(String(raw[range]))
        }
    }

    private func parseInlineTableKeys(_ raw: String) -> [String] {
        let body = raw.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        return body.split(separator: ",").compactMap { pair in
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            let rawKey = pair[..<equals].trimmingCharacters(in: .whitespaces)
            return parseTOMLString(rawKey) ?? (rawKey.isEmpty ? nil : rawKey)
        }
    }

    func firstUnquotedEquals(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
            } else if character == "=", quote == nil {
                return index
            }
        }
        return nil
    }

    func stripTOMLComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = homeDirectory.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
