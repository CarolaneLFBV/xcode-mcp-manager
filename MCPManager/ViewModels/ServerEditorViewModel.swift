import Foundation
import Combine

/// Normalizes an editable definition without persistence or process side effects.
@MainActor
final class ServerEditorViewModel: ObservableObject {
    @Published var draft: MCPServer
    @Published var argumentsText: String
    @Published var environmentText: String

    init(server: MCPServer) {
        draft = server
        argumentsText = server.arguments.joined(separator: "\n")
        environmentText = server.environmentVariableNames.joined(separator: "\n")
    }

    var preparedDraft: MCPServer {
        var server = draft
        server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.command = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
        server.url = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
        server.bearerTokenEnvironmentVariable = server.bearerTokenEnvironmentVariable
            .trimmingCharacters(in: .whitespacesAndNewlines)
        server.arguments = lines(from: argumentsText)
        server.environmentVariableNames = lines(from: environmentText)
        return server
    }

    private func lines(from value: String) -> [String] {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
