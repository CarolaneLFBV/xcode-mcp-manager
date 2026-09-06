import Foundation

enum MCPSidebarMode: String, CaseIterable, Identifiable {
    case xcode, catalog
    var id: Self { self }
    var title: String { self == .xcode ? "Xcode" : String(localized: "Catalogue") }
}

struct MCPSidebarGroup: Identifiable {
    let id: String
    let title: String
    let location: String?
    let entries: [XcodeInventoryEntry]
    var symbol: String { location == nil ? "globe" : "folder" }
}

enum MCPSidebarModel {
    static func groups(in inventory: XcodeInventory, query: String) -> [MCPSidebarGroup] {
        let grouped = Dictionary(grouping: inventory.entries) {
            $0.target.projectDirectoryURL?.standardizedFileURL.path ?? "global"
        }
        let groups = grouped.map { key, entries in
            let location = key == "global" ? nil : key
            let title = location.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Globaux")
            let filtered = entries.filter {
                matches(query, in: [$0.server.name, $0.target.kind.shortTitle, title, location ?? "Global"])
            }.sorted {
                let order = $0.server.name.localizedStandardCompare($1.server.name)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.target.kind.rawValue < $1.target.kind.rawValue
            }
            return MCPSidebarGroup(id: key, title: title, location: location, entries: filtered)
        }.filter { !$0.entries.isEmpty }
        return groups.sorted {
            if $0.location == nil { return true }
            if $1.location == nil { return false }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func catalog(_ servers: [MCPServer], query: String) -> [MCPServer] {
        servers.filter { matches(query, in: [$0.name, $0.transport.title]) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func matches(_ query: String, in fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { word in
            fields.contains { $0.localizedStandardContains(String(word)) }
        }
    }
}
