import Foundation

enum CodexConfigRenderer {
    static func render(_ server: MCPServer) -> String {
        let server = MCPEnvironmentService().wrapped(server)
        let escapedName = escape(server.name)
        var lines = ["[mcp_servers.\"\(escapedName)\"]"]

        switch server.transport {
        case .stdio:
            lines.append("command = \"\(escape(server.command))\"")
            if !server.arguments.isEmpty {
                lines.append("args = [\(server.arguments.map { "\"\(escape($0))\"" }.joined(separator: ", "))]")
            }
            if !server.environmentVariableNames.isEmpty {
                let values = server.environmentVariableNames.sorted().map { "\"\(escape($0))\"" }
                lines.append("env_vars = [\(values.joined(separator: ", "))]")
            }
        case .streamableHTTP:
            lines.append("url = \"\(escape(server.url))\"")
            if !server.bearerTokenEnvironmentVariable.isEmpty {
                lines.append("bearer_token_env_var = \"\(escape(server.bearerTokenEnvironmentVariable))\"")
            }
        }

        if !server.enabled {
            lines.append("enabled = false")
        }

        return lines.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
