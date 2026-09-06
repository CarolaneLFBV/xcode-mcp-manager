import Foundation
import Darwin

@main
struct MCPEnvironmentLauncher {
    static func main() {
        do { try run() }
        catch {
            // Never echo arguments, profile data, Keychain contents or a child response.
            FileHandle.standardError.write(Data(String(localized: "MCP Manager : variables indisponibles. Vérifiez le profil et l’accès au Trousseau.\n", bundle: MCPLocalization.bundle).utf8))
            exit(78)
        }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--probe" {
            guard args.dropFirst().allSatisfy({ ProcessInfo.processInfo.environment[$0] != nil }) else {
                throw MCPEnvironmentError.invalid("Probe failed")
            }
            print("MCP_MANAGER_ENV_OK")
            return
        }
        guard args.count == 2, ["--profile", "--check"].contains(args[0]), let id = UUID(uuidString: args[1]) else {
            throw MCPEnvironmentError.invalid("Invalid invocation")
        }
        #if MCP_MANAGER_TESTING
        let directory = ProcessInfo.processInfo.environment["MCP_MANAGER_TEST_PROFILE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        let storage = MCPEnvironmentStorage(directory: directory)
        #else
        let storage = MCPEnvironmentStorage()
        #endif
        let profile = try storage.profile(id)
        guard profile.transport == "stdio", !profile.command.isEmpty,
              URL(fileURLWithPath: profile.command).lastPathComponent != "mcp-manager-launcher" else {
            throw MCPEnvironmentError.invalid("Invalid local command")
        }
        let environment = try storage.environment(profile)
        if args[0] == "--check" {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            probe.arguments = ["--probe"] + profile.variables.map(\.name)
            probe.environment = environment
            probe.standardOutput = FileHandle.standardOutput
            probe.standardError = FileHandle.nullDevice
            try probe.run()
            probe.waitUntilExit()
            guard probe.terminationStatus == 0 else { throw MCPEnvironmentError.invalid("Probe failed") }
            return
        }
        let executable: String
        if profile.command.contains("/") {
            executable = URL(fileURLWithPath: profile.command).standardizedFileURL.path
        } else {
            guard let path = (environment["PATH"] ?? "").split(separator: ":").map({ String($0) + "/" + profile.command })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw MCPEnvironmentError.invalid("Command unavailable")
            }
            executable = path
        }
        guard !profile.arguments.contains(where: { $0.utf8.contains(0) }), !executable.utf8.contains(0) else {
            throw MCPEnvironmentError.invalid("Invalid arguments")
        }
        let argv = ([executable] + profile.arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        // Replace the launcher: stdio and process signals belong directly to the MCP server.
        argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { variables in
                _ = execve(executable, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        throw MCPEnvironmentError.invalid("Launch failed")
    }
}
