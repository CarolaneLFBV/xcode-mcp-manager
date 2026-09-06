import Foundation

/// Owns handshake, wire state and process lifetime for one connection.
/// No UI state or cache writes occur here. HTTP work is cancelled by the caller's task.
@MainActor
final class MCPWireSession: MCPSession {
    private let server: MCPServer
    private let credentials: MCPLocalCredentials
    private let ignoringEnvironment: Set<String>
    private let environmentOverrides: [String: String]
    private let events: MCPSessionEvents
    private let protected: Bool
    private var connection: StdioMCPConnection?
    private var processToken: UUID?
    private var identity: MCPServerIdentity?
    private var httpSessionID: String?
    private var closed = false
    private var negotiating = false

    init(server: MCPServer, credentials: MCPLocalCredentials,
         ignoringEnvironment: Set<String>, environmentOverrides: [String: String],
         events: MCPSessionEvents) {
        self.server = server
        self.credentials = credentials
        self.ignoringEnvironment = ignoringEnvironment
        self.environmentOverrides = environmentOverrides
        self.events = events
        protected = events.protectLogs || credentials.source != nil || credentials.hasValues || server.environmentProfileID != nil
    }

    var processIdentifier: Int32? { connection?.processIdentifier }
    private var http: HTTPMCPTransport { HTTPMCPTransport(server: server, sourceCredentials: credentials) }

    func connect() async throws -> MCPServerIdentity {
        try checkOpen()
        negotiating = true
        defer { negotiating = false }
        let result = try await (server.transport == .stdio ? connectSTDIO() : connectHTTP())
        try checkOpen()
        identity = result
        return result
    }

    func listTools() async throws -> [MCPTool] {
        try checkOpen()
        guard let identity else { throw MCPClientError.closed }
        var requestID = 10
        return try await MCPToolDiscovery.listAll { cursor in
            try self.checkOpen()
            let params = MCPWire.params(cursor: cursor, modern: identity.era == .modern)
            if let connection = self.connection {
                return try await connection.request(method: "tools/list", params: params)
            }
            defer { requestID += 1 }
            return try await self.http.request(id: requestID, method: "tools/list", params: params,
                protocolVersion: identity.era == .modern ? MCPWire.modernProtocolVersion : identity.protocolVersion,
                sessionID: self.httpSessionID).result
        }
    }

    func close() {
        closed = true
        processToken = nil
        connection?.close()
        connection = nil
        identity = nil
        httpSessionID = nil
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
    }

    private func launch() throws -> StdioMCPConnection {
        try checkOpen()
        // Invalidate the previous process before closing it: EOF can arrive later.
        let token = UUID()
        processToken = token
        connection?.close()
        let result = StdioMCPConnection(server: server, sourceCredentials: credentials,
            ignoringEnvironment: ignoringEnvironment, environmentOverrides: environmentOverrides,
            onDiagnostic: { [weak self] error in
                guard let self, self.processToken == token, !self.negotiating else { return }
                self.events.diagnostic(error)
            }, onLog: { [weak self] message in
                guard let self, self.processToken == token else { return }
                self.events.log(message)
            }, onExit: { [weak self] code in
                guard let self, self.processToken == token, !self.negotiating else { return }
                self.events.exit(code)
            })
        connection = result
        try result.start()
        return result
    }

    private func connectSTDIO() async throws -> MCPServerIdentity {
        events.log(protected ? String(localized: "Démarrage du serveur avec variables protégées.")
            : String(localized: "Commande : \(([server.command] + server.arguments).joined(separator: " "))"))
        var connection = try launch()
        events.log(String(localized: "Processus démarré (PID \(connection.processIdentifier))."))
        do {
            let result = try await connection.request(method: "server/discover",
                params: .object(["_meta": MCPWire.modernMetadata]), timeout: .seconds(3))
            try checkOpen()
            try MCPWire.validateDiscovery(result)
            let identity = MCPWire.identity(from: result, era: .modern)
            events.log(protected ? String(localized: "Protocole moderne négocié.")
                : String(localized: "Protocole négocié : \(identity.protocolVersion) (moderne)."))
            return identity
        } catch {
            try checkOpen()
            guard (error as? MCPClientError)?.allowsLegacyFallback != false else { throw error }
            events.log(String(localized: "Serveur moderne non détecté, essai du handshake compatible."))
            if !connection.isRunning {
                connection = try launch()
                events.log(String(localized: "Serveur relancé pour le handshake historique."))
            }
            let result = try await connection.request(method: "initialize", params: Self.initializeParams)
            try checkOpen()
            try MCPWire.validateSuccess(result)
            try connection.notify(method: "notifications/initialized", params: .object([:]))
            let identity = MCPWire.identity(from: result, era: .legacy)
            events.log(protected ? String(localized: "Protocole historique négocié.")
                : String(localized: "Protocole négocié : \(identity.protocolVersion) (handshake)."))
            return identity
        }
    }

    private func connectHTTP() async throws -> MCPServerIdentity {
        events.log(protected ? String(localized: "Test HTTP avec authentification protégée.")
            : String(localized: "Négociation avec \(server.url)"))
        let identity: MCPServerIdentity
        do {
            let result = try await http.request(id: 1, method: "server/discover",
                params: .object(["_meta": MCPWire.modernMetadata]), protocolVersion: MCPWire.modernProtocolVersion)
            try checkOpen()
            try MCPWire.validateDiscovery(result.result)
            identity = MCPWire.identity(from: result.result, era: .modern)
        } catch {
            try checkOpen()
            guard (error as? MCPClientError)?.allowsLegacyFallback == true else { throw error }
            events.log(String(localized: "Endpoint historique détecté, exécution du handshake."))
            let result = try await http.request(id: 2, method: "initialize", params: Self.initializeParams)
            try checkOpen()
            try MCPWire.validateSuccess(result.result)
            identity = MCPWire.identity(from: result.result, era: .legacy)
            httpSessionID = result.sessionID
            try await http.notify(method: "notifications/initialized", params: .object([:]),
                protocolVersion: identity.protocolVersion, sessionID: httpSessionID)
            try checkOpen()
        }
        let protocolVersion = identity.era == .modern ? MCPWire.modernProtocolVersion : identity.protocolVersion
        events.log(protected ? String(localized: "Connexion HTTP négociée.")
            : String(localized: "Protocole négocié : \(protocolVersion) — \(identity.name) \(identity.version)."))
        return identity
    }

    private static var initializeParams: JSONValue {
        .object([
            "protocolVersion": .string(MCPWire.latestLegacyProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("MCP Manager"), "version": .string(MCPAppVersion.current)])
        ])
    }
}
