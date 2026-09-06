import Foundation

struct MCPConfigurationSource: Codable, Hashable, Sendable {
    enum Format: String, Codable, Sendable { case toml, json }
    let url: URL
    let name: String
    let format: Format
}

/// Deliberately not Codable: source credentials are never persisted in the catalogue.
struct MCPLocalCredentials: Sendable {
    var environment: [String: String] = [:]
    var headers: [String: String] = [:]
    var oauth = false
    var source: URL?
    var hasValues: Bool { !environment.isEmpty || !headers.isEmpty }
}

enum MCPLocalCredentialError: LocalizedError {
    case unavailable, changed, ambiguous, unsupported, missing, unsafeHTTP, oauth, authentication
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "La configuration source est introuvable ou illisible. Actualisez l’inventaire.")
        case .changed: String(localized: "La connexion diffère de sa source. Actualisez ou sélectionnez l’entrée exacte dans Xcode ; aucun secret n’a été réutilisé.")
        case .ambiguous: String(localized: "Plusieurs configurations correspondent. Sélectionnez le serveur dans le groupe Xcode de l’agent ou du projet voulu.")
        case .unsupported: String(localized: "La source utilise une forme de variable ou d’authentification non prise en charge. Aucun script ni fichier .env n’a été exécuté.")
        case .missing: String(localized: "Une variable requise manque dans la configuration source et dans l’environnement du Manager. L’environnement privé de Xcode n’est pas accessible.")
        case .unsafeHTTP: String(localized: "Les identifiants HTTP nécessitent une URL HTTPS et des en-têtes valides, sans redirection.")
        case .oauth: "OAuth requis : utilisez Se connecter dans la rubrique Connexion OAuth (Sentry pris en charge dans ce premier lot). Le Manager ne partage pas la session de Xcode."
        case .authentication: String(localized: "Le serveur a refusé l’authentification HTTP (401/403). Vérifiez les identifiants et leurs droits. Une connexion réussie dans Xcode ne garantit pas celle du Manager.")
        }
    }
}

struct MCPLocalCredentialResolver: Sendable {
    var inherited: [String: String] = ProcessInfo.processInfo.environment

    func resolve(_ server: MCPServer, candidates: [MCPServer]? = nil, ignoringEnvironment: Set<String> = []) throws -> MCPLocalCredentials {
        guard server.environmentProfileID == nil else { return MCPLocalCredentials() }
        var reference = server.configurationSource
        if reference == nil, let binding = server.xcodeBinding {
            let url = binding.projectDirectoryURL?.appending(path: ".codex/config.toml")
                ?? XcodeMCPManagement().url(for: binding.kind)
            reference = MCPConfigurationSource(url: url, name: binding.name, format: binding.kind == .codex ? .toml : .json)
        }
        if reference == nil {
            let known = candidates ?? (XcodeMCPManagement().inventory().entries + XcodeProjectDiscovery().inventory().entries).map(\.server)
            let matches = Set(known.filter { sameConnection($0, server) }.compactMap(\.configurationSource))
            guard matches.count <= 1 else { throw MCPLocalCredentialError.ambiguous }
            reference = matches.first
        }
        var result = MCPLocalCredentials()
        if let reference {
            result = try read(reference, for: server)
        }
        for name in ignoringEnvironment { result.environment.removeValue(forKey: name) }
        for name in server.environmentVariableNames where result.environment[name] == nil && !ignoringEnvironment.contains(name) {
            guard let value = inherited[name] else { throw MCPLocalCredentialError.missing }
            result.environment[name] = value
        }
        if server.transport == .streamableHTTP, !server.bearerTokenEnvironmentVariable.isEmpty {
            guard let value = result.environment[server.bearerTokenEnvironmentVariable] ?? inherited[server.bearerTokenEnvironmentVariable], !value.isEmpty else {
                throw MCPLocalCredentialError.missing
            }
            result.headers = result.headers.filter { $0.key.lowercased() != "authorization" }
            result.headers["Authorization"] = "Bearer \(value)"
        }
        try MCPEnvironmentRuntime.validate(result.environment.keys.map { .init(name: $0, isSecret: false, value: result.environment[$0]) })
        if server.transport == .streamableHTTP {
            try Self.validateHeaders(result.headers, url: server.url)
            if result.oauth && result.headers.isEmpty { throw MCPLocalCredentialError.oauth }
        }
        return result
    }

    static func validateHeaders(_ headers: [String: String], url: String) throws {
        guard !headers.isEmpty else { return }
        guard let url = URL(string: url), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            throw MCPLocalCredentialError.unsafeHTTP
        }
        let forbidden = ["host", "content-length", "transfer-encoding", "connection", "content-type", "accept", "mcp-session-id", "mcp-protocol-version", "mcp-method"]
        let headerNameBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+.^_`|~-".utf8)
        guard Set(headers.keys.map { $0.lowercased() }).count == headers.count else { throw MCPLocalCredentialError.unsafeHTTP }
        for (key, value) in headers {
            guard !key.isEmpty, key.utf8.allSatisfy({ headerNameBytes.contains($0) }),
                  !forbidden.contains(key.lowercased()), !value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) else {
                throw MCPLocalCredentialError.unsafeHTTP
            }
        }
    }

    private func sameConnection(_ a: MCPServer, _ b: MCPServer) -> Bool {
        guard a.transport == b.transport else { return false }
        if a.transport == .streamableHTTP { return a.url == b.url && a.bearerTokenEnvironmentVariable == b.bearerTokenEnvironmentVariable }
        return a.command == b.command && a.arguments == b.arguments && !a.arguments.contains("<secret non importé>")
    }

    private func read(_ reference: MCPConfigurationSource, for server: MCPServer) throws -> MCPLocalCredentials {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: reference.url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 5_000_000 else { throw MCPLocalCredentialError.unavailable }
            data = try Data(contentsOf: reference.url)
        } catch { throw MCPLocalCredentialError.unavailable }
        let parser = LocalMCPDiscoveryService(includeDeveloperTools: false)
        let source = MCPDiscoverySource(kind: .xcodeCodex, location: reference.url.path)
        var env: [String: String] = [:]
        var headers: [String: String] = [:]
        var envHeaders: [String: String] = [:]
        var oauth = false
        do {
            let discoveries = try reference.format == .toml ? parser.parseCodexConfiguration(data, source: source) : parser.parseJSONConfiguration(data, source: source)
            guard let current = discoveries.first(where: { $0.server.name == reference.name })?.server,
                  sameConnection(current, server) else { throw MCPLocalCredentialError.changed }
            if reference.format == .json {
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let map = (root["mcpServers"] ?? root["servers"]) as? [String: Any] ?? [:]
                let definition = map[reference.name] as? [String: Any] ?? [:]
                env = try stringMap(definition["env"])
                headers = try stringMap(definition["headers"])
            } else {
                let document = try TOMLServerDocument(data)
                let path = ["mcp_servers", reference.name]
                let props = try properties(document, path: path)
                env = try table(document, path: path, name: "env", props: props)
                headers = try table(document, path: path, name: "http_headers", props: props)
                envHeaders = try table(document, path: path, name: "env_http_headers", props: props)
                oauth = props["auth"].flatMap(parser.parseTOMLString) == "oauth"
                if props["http_headers_helper"] != nil { throw MCPLocalCredentialError.unsupported }
            }
            for (key, value) in env { env[key] = try interpolate(value, values: inherited) }
            for (key, value) in headers { headers[key] = try interpolate(value, values: env.merging(inherited) { a, _ in a }) }
            for (header, name) in envHeaders {
                guard let value = env[name] ?? inherited[name] else { throw MCPLocalCredentialError.missing }
                headers[header] = value
            }
        } catch let error as MCPLocalCredentialError { throw error }
        catch { throw MCPLocalCredentialError.unsupported }
        return MCPLocalCredentials(environment: env, headers: headers, oauth: oauth, source: reference.url)
    }

    private func stringMap(_ value: Any?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let map = value as? [String: String] else { throw MCPLocalCredentialError.unsupported }
        return map
    }

    private func properties(_ document: TOMLServerDocument, path: [String]) throws -> [String: String] {
        guard let section = document.sections.first(where: { $0.path == path }) else { return [:] }
        let parser = LocalMCPDiscoveryService(includeDeveloperTools: false)
        let assignments = section.range.filter { document.assignmentLines.contains($0) }
        var result: [String: String] = [:]
        for (offset, index) in assignments.enumerated() {
            let end = offset + 1 < assignments.count ? assignments[offset + 1] : section.range.upperBound
            let text = document.lines[index..<end].map(parser.stripTOMLComment).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = parser.firstUnquotedEquals(in: text) else { continue }
            let rawKey = String(text[..<equals]).trimmingCharacters(in: .whitespaces)
            let key = parser.parseTOMLString(rawKey) ?? rawKey
            guard result[key] == nil else { throw MCPLocalCredentialError.unsupported }
            result[key] = String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func table(_ document: TOMLServerDocument, path: [String], name: String, props: [String: String]) throws -> [String: String] {
        var values = try properties(document, path: path + [name])
        if let inline = props[name] {
            guard values.isEmpty, inline.first == "{", inline.last == "}" else { throw MCPLocalCredentialError.unsupported }
            var quote: Character?; var escaped = false; var parts: [String] = []; var part = ""
            for char in inline.dropFirst().dropLast() {
                if escaped { escaped = false; part.append(char); continue }
                if char == "\\", quote == "\"" { escaped = true; part.append(char); continue }
                if char == "\"" || char == "'" { quote = quote == char ? nil : (quote ?? char) }
                if char == ",", quote == nil { parts.append(part); part = "" } else { part.append(char) }
            }
            guard quote == nil else { throw MCPLocalCredentialError.unsupported }
            if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(part) }
            let parser = LocalMCPDiscoveryService(includeDeveloperTools: false)
            for part in parts {
                guard let equals = parser.firstUnquotedEquals(in: part) else { throw MCPLocalCredentialError.unsupported }
                let rawKey = String(part[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                let key = parser.parseTOMLString(rawKey) ?? rawKey
                guard values[key] == nil else { throw MCPLocalCredentialError.unsupported }
                values[key] = String(part[part.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return try values.mapValues { value in
            guard !value.hasPrefix("\"\"\""), !value.hasPrefix("'''"),
                  let decoded = LocalMCPDiscoveryService(includeDeveloperTools: false).parseTOMLString(value) else {
                throw MCPLocalCredentialError.unsupported
            }
            return decoded
        }
    }

    private func interpolate(_ value: String, values: [String: String]) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\$\{(?:env:)?([A-Za-z_][A-Za-z0-9_]*)\}"#)
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: value), let range = Range(match.range, in: result),
                  let replacement = values[String(value[keyRange])] else { throw MCPLocalCredentialError.missing }
            result.replaceSubrange(range, with: replacement)
        }
        guard !result.contains("${") else { throw MCPLocalCredentialError.unsupported }
        return result
    }
}
