import Foundation

/// Bounds discovery independently of either wire transport.
enum MCPToolDiscovery {
    @MainActor
    static func listAll(request: (String?) async throws -> JSONValue) async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        var pageCount = 0
        repeat {
            try Task.checkCancellation()
            let result = try await request(cursor)
            try Task.checkCancellation()
            let page = try MCPWire.tools(from: result)
            tools.append(contentsOf: page.0)
            cursor = page.1
            pageCount += 1
            if pageCount >= 50 && cursor != nil {
                throw MCPClientError.invalidMessage(String(localized: "La pagination des outils dépasse 50 pages."))
            }
        } while cursor != nil
        return tools
    }
}
