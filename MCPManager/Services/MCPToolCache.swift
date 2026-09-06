import CryptoKit
import Foundation

/// Stores tool definitions only, never credentials, protocol logs or diagnostics.
struct MCPToolCache {
    struct Entry: Codable {
        let version: Int
        let key: String
        let savedAt: Date
        let tools: [MCPTool]
    }
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MCPManager/ToolCache", directoryHint: .isDirectory)
    }

    static func key(for server: MCPServer) -> String {
        var identity = server
        // Imported inventories may assign a new UUID after restarting.
        if server.configurationSource != nil || server.xcodeBinding != nil {
            identity.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
        identity.name = ""
        identity.createdAt = Date(timeIntervalSince1970: 0)
        identity.updatedAt = identity.createdAt
        identity.enabled = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(identity)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func load(for server: MCPServer) -> Entry? {
        let key = Self.key(for: server)
        let url = directory.appending(path: key + ".json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2_000_000,
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1, entry.key == key,
              Set(entry.tools.map(\.name)).count == entry.tools.count else { return nil }
        return entry
    }

    @discardableResult func save(_ tools: [MCPTool], for server: MCPServer, at date: Date = .now) throws -> Entry {
        let entry = Entry(version: 1, key: Self.key(for: server), savedAt: date, tools: tools)
        let data = try JSONEncoder().encode(entry)
        guard data.count <= 2_000_000, Set(tools.map(\.name)).count == tools.count else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: entry.key + ".json")
        // Atomic replacement retains the last valid list if the write fails.
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return entry
    }
}
