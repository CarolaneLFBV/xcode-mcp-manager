import Foundation

/// Transport-independent boundary used by the supervisor and synthetic tests.
/// Implementations own their resources; close must be safe to call more than once.
@MainActor
protocol MCPSession: AnyObject {
    var processIdentifier: Int32? { get }
    func connect() async throws -> MCPServerIdentity
    func listTools() async throws -> [MCPTool]
    func close()
}

/// Events contain no credentials. The owner must reject events from old sessions.
@MainActor
struct MCPSessionEvents {
    var protectLogs = false
    var log: (String) -> Void
    var diagnostic: (MCPClientError) -> Void
    var exit: (Int32) -> Void
}
