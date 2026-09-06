@preconcurrency import Foundation

@MainActor
final class StdioMCPConnection {
    private let process = Process()
    private let standardInput = Pipe()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private var outputBuffer = Data()
    private var nextID = 1
    private var continuations: [Int: CheckedContinuation<Result<JSONValue, MCPClientError>, Never>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var isClosing = false
    private var startupFailure: MCPClientError?
    private var stderrTail = Data()
    private var stdoutTail = Data()
    private var stdoutEnded = false
    private var stderrEnded = false
    private var exitCode: Int32?
    private var finalFailure: MCPClientError?
    private var exitFinalized = false
    private var exitDrainTask: Task<Void, Never>?
    private let onDiagnostic: @MainActor (MCPClientError) -> Void
    private let onLog: @MainActor (String) -> Void
    private let onExit: @MainActor (Int32) -> Void
    private let managedEnvironment: Bool

    init(
        server: MCPServer,
        sourceCredentials: MCPLocalCredentials = MCPLocalCredentials(),
        ignoringEnvironment: Set<String> = [],
        environmentOverrides: [String: String] = [:],
        onDiagnostic: @escaping @MainActor (MCPClientError) -> Void = { _ in },
        onLog: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) {
        self.onLog = onLog
        self.onDiagnostic = onDiagnostic
        self.onExit = onExit
        managedEnvironment = server.environmentProfileID != nil || sourceCredentials.source != nil || sourceCredentials.hasValues
        let launchServer = MCPEnvironmentService().wrapped(server)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [launchServer.command] + launchServer.arguments
        var environment = MCPEnvironmentRuntime.baseEnvironment(ProcessInfo.processInfo.environment)
        if server.environmentProfileID == nil {
            // Forward only variables explicitly requested by this server, not every ambient token.
            for name in server.environmentVariableNames {
                environment[name] = ProcessInfo.processInfo.environment[name]
            }
            environment.merge(sourceCredentials.environment) { _, source in source }
        }
        if let project = server.xcodeBinding?.projectDirectoryURL { process.currentDirectoryURL = project }
        let commonExecutablePaths = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (commonExecutablePaths + [currentPath]).joined(separator: ":")
        process.environment = environment
        for name in ignoringEnvironment { process.environment?.removeValue(forKey: name) }
        for (name, value) in environmentOverrides { process.environment?[name] = value }
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func start() throws {
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self, !self.isClosing, !self.exitFinalized else { return }
                if data.isEmpty { self.stdoutEnded = true; self.finishExitIfReady() }
                else { self.consume(data) }
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self, !self.isClosing, !self.exitFinalized else { return }
                if data.isEmpty { self.stderrEnded = true; self.finishExitIfReady() }
                else {
                    self.stderrTail.append(data)
                    self.stderrTail = Data(self.stderrTail.suffix(3000))
                    self.onLog(String(localized: "Le serveur a écrit sur STDERR (détail réservé au diagnostic protégé)."))
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.processDidExit(process.terminationStatus)
            }
        }
        try process.run()
    }

    func request(method: String, params: JSONValue, timeout: Duration = .seconds(8)) async throws -> JSONValue {
        if !process.isRunning {
            // Let EOF events finish delivering a very short-lived process's output.
            for _ in 0..<60 where !exitFinalized && !isClosing {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard process.isRunning else {
            throw finalFailure ?? startupFailure ?? MCPClientError.invalidMessage(String(localized: "Le processus MCP n’est pas actif."))
        }
        let id = nextID
        nextID += 1
        var data = try MCPWire.requestData(id: id, method: method, params: params)
        data.append(0x0A)

        let outcome: Result<JSONValue, MCPClientError> = await withCheckedContinuation { continuation in
            continuations[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.timeoutRequest(id: id, method: method)
            }
            do {
                try standardInput.fileHandleForWriting.write(contentsOf: data)
            } catch {
                let writeFailure = MCPClientError.invalidMessage(error.localizedDescription)
                Task { [weak self] in
                    guard let self else { return }
                    for _ in 0..<60 where !self.exitFinalized && !self.isClosing {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    self.resolve(id: id, with: .failure(self.finalFailure ?? writeFailure))
                }
            }
        }
        return try outcome.get()
    }

    func notify(method: String, params: JSONValue) throws {
        var data = try MCPWire.notificationData(method: method, params: params)
        data.append(0x0A)
        try standardInput.fileHandleForWriting.write(contentsOf: data)
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        exitDrainTask?.cancel()
        stderrTail.removeAll(); stdoutTail.removeAll(); outputBuffer.removeAll()
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        failAll(with: .closed)
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            var line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty else { continue }
            do {
                let message = try MCPWire.decode(Data(line))
                guard let id = MCPWire.responseID(from: message) else {
                    if let error = message["error"], let text = error["message"]?.stringValue {
                        let failure: MCPClientError = text.contains("MCP_XCODE_PID is not set")
                            ? .xcodeServiceUnavailable(detail: String(text.prefix(8000)))
                            : .rpc(code: error["code"]?.integerValue ?? -32000, message: String(text.prefix(8000)))
                        startupFailure = failure
                        stdoutTail.append(line)
                        stdoutTail = Data(stdoutTail.suffix(3000))
                    }
                    continue
                }
                do {
                    resolve(id: id, with: .success(try MCPWire.result(from: message)))
                } catch let error as MCPClientError {
                    resolve(id: id, with: .failure(error))
                } catch {
                    resolve(id: id, with: .failure(.invalidMessage(error.localizedDescription)))
                }
            } catch {
                stdoutTail.append(line)
                stdoutTail = Data(stdoutTail.suffix(3000))
                onLog(String(localized: "Message STDOUT MCP invalide (détail réservé au diagnostic protégé)."))
            }
        }
    }

    private func resolve(id: Int, with result: Result<JSONValue, MCPClientError>) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuations.removeValue(forKey: id)?.resume(returning: result)
    }

    private func timeoutRequest(id: Int, method: String) {
        resolve(id: id, with: .failure(startupFailure ?? .timeout(method)))
    }

    private func processDidExit(_ code: Int32) {
        guard !isClosing else { return }
        exitCode = code
        finishExitIfReady()
        if !exitFinalized {
            exitDrainTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.finishExitIfReady(force: true)
            }
        }
    }

    private func finishExitIfReady(force: Bool = false) {
        guard !exitFinalized, !isClosing, let code = exitCode,
              force || (stdoutEnded && stderrEnded) else { return }
        // Do not block waiting for a descendant that inherited a pipe.
        if !outputBuffer.isEmpty { consume(Data([0x0A])) }
        exitFinalized = true
        exitDrainTask?.cancel()
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        var detail = "Code de sortie : \(code)\n"
        if !stdoutTail.isEmpty { detail += "\nSTDOUT - derniers messages non standards :\n" + String(decoding: stdoutTail, as: UTF8.self) }
        if !stderrTail.isEmpty { detail += "\n\nSTDERR - derniers messages :\n" + String(decoding: stderrTail, as: UTF8.self) }
        if stdoutTail.isEmpty && stderrTail.isEmpty { detail += String(localized: "Aucun message de diagnostic reçu sur STDOUT ou STDERR.") }
        if force { detail += String(localized: "\nCollecte arrêtée après 500 ms : un flux est peut-être resté ouvert.") }
        let failure: MCPClientError
        if case .xcodeServiceUnavailable = startupFailure { failure = .xcodeServiceUnavailable(detail: detail) }
        else if let startupFailure, startupFailure.allowsLegacyFallback { failure = startupFailure }
        else { failure = .processFailure(code: code, detail: detail) }
        finalFailure = failure
        if code != 0 { onDiagnostic(failure) }
        failAll(with: failure)
        onExit(code)
    }

    private func failAll(with error: MCPClientError) {
        let active = continuations
        continuations.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        active.values.forEach { $0.resume(returning: .failure(error)) }
    }
}
