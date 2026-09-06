import Foundation

/// Inspect only registered or explicitly selected directories. Never walk the user's home,
/// execute project commands, or infer that a detected configuration is loaded by Xcode.
struct XcodeProjectDiscovery: Sendable {
    let codingAssistantDirectory: URL

    init(codingAssistantDirectory: URL? = nil) {
        self.codingAssistantDirectory = codingAssistantDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Developer/Xcode/CodingAssistant")
    }

    func inventory(additionalProjectDirectories: [URL] = []) -> XcodeInventory {
        var result = XcodeInventory()
        var directories = additionalProjectDirectories
        let globalURL = codingAssistantDirectory.appending(path: "codex/config.toml")
        do {
            if let data = try readIfPresent(globalURL) {
                let document = try TOMLServerDocument(data)
                directories += document.sections.compactMap { section in
                    guard section.path.count == 2, section.path[0] == "projects",
                          section.path[1].hasPrefix("/") else { return nil }
                    return URL(fileURLWithPath: section.path[1], isDirectory: true)
                }
            }
        } catch {
            result.errors.append("Projets Codex : impossible de lire la liste dans \(globalURL.path).")
        }

        let uniquePaths = Set(directories.filter { $0.isFileURL }.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        for path in uniquePaths.sorted() {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let url = directory.appending(path: ".codex/config.toml")
            do {
                guard let data = try readIfPresent(url) else { continue }
                let document = try TOMLServerDocument(data)
                let discoveries = try LocalMCPDiscoveryService(includeDeveloperTools: false)
                    .parseCodexConfiguration(data, source: MCPDiscoverySource(kind: .xcodeCodex, location: url.path))
                for name in document.names.sorted() {
                    var server = discoveries.first { $0.server.name == name }?.server ?? MCPServer(name: name)
                    server.scope = .project
                    server.xcodeBinding = XcodeServerBinding(kind: .codex, name: name, projectDirectoryURL: directory)
                    let hash = Array(XcodeMCPManagement.digest(Data("project:codex:\(url.path):\(name)".utf8)).prefix(32))
                    server.id = UUID(uuidString: [String(hash[0..<8]), String(hash[8..<12]), String(hash[12..<16]),
                        String(hash[16..<20]), String(hash[20..<32])].joined(separator: "-"))!
                    result.entries.append(XcodeInventoryEntry(server: server, target: XcodeInstallationTarget(
                        kind: .codex, configurationURL: url, isAvailable: true, isAlreadyConfigured: true,
                        configuredServerName: name, isDisabled: !server.enabled, projectDirectoryURL: directory
                    )))
                }
            } catch {
                result.errors.append("Projet \(directory.lastPathComponent) : configuration illisible ou non prise en charge (\(url.path)).")
            }
        }
        return result
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw XcodeManagementError.unsupported(String(localized: "le fichier de configuration n’est pas un fichier ordinaire."))
        }
        return try Data(contentsOf: url)
    }
}
