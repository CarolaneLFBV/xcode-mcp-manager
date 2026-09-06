import Foundation

/// Non-cooperative suspension deliberately models replies arriving after cancellation.
/// Tests control completion explicitly: no subprocess, network, Keychain or sleep.
@MainActor
private final class ReplyGate<Value: Sendable> {
    private var reply: CheckedContinuation<Value, Error>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            precondition(reply == nil)
            reply = continuation
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    func waitUntilRequested() async {
        if reply != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func finish(_ result: Result<Value, Error>) {
        let pending = reply
        reply = nil
        precondition(pending != nil)
        pending?.resume(with: result)
    }
}

@MainActor
private final class FakeMCPSession: MCPSession {
    var processIdentifier: Int32? = 123
    var connectReply: ReplyGate<MCPServerIdentity>?
    var toolsReply: ReplyGate<[MCPTool]>?
    var result = [MCPTool(name: "fixture-tool")]
    var events: MCPSessionEvents?
    var closed = false
    var connections = 0
    var listings = 0
    static var identity: MCPServerIdentity {
        .init(name: "fixture", version: "1", protocolVersion: MCPWire.modernProtocolVersion,
              instructions: nil, era: .modern)
    }

    func connect() async throws -> MCPServerIdentity {
        connections += 1
        return try await connectReply?.value() ?? Self.identity
    }

    func listTools() async throws -> [MCPTool] {
        listings += 1
        return try await toolsReply?.value() ?? result
    }

    func close() { closed = true }
}

@MainActor
enum SupervisorScenarios {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "SupervisorScenarios", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func run(directory: URL) async throws -> [String] {
        var results: [String] = []
        let server = MCPServer(name: "fixture", command: "fixture-never-executed")
        func cache() -> MCPToolCache { MCPToolCache(directory: directory.appending(path: UUID().uuidString)) }

        do {
            var lookups = 0
            let supervisor = MCPProcessSupervisor(toolCache: cache(), resolveCredentials: { _, _ in lookups += 1; return .init() })
            supervisor.startOrCheck(server)
            // Also cancel synchronously, before the newly created task can execute.
            supervisor.stop(server)
            await supervisor.waitForCurrentOperation(for: server)
            await Task.yield()
            try require(lookups == 0, "Immediate stop still read credentials")
            results.append("Immediate cancellation skips credential access")
        }

        // Reserve before credentials suspend, and never launch after a user stop.
        do {
            let credentials = ReplyGate<MCPLocalCredentials>()
            var lookups = 0
            var launches = 0
            let supervisor = MCPProcessSupervisor(toolCache: cache(), resolveCredentials: { _, _ in
                lookups += 1
                return try await credentials.value()
            }, makeSession: { _, _, _, _, _ in launches += 1; return FakeMCPSession() })
            supervisor.startOrCheck(server)
            supervisor.startOrCheck(server)
            await credentials.waitUntilRequested()
            try require(lookups == 1 && supervisor.status(for: server) == .starting, "Duplicate credential lookup")
            Task { @MainActor in
                supervisor.stop(server)
                credentials.finish(.success(.init()))
            }
            await supervisor.waitForCurrentOperation(for: server)
            try require(launches == 0 && supervisor.status(for: server) == .stopped, "Stopped lookup launched a process")
            results.append("Single in-flight lookup and stop before launch")
        }

        // Late handshake success and late errors cannot resurrect or fail a stopped server.
        for fail in [false, true] {
            let gate = ReplyGate<MCPServerIdentity>()
            let session = FakeMCPSession()
            session.connectReply = gate
            let supervisor = MCPProcessSupervisor(toolCache: cache(), resolveCredentials: { _, _ in .init() },
                makeSession: { _, _, _, _, events in session.events = events; return session })
            supervisor.startOrCheck(server)
            await gate.waitUntilRequested()
            Task { @MainActor in
                supervisor.stop(server)
                gate.finish(fail ? .failure(MCPClientError.remoteFailure(detail: "synthetic-sensitive")) : .success(FakeMCPSession.identity))
            }
            await supervisor.waitForCurrentOperation(for: server)
            try require(session.closed && session.listings == 0, "Stopped handshake continued discovery")
            try require(supervisor.status(for: server) == .stopped && supervisor.identities[server.id] == nil
                && supervisor.diagnosticDetails[server.id] == nil, "Late handshake mutated presentation")
        }
        results.append("Late handshake success and failure ignored")

        // A replacement wins even when the previous session replies last, for both transports.
        for transport in MCPServer.Transport.allCases {
            var fixture = server
            fixture.transport = transport
            fixture.url = "https://example.invalid/mcp"
            let toolCache = cache()
            let old = FakeMCPSession(), replacement = FakeMCPSession()
            let gate = ReplyGate<[MCPTool]>()
            old.toolsReply = gate
            replacement.result = [MCPTool(name: "replacement")]
            if transport == .streamableHTTP { old.processIdentifier = nil; replacement.processIdentifier = nil }
            var creations = 0
            let supervisor = MCPProcessSupervisor(toolCache: toolCache, resolveCredentials: { _, _ in .init() },
                makeSession: { _, _, _, _, events in
                    creations += 1
                    let session = creations == 1 ? old : replacement
                    session.events = events
                    return session
                })
            supervisor.startOrCheck(fixture)
            await gate.waitUntilRequested()
            let target = fixture
            Task { @MainActor in
                supervisor.stop(target)
                supervisor.startOrCheck(target)
                await supervisor.waitForCurrentOperation(for: target)
                old.events?.log("obsolete log")
                old.events?.diagnostic(.remoteFailure(detail: "obsolete diagnostic"))
                old.events?.exit(1)
                gate.finish(.success([MCPTool(name: "obsolete")]))
            }
            await supervisor.waitForCurrentOperation(for: target)
            try require(creations == 2 && old.closed && !replacement.closed, "Replacement session closed by old completion")
            try require(supervisor.tools[target.id] == replacement.result && toolCache.load(for: target)?.tools == replacement.result,
                        "Obsolete tools overwrote memory or disk cache")
            try require(supervisor.verifiedToolIDs.contains(target.id) && supervisor.diagnosticDetails[target.id] == nil,
                        "Obsolete callback changed verification or diagnostics")
            try require(!(supervisor.logs[target.id] ?? []).contains { $0.contains("obsolete") }, "Old session logged after replacement")
            let expected: MCPProcessSupervisor.Status = transport == .stdio ? .running(pid: 123) : .reachable(code: 200)
            try require(supervisor.status(for: target) == expected, "Replacement status lost")
            supervisor.stop(target)
        }
        results.append("STDIO and HTTP replacement reject late tools, errors and exits")

        // Changing the connection fingerprint implicitly cancels the old operation.
        do {
            let credentials = ReplyGate<MCPLocalCredentials>()
            var lookups = 0
            let session = FakeMCPSession()
            let supervisor = MCPProcessSupervisor(toolCache: cache(), resolveCredentials: { _, _ in
                lookups += 1
                return lookups == 1 ? try await credentials.value() : .init()
            }, makeSession: { _, _, _, _, events in session.events = events; return session })
            supervisor.startOrCheck(server)
            await credentials.waitUntilRequested()
            var changed = server
            changed.command = "different-fixture-command"
            let replacement = changed
            Task { @MainActor in
                supervisor.startOrCheck(replacement)
                await supervisor.waitForCurrentOperation(for: replacement)
                credentials.finish(.failure(MCPLocalCredentialError.missing))
            }
            await supervisor.waitForCurrentOperation(for: server)
            try require(lookups == 2 && session.connections == 1, "Changed configuration failed to replace lookup")
            try require(supervisor.status(for: replacement) == .running(pid: 123), "Late credential failure overwrote replacement")
            supervisor.stop(replacement)
            results.append("Configuration change rejects old credential failure")
        }

        do {
            let xcode = MCPServer(name: "xcode-fixture", command: "xcrun", arguments: ["mcpbridge"])
            let xcodeSession = FakeMCPSession(), otherSession = FakeMCPSession()
            let supervisor = MCPProcessSupervisor(toolCache: cache(), resolveCredentials: { _, _ in .init() },
                makeSession: { target, _, _, _, events in
                    let session = target.id == xcode.id ? xcodeSession : otherSession
                    session.events = events
                    return session
                })
            try require(!supervisor.canRelinkXcode(xcode), "Relink offered before a failure")
            supervisor.startOrCheck(xcode)
            supervisor.startOrCheck(server)
            await supervisor.waitForCurrentOperation(for: xcode)
            await supervisor.waitForCurrentOperation(for: server)
            xcodeSession.events?.diagnostic(.xcodeTargetMissing(detail: "fixture missing target"))
            try require(supervisor.canRelinkXcode(xcode), "Xcode failure did not offer relink")
            try require(supervisor.status(for: server) == .running(pid: 123) && !otherSession.closed, "Failure closed unrelated session")
            otherSession.events?.diagnostic(.xcodeTargetMissing(detail: "fixture unrelated server"))
            try require(!supervisor.canRelinkXcode(server), "Relink offered for unrelated server")
            supervisor.stop(xcode)
            try require(!supervisor.canRelinkXcode(xcode) && supervisor.diagnosticDetails[xcode.id] == nil, "Stop retained relink/error detail")
            results.append("Independent servers and contextual Xcode relink")
        }

        // Refresh is deduplicated; process exit clears live verification but keeps cached definitions.
        do {
            let session = FakeMCPSession()
            let toolCache = cache()
            var creations = 0
            let supervisor = MCPProcessSupervisor(toolCache: toolCache, resolveCredentials: { _, _ in .init() },
                makeSession: { _, _, _, _, events in creations += 1; session.events = events; return session })
            supervisor.startOrCheck(server)
            await supervisor.waitForCurrentOperation(for: server)
            let gate = ReplyGate<[MCPTool]>()
            session.toolsReply = gate
            supervisor.startOrCheck(server)
            supervisor.startOrCheck(server)
            await gate.waitUntilRequested()
            Task { @MainActor in
                session.events?.exit(1)
                gate.finish(.success([MCPTool(name: "after-exit")]))
            }
            await supervisor.waitForCurrentOperation(for: server)
            try require(creations == 1 && session.connections == 1 && session.listings == 2, "Refresh started a second connection")
            try require(!supervisor.verifiedToolIDs.contains(server.id) && supervisor.identities[server.id] == nil, "Exited session remains verified")
            try require(supervisor.tools[server.id] == session.result && toolCache.load(for: server)?.tools == session.result, "Exit destroyed last known tools")
            if case .failed = supervisor.status(for: server) {} else { throw NSError(domain: "Expected failure after exit", code: 1) }
            results.append("Refresh deduplication and exit retain unverified cache")
        }

        do {
            var disabled = server
            disabled.enabled = false
            var lookups = 0
            let supervisor = MCPProcessSupervisor(toolCache: cache(), resolveCredentials: { _, _ in lookups += 1; return .init() })
            supervisor.startOrCheck(disabled)
            await supervisor.waitForCurrentOperation(for: disabled)
            try require(lookups == 0 && supervisor.status(for: disabled) == .stopped, "Disabled server started")
            results.append("Disabled server cannot start")
        }

        // Graceful termination invalidates in-flight work before closing resources.
        do {
            let session = FakeMCPSession()
            let pending = ReplyGate<[MCPTool]>()
            session.toolsReply = pending
            let supervisor = MCPProcessSupervisor(toolCache: cache(), resolveCredentials: { _, _ in .init() },
                makeSession: { _, _, _, _, events in session.events = events; return session })
            supervisor.startOrCheck(server)
            await pending.waitUntilRequested()
            Task { @MainActor in
                supervisor.shutdown()
                supervisor.shutdown()
                pending.finish(.success([MCPTool(name: "too-late")]))
            }
            await supervisor.waitForCurrentOperation(for: server)
            try require(session.closed && supervisor.status(for: server) == .stopped, "Shutdown did not close the session")
            try require(supervisor.tools[server.id] == nil && supervisor.verifiedToolIDs.isEmpty, "Shutdown accepted late discovery")
            results.append("Idempotent shutdown cancels discovery")
        }

        // Error display policy remains independent of transport and never exposes raw detail in protected logs.
        do {
            let error = MCPClientError.remoteFailure(detail: String(repeating: "s", count: 9000))
            try require(MCPDiagnostics.detail(error)?.count == 8000, "Sensitive detail is not bounded")
            try require(!MCPDiagnostics.message(error, protected: true).contains(String(repeating: "s", count: 10)), "Protected error leaked detail")
            let lines = (0..<300).map(String.init)
            try require(MCPDiagnostics.appending("last", to: lines).count == 250, "Log is not bounded")
            try require(MCPDiagnostics.needsXcodeRelink(MCPClientError.xcodeTargetMissing(detail: "fixture")), "Missing Xcode target not recognized")
            try require(!MCPDiagnostics.needsXcodeRelink(error), "Unrelated error offered relink")
            results.append("Bounded diagnostics and Xcode-only relink classification")
        }

        do {
            var pages = 0
            let tools = try await MCPToolDiscovery.listAll { cursor in
                pages += 1
                try require(cursor == (pages == 1 ? nil : "next"), "Pagination cursor lost")
                var page: [String: JSONValue] = ["tools": .array([.object(["name": .string("tool-\(pages)"), "inputSchema": .object([:])])])]
                if pages == 1 { page["nextCursor"] = .string("next") }
                return .object(page)
            }
            try require(tools.count == 2 && pages == 2, "Pages not accumulated")
            pages = 0
            do {
                _ = try await MCPToolDiscovery.listAll { _ in
                    pages += 1
                    return .object(["tools": .array([]), "nextCursor": .string("loop")])
                }
                throw NSError(domain: "Unbounded pagination", code: 1)
            } catch is MCPClientError { try require(pages == 50, "Wrong pagination bound") }
            results.append("Shared discovery pagination and page limit")
        }
        return results
    }
}
