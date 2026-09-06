@preconcurrency import Foundation
import Combine

@MainActor
/// Owns live connections, per-server status and bounded in-memory diagnostics.
///
/// A configured server is not necessarily connected. Cached tools are not proof
/// of a live session. Connection tokens reject callbacks from replaced processes.
final class MCPProcessSupervisor: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case running(pid: Int32)
        case checking
        case reachable(code: Int)
        case failed(String)

        var title: String {
            switch self {
            case .stopped: String(localized: "Arrêté")
            case .starting: String(localized: "Négociation…")
            case .running: String(localized: "Connecté")
            case .checking: String(localized: "Inspection…")
            case .reachable: String(localized: "Connecté")
            case .failed: String(localized: "Erreur")
            }
        }

        var isActive: Bool {
            switch self {
            case .starting, .running, .checking, .reachable: true
            case .stopped, .failed: false
            }
        }
    }

    @Published private(set) var statuses: [UUID: Status] = [:]
    @Published private(set) var logs: [UUID: [String]] = [:]
    @Published private(set) var tools: [UUID: [MCPTool]] = [:]
    @Published private(set) var identities: [UUID: MCPServerIdentity] = [:]
    // Never persisted or appended to the ordinary log. One bounded error per server.
    @Published private(set) var diagnosticDetails: [UUID: String] = [:]
    @Published private(set) var toolsUpdatedAt: [UUID: Date] = [:]
    @Published private(set) var verifiedToolIDs: Set<UUID> = []
    private let toolCache: MCPToolCache
    private var toolKeys: [UUID: String] = [:]

    typealias CredentialResolver = @MainActor (MCPServer, Set<String>) async throws -> MCPLocalCredentials
    typealias SessionFactory = @MainActor (MCPServer, MCPLocalCredentials, Set<String>, [String: String], MCPSessionEvents) -> any MCPSession

    private let resolveCredentials: CredentialResolver
    private let makeSession: SessionFactory
    private let validateProfile: @MainActor (MCPServer) throws -> Void

    init(toolCache: MCPToolCache = MCPToolCache(),
         resolveCredentials: @escaping CredentialResolver = { server, ignored in
             if server.transport == .streamableHTTP, MCPOAuthController.shared.hasStored(server) {
                 return try await MCPOAuthController.shared.credentials(server)
             }
             return try await Task.detached {
                 try MCPLocalCredentialResolver().resolve(server, ignoringEnvironment: ignored)
             }.value
         },
         validateProfile: @escaping @MainActor (MCPServer) throws -> Void = { server in
             if server.environmentProfileID != nil { _ = try MCPEnvironmentService().profile(for: server) }
         },
         makeSession: @escaping SessionFactory = { server, credentials, ignored, overrides, events in
             MCPWireSession(server: server, credentials: credentials, ignoringEnvironment: ignored,
                            environmentOverrides: overrides, events: events)
         }) {
        self.toolCache = toolCache
        self.resolveCredentials = resolveCredentials
        self.validateProfile = validateProfile
        self.makeSession = makeSession
    }

    func restoreCachedTools(for server: MCPServer) {
        let key = MCPToolCache.key(for: server)
        guard toolKeys[server.id] != key else { return }
        if toolKeys[server.id] != nil { stop(server) }
        toolKeys[server.id] = key
        let cached = toolCache.load(for: server)
        tools[server.id] = cached?.tools
        toolsUpdatedAt[server.id] = cached?.savedAt
        verifiedToolIDs.remove(server.id)
    }

    private func receivedTools(_ discovered: [MCPTool], for server: MCPServer) {
        tools[server.id] = discovered
        toolsUpdatedAt[server.id] = .now
        verifiedToolIDs.insert(server.id)
        do { try toolCache.save(discovered, for: server, at: toolsUpdatedAt[server.id]!) }
        catch { appendLog(String(localized: "Liste disponible en mémoire, mais son enregistrement local a échoué. Elle ne sera pas conservée après fermeture."), for: server.id) }
    }

    private var sessions: [UUID: any MCPSession] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var operationTokens: [UUID: UUID] = [:]
    private var protectedLogIDs = Set<UUID>()
    private var relinkedXcodeIDs: Set<UUID> = []
    private var xcodeProcessIDs: [UUID: Int32] = [:]
    private var preferredXcodeProcessID: Int32?
    @Published private(set) var xcodeLinkFailures: Set<UUID> = []
    private var sessionTokens: [UUID: UUID] = [:]
    static let xcodeContextVariables: Set<String> = ["MCP_XCODE_PID", "MCP_XCODE_SESSION_ID"]

    func canRelinkXcode(_ server: MCPServer) -> Bool {
        guard server.supportsXcodeRelink, xcodeLinkFailures.contains(server.id) else { return false }
        if case .failed = status(for: server) { return true }
        return false
    }

    func relinkXcode(_ server: MCPServer, processID: Int32) {
        guard canRelinkXcode(server) else { return }
        connectXcode(server, processID: processID)
    }

    // Explicit first-time setup does not require a previous failure.
    func connectXcode(_ server: MCPServer, processID: Int32) {
        guard server.supportsXcodeRelink, processID > 0, server.enabled,
              status(for: server) != .starting, status(for: server) != .checking else { return }
        stop(server)
        relinkedXcodeIDs.insert(server.id)
        xcodeProcessIDs[server.id] = processID
        appendLog(String(localized: "Reliaison locale : instance Xcode choisie (PID \(processID)), ancienne session ignorée. Aucun fichier source n’est modifié."), for: server.id)
        startOrCheck(server)
        if status(for: server) == .stopped { statuses[server.id] = .starting }
    }

    func useVerifiedXcodeSession(from server: MCPServer) -> Bool {
        guard server.supportsXcodeRelink, verifiedToolIDs.contains(server.id),
              case .running = status(for: server), let pid = xcodeProcessIDs[server.id] else { return false }
        preferredXcodeProcessID = pid
        return true
    }

    func status(for server: MCPServer) -> Status { statuses[server.id] ?? .stopped }

    /// One operation per server, reserved before any credential lookup can suspend.
    func startOrCheck(_ server: MCPServer) {
        restoreCachedTools(for: server)
        guard server.enabled else { stop(server); return }
        guard operationTokens[server.id] == nil else { return }
        if server.supportsXcodeRelink, xcodeProcessIDs[server.id] == nil, let pid = preferredXcodeProcessID {
            relinkedXcodeIDs.insert(server.id)
            xcodeProcessIDs[server.id] = pid
        }
        verifiedToolIDs.remove(server.id)
        diagnosticDetails[server.id] = nil
        xcodeLinkFailures.remove(server.id)
        if URL(fileURLWithPath: server.command).lastPathComponent == "mcp-manager-launcher", server.environmentProfileID == nil {
            statuses[server.id] = .failed(String(localized: "Profil du lanceur indisponible. Actualisez l’inventaire ou rétablissez le profil avant de tester."))
            return
        }
        guard server.isValid else {
            statuses[server.id] = .failed(server.validationIssues.joined(separator: " "))
            return
        }
        let token = UUID()
        operationTokens[server.id] = token
        statuses[server.id] = server.transport == .stdio && sessions[server.id] == nil ? .starting : .checking
        tasks[server.id] = Task { [weak self] in
            guard let self else { return }
            await self.inspect(server, token: token)
            // An obsolete completion must never remove a replacement operation.
            if self.operationTokens[server.id] == token {
                self.operationTokens[server.id] = nil
                self.tasks[server.id] = nil
            }
        }
    }

    /// Invalidate first, then cancel and close. Even non-cooperative async work is
    /// unable to publish results, persist tools or resurrect a stopped server.
    func stop(_ server: MCPServer) {
        invalidateOperation(server.id)
        closeSession(server.id)
        xcodeLinkFailures.remove(server.id)
        verifiedToolIDs.remove(server.id)
        diagnosticDetails[server.id] = nil
        identities[server.id] = nil
        appendLog(String(localized: "Arrêt demandé."), for: server.id)
        statuses[server.id] = .stopped
    }

    func clearLogs(for id: UUID) {
        logs[id] = []
        diagnosticDetails[id] = nil
    }

    /// Graceful application termination closes only sessions owned by this manager.
    /// Cached tool definitions are retained; credentials and diagnostics are not saved.
    func shutdown() {
        for id in Set(operationTokens.keys).union(sessions.keys) {
            invalidateOperation(id)
            closeSession(id)
        }
        statuses = statuses.mapValues { _ in .stopped }
        verifiedToolIDs.removeAll()
        identities.removeAll()
        diagnosticDetails.removeAll()
        xcodeLinkFailures.removeAll()
    }

    /// Waits for the operation current at entry, not for a later replacement.
    /// Does not start work; useful to coordinate callers and deterministic tests.
    func waitForCurrentOperation(for server: MCPServer) async {
        let pending = tasks[server.id]
        await pending?.value
    }

    private func isCurrent(_ id: UUID, _ token: UUID) -> Bool {
        operationTokens[id] == token && !Task.isCancelled
    }

    private func invalidateOperation(_ id: UUID) {
        operationTokens[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
    }

    private func closeSession(_ id: UUID) {
        sessionTokens[id] = nil
        sessions.removeValue(forKey: id)?.close()
    }

    private func inspect(_ server: MCPServer, token: UUID) async {
        let id = server.id
        guard isCurrent(id, token) else { return }
        let ignored = server.supportsXcodeRelink && relinkedXcodeIDs.contains(id) ? Self.xcodeContextVariables : []
        let credentials: MCPLocalCredentials
        do {
            credentials = try await resolveCredentials(server, ignored)
            guard isCurrent(id, token) else { return }
            if credentials.source != nil || credentials.hasValues || server.environmentProfileID != nil {
                protectedLogIDs.insert(id)
            }
            if let source = credentials.source {
                appendLog(String(localized: "Configuration source utilisée pour le test : \(source.path). Valeurs conservées en mémoire uniquement."), for: id)
            }
        } catch {
            guard isCurrent(id, token) else { return }
            let message = (error as? MCPOAuthError)?.localizedDescription
                ?? (error as? MCPLocalCredentialError)?.localizedDescription
                ?? String(localized: "Impossible de réutiliser la configuration source en sécurité.")
            statuses[id] = .failed(message)
            appendLog(message, for: id)
            return
        }
        do { try validateProfile(server) }
        catch {
            guard isCurrent(id, token) else { return }
            statuses[id] = .failed(String(localized: "Profil de variables indisponible. Enregistrez à nouveau Variables et secrets."))
            return
        }
        var listingTools = false
        do {
            // HTTP inspection negotiates a fresh authenticated session each time.
            if server.transport == .streamableHTTP { closeSession(id) }
            let session: any MCPSession
            if let existing = sessions[id] {
                session = existing
            } else {
                identities[id] = nil
                let sessionToken = UUID()
                sessionTokens[id] = sessionToken
                let events = MCPSessionEvents(
                    protectLogs: protectedLogIDs.contains(id),
                    log: { [weak self] message in
                        guard let self, self.sessionTokens[id] == sessionToken else { return }
                        self.appendLog(message, for: id)
                    },
                    diagnostic: { [weak self] error in
                        guard let self, self.sessionTokens[id] == sessionToken else { return }
                        let message = self.safeError(error, server: server)
                        self.invalidateOperation(id)
                        self.closeSession(id)
                        self.verifiedToolIDs.remove(id)
                        self.identities[id] = nil
                        self.statuses[id] = .failed(message)
                    },
                    exit: { [weak self] code in
                        guard let self, self.sessionTokens[id] == sessionToken else { return }
                        self.connectionExited(id: id, code: code)
                    })
                let overrides = server.supportsXcodeRelink
                    ? xcodeProcessIDs[id].map { ["MCP_XCODE_PID": String($0)] } ?? [:] : [:]
                session = makeSession(server, credentials, ignored, overrides, events)
                sessions[id] = session
                let identity = try await session.connect()
                guard isCurrent(id, token) else { return }
                identities[id] = identity
            }
            statuses[id] = .checking
            listingTools = true
            let discovered = try await session.listTools()
            guard isCurrent(id, token) else { return }
            receivedTools(discovered, for: server)
            statuses[id] = session.processIdentifier.map { .running(pid: $0) } ?? .reachable(code: 200)
            appendLog(String(localized: "\(discovered.count) outils MCP découverts"), for: id)
        } catch {
            guard isCurrent(id, token) else { return }
            closeSession(id)
            identities[id] = nil
            let message = safeError(error, server: server)
            statuses[id] = .failed(message)
            appendLog(listingTools ? String(localized: "Impossible de lister les outils : \(message)")
                : String(localized: "Échec MCP : \(message)"), for: id)
        }
    }

    private func connectionExited(id: UUID, code: Int32) {
        invalidateOperation(id)
        closeSession(id)
        verifiedToolIDs.remove(id)
        identities[id] = nil
        if case .failed = statuses[id] { return }
        statuses[id] = code == 0 ? .stopped : .failed(String(localized: "Code de sortie \(code)"))
        appendLog(String(localized: "Processus terminé avec le code \(code)."), for: id)
    }

    private func appendLog(_ message: String, for id: UUID) {
        logs[id] = MCPDiagnostics.appending(message, to: logs[id, default: []])
    }

    private func safeError(_ error: Error, server: MCPServer) -> String {
        if let detail = MCPDiagnostics.detail(error) { diagnosticDetails[server.id] = detail }
        if server.supportsXcodeRelink, MCPDiagnostics.needsXcodeRelink(error) {
            xcodeLinkFailures.insert(server.id)
        }
        return MCPDiagnostics.message(error, protected: protectedLogIDs.contains(server.id))
    }
}
