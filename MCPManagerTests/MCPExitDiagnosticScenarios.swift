import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum MCPExitDiagnosticScenarios {
    @MainActor static func run() async throws {
        for mode in ["stderr", "unscoped", "empty", "held-pipe"] {
            for _ in 0..<3 {
                let script: String
                switch mode {
                case "stderr": script = "import os; os.write(2,b'PRIVATE_FIXTURE fatal reason without newline'); os.write(1,b'PRIVATE_FIXTURE non-JSON startup output'); os._exit(1)"
                case "unscoped": script = "import os; os.write(1,b'{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"MCP_XCODE_PID is not set PRIVATE_FIXTURE\"}}'); os.write(2,b'PRIVATE_FIXTURE stderr'); os._exit(1)"
                case "held-pipe": script = "import os,time; os.write(2,b'PRIVATE_FIXTURE inherited pipe'); pid=os.fork(); time.sleep(2) if pid == 0 else None; os._exit(1)"
                default: script = "import os; os._exit(1)"
                }
                let server = MCPServer(name: "Exit fixture", command: "/usr/bin/python3", arguments: ["-c", script])
                var logs: [String] = []
                var diagnostic: MCPClientError?
                let connection = StdioMCPConnection(server: server,
                    sourceCredentials: .init(environment: ["TEST_SECRET":"PRIVATE_FIXTURE"]),
                    onDiagnostic: { diagnostic = $0 }, onLog: { logs.append($0) }, onExit: { _ in })
                defer { connection.close() }
                try connection.start()
                do {
                    _ = try await connection.request(method: "initialize", params: .object([:]), timeout: .seconds(3))
                    preconditionFailure("Exited server accepted request")
                } catch let error as MCPClientError {
                    let detail = error.diagnosticDescription
                    if mode == "empty" { precondition(detail.contains("Aucun message de diagnostic reçu")) }
                    else { precondition(detail.contains("PRIVATE_FIXTURE"), "Lost final output: \(mode)") }
                    if mode == "stderr" { precondition(detail.contains("STDOUT") && detail.contains("STDERR")) }
                    if mode == "unscoped" {
                        guard case .xcodeServiceUnavailable = error else { preconditionFailure("Lost startup classification") }
                        precondition(detail.contains("STDERR"))
                    }
                    if mode == "held-pipe" { precondition(detail.contains("500 ms")) }
                    precondition(!error.protectedDescription.contains("PRIVATE_FIXTURE"))
                }
                precondition(diagnostic != nil)
                precondition(!logs.joined().contains("PRIVATE_FIXTURE"))
            }
        }
        print("OK · Arrêts immédiats répétés, STDERR, STDOUT partiel, erreur id:null, silence et flux hérité borné ; logs protégés")
    }
}
