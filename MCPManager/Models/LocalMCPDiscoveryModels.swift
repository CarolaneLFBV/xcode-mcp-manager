import Foundation

struct MCPDiscoverySource: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case codex
        case claudeDesktop
        case claudeCode
        case cursor
        case visualStudioCode
        case windsurf
        case xcode
        case xcodeCodex
        case xcodeClaude
        case lldb

        var title: String {
            switch self {
            case .codex: "Codex"
            case .claudeDesktop: "Claude Desktop"
            case .claudeCode: "Claude Code"
            case .cursor: "Cursor"
            case .visualStudioCode: "Visual Studio Code"
            case .windsurf: "Windsurf"
            case .xcode: "Xcode"
            case .xcodeCodex: "Codex dans Xcode"
            case .xcodeClaude: "Claude dans Xcode"
            case .lldb: "LLDB"
            }
        }

        var symbolName: String {
            switch self {
            case .xcode, .xcodeCodex, .xcodeClaude: "hammer"
            case .lldb: "ladybug"
            case .codex, .claudeDesktop, .claudeCode, .cursor, .visualStudioCode, .windsurf:
                "doc.text"
            }
        }
    }

    let kind: Kind
    let location: String
    var id: String { "\(kind.rawValue):\(location)" }
}

struct DiscoveredMCPServer: Identifiable, Hashable, Sendable {
    let id: UUID
    var server: MCPServer
    var sources: [MCPDiscoverySource]
    var warnings: [String]

    init(
        id: UUID = UUID(),
        server: MCPServer,
        sources: [MCPDiscoverySource],
        warnings: [String] = []
    ) {
        self.id = id
        self.server = server
        self.sources = sources
        self.warnings = warnings
    }
}

struct LocalMCPScanResult: Sendable {
    let discoveries: [DiscoveredMCPServer]
    let inspectedLocations: Int
    let unreadableLocations: [String]
}

extension MCPServer {
    var discoverySignature: String {
        switch transport {
        case .stdio:
            return (["stdio", command] + arguments).joined(separator: "\u{1F}")
        case .streamableHTTP:
            return "http\u{1F}\(url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        }
    }
}
