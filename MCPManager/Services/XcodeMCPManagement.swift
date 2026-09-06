import Foundation
import CryptoKit
import Darwin

struct XcodeServerBinding: Codable, Hashable, Sendable {
    let kind: XcodeInstallationTarget.Kind
    let name: String
    var projectDirectoryURL: URL? = nil
}

enum XcodeManagementAction: String, Codable, CaseIterable, Sendable {
    case enable, disable, uninstall
    var title: String {
        switch self {
        case .enable: String(localized: "Activer")
        case .disable: String(localized: "Désactiver")
        case .uninstall: String(localized: "Désinstaller")
        }
    }
}

struct XcodeEntrySnapshot: Codable, Equatable, Sendable {
    var active: Data?
    var paused: Data?
    var revision: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return XcodeMCPManagement.digest(try! encoder.encode(self))
    }
}

struct XcodeManagementReceipt: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let binding: XcodeServerBinding
    let action: XcodeManagementAction
    let before: XcodeEntrySnapshot
    let after: XcodeEntrySnapshot
    var completed: Bool
    var restored: Bool
    var restoring: Bool = false
}

struct XcodeInventoryEntry: Identifiable, Sendable {
    var server: MCPServer
    var target: XcodeInstallationTarget
    var id: UUID { server.id }
}

struct XcodeInventory: Sendable {
    var entries: [XcodeInventoryEntry] = []
    var errors: [String] = []
}

enum XcodeManagementError: LocalizedError {
    case conflict, unsupported(String), incomplete
    var errorDescription: String? {
        switch self {
        case .conflict: String(localized: "Cette configuration a changé. Actualisez la liste avant de réessayer. Aucun changement concurrent ne sera remplacé.")
        case .unsupported(let reason): String(localized: "Configuration conservée : \(reason)")
        case .incomplete: String(localized: "Une opération interrompue doit être restaurée depuis l’historique avant de continuer.")
        }
    }
}

// Serializes app-owned writes. Entry revisions and file comparisons also catch external edits.
enum XcodeConfigurationLock {
    static let shared = NSRecursiveLock()
}

struct XcodeMCPManagement: Sendable {
    let directory: URL
    let environmentService: MCPEnvironmentService
    init(directory: URL? = nil, environmentService: MCPEnvironmentService = MCPEnvironmentService()) {
        self.environmentService = environmentService
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Developer/Xcode/CodingAssistant")
    }

    func url(for kind: XcodeInstallationTarget.Kind) -> URL {
        directory.appending(path: kind == .codex ? "codex/config.toml" : "ClaudeAgentConfig/.claude.json")
    }
    private var pausedURL: URL { directory.appending(path: "ClaudeAgentConfig/.mcp-manager-disabled.json") }
    private var historyURL: URL { directory.appending(path: ".mcp-manager-history") }

    func inventory() -> XcodeInventory {
        var result = XcodeInventory()
        for kind in XcodeInstallationTarget.Kind.allCases {
            do { result.entries += try entries(for: kind) }
            catch { result.errors.append("\(kind.title) : \(error.localizedDescription)") }
        }
        do {
            for receipt in try history() where (!receipt.completed || receipt.restoring) && !receipt.restored {
                result.errors.append(String(localized: "\(receipt.binding.kind.title) · \(receipt.binding.name) : restauration nécessaire dans l’historique."))
            }
        } catch { result.errors.append("Historique illisible : \(error.localizedDescription)") }
        return result
    }

    func entries(for kind: XcodeInstallationTarget.Kind) throws -> [XcodeInventoryEntry] {
        let documents = try readDocuments(kind)
        let names = try names(in: documents, kind: kind)
        let interrupted = try history().contains { (!$0.completed || $0.restoring) && !$0.restored && $0.binding.kind == kind }
        return try names.sorted().map { name in
            let snapshot = try snapshot(name, kind: kind, documents: documents)
            let payload = snapshot.active ?? snapshot.paused!
            let parser = LocalMCPDiscoveryService(includeDeveloperTools: false)
            let source = MCPDiscoverySource(kind: kind == .codex ? .xcodeCodex : .xcodeClaude, location: url(for: kind).path)
            let discoveries: [DiscoveredMCPServer]
            if kind == .codex {
                let fragments = try JSONDecoder().decode([String].self, from: payload)
                discoveries = try parser.parseCodexConfiguration(Data(fragments.joined().utf8), source: source)
            } else {
                let definition = try JSONSerialization.jsonObject(with: payload)
                discoveries = try parser.parseJSONConfiguration(Self.json(["mcpServers": [name: definition]]), source: source)
            }
            // Even an unsupported definition stays visible and can be removed/restored losslessly.
            var server = discoveries.first?.server ?? MCPServer(name: name)
            var environmentError: String?
            do { server = try environmentService.unwrapped(server) }
            catch { environmentError = String(localized: "Profil de variables du lanceur introuvable ou invalide. Rétablissez le profil avant de modifier cette entrée.") }
            server.xcodeBinding = XcodeServerBinding(kind: kind, name: name)
            let hash = Self.digest(Data("\(kind.rawValue):\(name)".utf8))
            let chars = Array(hash.prefix(32))
            server.id = UUID(uuidString: [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-"))!
            let disabled = snapshot.paused != nil || (kind == .codex && !server.enabled)
            server.enabled = !disabled
            return XcodeInventoryEntry(server: server, target: XcodeInstallationTarget(
                kind: kind, configurationURL: url(for: kind),
                isAvailable: FileManager.default.fileExists(atPath: url(for: kind).deletingLastPathComponent().path),
                isAlreadyConfigured: true, configuredServerName: name, isDisabled: disabled,
                detectionError: interrupted ? XcodeManagementError.incomplete.localizedDescription : environmentError,
                revision: snapshot.revision
            ))
        }
    }

    func history() throws -> [XcodeManagementReceipt] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(XcodeManagementReceipt.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    func perform(_ action: XcodeManagementAction, binding: XcodeServerBinding, revision: String) throws -> XcodeManagementReceipt {
        guard binding.projectDirectoryURL == nil else {
            throw XcodeManagementError.unsupported(String(localized: "les configurations de projet sont en lecture seule."))
        }
        XcodeConfigurationLock.shared.lock()
        defer { XcodeConfigurationLock.shared.unlock() }
        guard !(try history().contains { (!$0.completed || $0.restoring) && !$0.restored && $0.binding.kind == binding.kind }) else {
            throw XcodeManagementError.incomplete
        }
        let documents = try readDocuments(binding.kind)
        let before = try snapshot(binding.name, kind: binding.kind, documents: documents)
        guard before.revision == revision, before.active != nil || before.paused != nil else { throw XcodeManagementError.conflict }
        var after = before
        switch action {
        case .uninstall: after = XcodeEntrySnapshot()
        case .disable:
            if binding.kind == .claude {
                guard before.active != nil, before.paused == nil else { throw XcodeManagementError.conflict }
                after = XcodeEntrySnapshot(active: nil, paused: before.active)
            } else {
                after.active = try TOMLServerDocument.settingEnabled(false, payload: before.active!, name: binding.name)
            }
        case .enable:
            if binding.kind == .claude {
                guard before.active == nil, before.paused != nil else { throw XcodeManagementError.conflict }
                after = XcodeEntrySnapshot(active: before.paused, paused: nil)
            } else {
                after.active = try TOMLServerDocument.settingEnabled(true, payload: before.active!, name: binding.name)
            }
        }
        var receipt = XcodeManagementReceipt(id: UUID(), date: .now, binding: binding, action: action,
            before: before, after: after, completed: false, restored: false)
        // Durable intent is saved first; an interrupted multi-file write remains recoverable.
        try save(receipt)
        try apply(after, binding: binding, expectedDocuments: documents)
        receipt.completed = true
        try save(receipt)
        return receipt
    }

    func restore(_ requested: XcodeManagementReceipt) throws {
        guard requested.binding.projectDirectoryURL == nil else {
            throw XcodeManagementError.unsupported(String(localized: "les configurations de projet sont en lecture seule."))
        }
        XcodeConfigurationLock.shared.lock()
        defer { XcodeConfigurationLock.shared.unlock() }
        guard var receipt = try history().first(where: { $0.id == requested.id }), !receipt.restored else {
            throw XcodeManagementError.conflict
        }
        guard receipt.binding.projectDirectoryURL == nil else {
            throw XcodeManagementError.unsupported(String(localized: "les configurations de projet sont en lecture seule."))
        }
        guard !(try history().contains { $0.binding == receipt.binding && $0.date > receipt.date && !$0.restored }) else {
            throw XcodeManagementError.conflict
        }
        let documents = try readDocuments(receipt.binding.kind)
        let current = try snapshot(receipt.binding.name, kind: receipt.binding.kind, documents: documents, allowDuplicate: !receipt.completed || receipt.restoring)
        if receipt.completed && !receipt.restoring {
            guard current == receipt.after else { throw XcodeManagementError.conflict }
        } else {
            guard [receipt.before.active, receipt.after.active].contains(current.active),
                  [receipt.before.paused, receipt.after.paused].contains(current.paused) else { throw XcodeManagementError.conflict }
        }
        receipt.restoring = true
        try save(receipt)
        try apply(receipt.before, binding: receipt.binding, expectedDocuments: documents)
        receipt.restoring = false
        receipt.restored = true
        try save(receipt)
    }

    private struct Documents {
        var configuration: Data?
        var paused: Data?
    }
    private func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw XcodeManagementError.unsupported(String(localized: "les liens symboliques nécessitent une gestion manuelle"))
        }
        return try Data(contentsOf: url)
    }
    private func readDocuments(_ kind: XcodeInstallationTarget.Kind) throws -> Documents {
        Documents(configuration: try read(url(for: kind)), paused: kind == .claude ? try read(pausedURL) : nil)
    }
    private func names(in documents: Documents, kind: XcodeInstallationTarget.Kind) throws -> Set<String> {
        if kind == .codex { return try TOMLServerDocument(documents.configuration ?? Data()).names }
        return Set(try serverMap(documents.configuration).keys).union(try serverMap(documents.paused).keys)
    }
    private func snapshot(_ name: String, kind: XcodeInstallationTarget.Kind, documents: Documents, allowDuplicate: Bool = false) throws -> XcodeEntrySnapshot {
        if kind == .codex {
            return XcodeEntrySnapshot(active: try TOMLServerDocument(documents.configuration ?? Data()).payload(name))
        }
        let active = try serverMap(documents.configuration)[name].map(Self.json)
        let paused = try serverMap(documents.paused)[name].map(Self.json)
        guard allowDuplicate || active == nil || paused == nil else {
            throw XcodeManagementError.unsupported(String(localized: "« \(name) » existe dans la configuration et dans les serveurs suspendus ; restaurez l’opération interrompue ou résolvez le doublon"))
        }
        return XcodeEntrySnapshot(active: active, paused: paused)
    }
    private func serverMap(_ data: Data?) throws -> [String: Any] {
        let root = try jsonRoot(data)
        if root["mcpServers"] == nil { return [:] }
        guard let map = root["mcpServers"] as? [String: Any] else { throw XcodeManagementError.unsupported(String(localized: "mcpServers doit être un objet")) }
        return map
    }
    private func jsonRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw XcodeManagementError.unsupported(String(localized: "racine JSON incorrecte")) }
        return root
    }
    private func replaceJSON(_ payload: Data?, name: String, in data: Data?) throws -> Data {
        var root = try jsonRoot(data)
        var map = try serverMap(data)
        map[name] = try payload.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        root["mcpServers"] = map
        return try Self.json(root)
    }
    private func apply(_ state: XcodeEntrySnapshot, binding: XcodeServerBinding, expectedDocuments: Documents) throws {
        let configuration: Data
        if binding.kind == .codex {
            configuration = try TOMLServerDocument(expectedDocuments.configuration ?? Data()).replacing(binding.name, with: state.active)
        } else {
            configuration = try replaceJSON(state.active, name: binding.name, in: expectedDocuments.configuration)
        }
        let paused = binding.kind == .claude ? try replaceJSON(state.paused, name: binding.name, in: expectedDocuments.paused) : nil
        let latest = try readDocuments(binding.kind)
        guard latest.configuration == expectedDocuments.configuration, latest.paused == expectedDocuments.paused else { throw XcodeManagementError.conflict }
        // Save the paused definition before removing the active one; on reactivation reverse the order.
        if binding.kind == .claude, state.paused != nil, let paused {
            try Self.atomicWrite(paused, to: pausedURL, permissions: 0o600)
        }
        guard try read(url(for: binding.kind)) == expectedDocuments.configuration else { throw XcodeManagementError.conflict }
        let mode = (try? FileManager.default.attributesOfItem(atPath: url(for: binding.kind).path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try Self.atomicWrite(configuration, to: url(for: binding.kind), permissions: mode)
        if binding.kind == .claude, state.paused == nil, let paused {
            guard try read(pausedURL) == expectedDocuments.paused else { throw XcodeManagementError.conflict }
            try Self.atomicWrite(paused, to: pausedURL, permissions: 0o600)
        }
        let verified = try snapshot(binding.name, kind: binding.kind, documents: readDocuments(binding.kind))
        guard verified == state else { throw XcodeManagementError.conflict }
    }

    private func save(_ receipt: XcodeManagementReceipt) throws {
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.atomicWrite(JSONEncoder().encode(receipt), to: historyURL.appending(path: "\(receipt.id.uuidString).json"), permissions: 0o600)
    }
    static func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".mcp-manager-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw XcodeManagementError.unsupported(String(localized: "impossible de préparer le fichier"))
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Lossless table boundaries. Unsupported forms fail closed before any mutation.
struct TOMLServerDocument {
    struct Section { let path: [String]; let range: Range<Int> }
    let lines: [String]
    let sections: [Section]
    let assignmentLines: Set<Int>
    var names: Set<String> { Set(sections.filter { $0.path.count >= 2 && $0.path[0] == "mcp_servers" }.map { $0.path[1] }) }

    init(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw XcodeManagementError.unsupported(String(localized: "TOML illisible")) }
        // Retain newline bytes, including CRLF, to preserve unrelated sections exactly.
        var rawLines: [String] = []
        var start = text.startIndex
        for index in text.indices where text[index] == "\n" {
            let end = text.index(after: index)
            rawLines.append(String(text[start..<end])); start = end
        }
        if start < text.endIndex { rawLines.append(String(text[start...])) }
        lines = rawLines
        var headers: [(Int, [String])] = []
        var nesting = 0
        var multiline: Character?
        var assignments = Set<Int>()
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if multiline == nil && (line.isEmpty || line.hasPrefix("#")) { continue }
            if multiline == nil && nesting == 0 && line.hasPrefix("[") {
                let path = try Self.header(line)
                if path.first == "mcp_servers" && (path.count < 2 || line.hasPrefix("[[")) {
                    throw XcodeManagementError.unsupported(String(localized: "utilisez des tables [mcp_servers.nom] distinctes"))
                }
                headers.append((index, path))
            } else {
                if nesting == 0 && multiline == nil { assignments.insert(index) }
                if headers.isEmpty && multiline == nil && line.hasPrefix("mcp_servers") {
                    throw XcodeManagementError.unsupported(String(localized: "la définition MCP en ligne n’est pas prise en charge"))
                }
                var quote: Character?
                var escaped = false
                let characters = Array(line)
                var position = 0
                while position < characters.count {
                    let c = characters[position]
                    if escaped { escaped = false; position += 1; continue }
                    if c == "\\", quote == "\"" || multiline == "\"" { escaped = true; position += 1; continue }
                    if let delimiter = multiline {
                        if c == delimiter && position + 2 < characters.count && characters[position + 1] == delimiter && characters[position + 2] == delimiter {
                            var count = 3
                            while position + count < characters.count && characters[position + count] == delimiter { count += 1 }
                            guard count <= 5 else { throw XcodeManagementError.unsupported(String(localized: "chaîne TOML invalide")) }
                            multiline = nil; position += count
                        } else { position += 1 }
                        continue
                    }
                    if let q = quote { if c == q { quote = nil }; position += 1; continue }
                    if c == "#" { break }
                    if c == "\"" || c == "'" {
                        if position + 2 < characters.count && characters[position + 1] == c && characters[position + 2] == c {
                            multiline = c; position += 3; continue
                        }
                        quote = c
                    }
                    else if c == "[" || c == "{" { nesting += 1 }
                    else if c == "]" || c == "}" { nesting -= 1 }
                    position += 1
                }
                guard quote == nil && nesting >= 0 else { throw XcodeManagementError.unsupported(String(localized: "syntaxe TOML non reconnue")) }
            }
        }
        guard nesting == 0 && multiline == nil else { throw XcodeManagementError.unsupported(String(localized: "tableau ou chaîne TOML incomplet")) }
        var found: [Section] = []
        var seen = Set<[String]>()
        for (offset, header) in headers.enumerated() {
            if header.1.first == "mcp_servers", !seen.insert(header.1).inserted { throw XcodeManagementError.unsupported(String(localized: "table MCP dupliquée")) }
            found.append(Section(path: header.1, range: header.0..<(offset + 1 < headers.count ? headers[offset + 1].0 : lines.count)))
        }
        sections = found
        assignmentLines = assignments
    }
    func payload(_ name: String) throws -> Data? {
        let matches = sections.filter { $0.path.count >= 2 && $0.path[0] == "mcp_servers" && $0.path[1] == name }
        guard !matches.isEmpty else { return nil }
        return try JSONEncoder().encode(matches.map { lines[$0.range].joined() })
    }
    func replacing(_ name: String, with payload: Data?) throws -> Data {
        let matches = sections.filter { $0.path.count >= 2 && $0.path[0] == "mcp_servers" && $0.path[1] == name }
        var result = lines
        for section in matches.reversed() { result.removeSubrange(section.range) }
        if let payload {
            let fragments = try JSONDecoder().decode([String].self, from: payload)
            let restored = fragments.joined()
            let check = try TOMLServerDocument(Data(restored.utf8))
            guard check.names == [name], check.sections.allSatisfy({ $0.path.first == "mcp_servers" }) else { throw XcodeManagementError.unsupported(String(localized: "sauvegarde TOML incompatible")) }
            if !result.isEmpty && !(result.last?.hasSuffix("\n") ?? true) { result.append("\n") }
            result.append(restored)
        }
        return Data(result.joined().utf8)
    }
    static func settingEnabled(_ enabled: Bool, payload: Data, name: String) throws -> Data {
        let fragments = try JSONDecoder().decode([String].self, from: payload)
        let document = try TOMLServerDocument(Data(fragments.joined().utf8))
        guard let root = document.sections.first(where: { $0.path == ["mcp_servers", name] }) else { throw XcodeManagementError.unsupported(String(localized: "table racine MCP absente")) }
        var lines = document.lines
        var matches: [Int] = []
        for i in root.range.dropFirst() {
            guard document.assignmentLines.contains(i) else { continue }
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            if ["enabled", "\"enabled\"", "'enabled'"].contains(key ?? "") {
                guard line.range(of: #"^(enabled|"enabled"|'enabled')\s*=\s*(true|false)\s*(#.*)?$"#, options: .regularExpression) != nil else {
                    throw XcodeManagementError.unsupported(String(localized: "la valeur enabled doit être un booléen"))
                }
                matches.append(i)
            }
        }
        guard matches.count <= 1 else { throw XcodeManagementError.unsupported(String(localized: "clé enabled dupliquée")) }
        let newline = lines[root.range.lowerBound].hasSuffix("\r\n") ? "\r\n" : "\n"
        if let index = matches.first {
            lines[index] = "enabled = \(enabled)" + newline
        } else {
            if !lines[root.range.lowerBound].hasSuffix("\n") { lines[root.range.lowerBound] += newline }
            lines.insert("enabled = \(enabled)" + newline, at: root.range.lowerBound + 1)
        }
        return try TOMLServerDocument(Data(lines.joined().utf8)).payload(name)!
    }
    private static func header(_ line: String) throws -> [String] {
        let array = line.hasPrefix("[[")
        var body = String(line.dropFirst(array ? 2 : 1))
        var parts: [String] = []
        while true {
            body = body.trimmingCharacters(in: .whitespaces)
            guard let first = body.first else { throw XcodeManagementError.unsupported(String(localized: "en-tête TOML incomplet")) }
            if first == "\"" || first == "'" {
                var escaped = false
                var closing: String.Index?
                for index in body.indices.dropFirst() {
                    let c = body[index]
                    if escaped { escaped = false }
                    else if c == "\\" && first == "\"" { escaped = true }
                    else if c == first { closing = index; break }
                }
                guard let closing else { throw XcodeManagementError.unsupported(String(localized: "clé TOML incomplète")) }
                let raw = String(body[...closing])
                parts.append(first == "'" ? String(raw.dropFirst().dropLast()) : try JSONDecoder().decode(String.self, from: Data(raw.utf8)))
                body = String(body[body.index(after: closing)...])
            } else {
                let key = body.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
                guard !key.isEmpty else { throw XcodeManagementError.unsupported(String(localized: "clé TOML non reconnue")) }
                parts.append(String(key)); body = String(body.dropFirst(key.count))
            }
            body = body.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix(".") { body.removeFirst(); continue }
            let suffix = array ? "]]" : "]"
            guard body.hasPrefix(suffix) else { throw XcodeManagementError.unsupported(String(localized: "en-tête TOML invalide")) }
            let tail = body.dropFirst(suffix.count).trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { throw XcodeManagementError.unsupported(String(localized: "en-tête TOML invalide")) }
            return parts
        }
    }
}
