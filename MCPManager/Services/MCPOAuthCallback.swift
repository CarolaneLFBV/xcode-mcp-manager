import Foundation
@preconcurrency import Network

/// Short-lived, loopback-only HTTP receiver. Never renders or logs callback parameters.
@MainActor
final class MCPOAuthCallback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var waiting: CheckedContinuation<String, Error>?
    private var outcome: Result<String, Error>?
    private var timeout: Task<Void, Never>?
    private var sockets: [UUID: NWConnection] = [:]
    private var socketTimeouts: [UUID: Task<Void, Never>] = [:]
    private var redirect: URL?
    private let state: String
    private let issuer: String
    private let requiresIssuer: Bool
    private let callbackPath: String

    init(state: String, issuer: String, requiresIssuer: Bool) throws {
        self.state = state; self.issuer = issuer; self.requiresIssuer = requiresIssuer
        callbackPath = "/oauth/callback/" + (try MCPOAuthSecurity.random())
    }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.finish(.failure(MCPOAuthError.timeout))
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard self.outcome == nil, let port = listener.port,
                                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.callbackPath)") else { return }
                            self.redirect = url; self.ready?.resume(returning: url); self.ready = nil
                        case .failed: self.finish(.failure(MCPOAuthError.network))
                        default: break
                        }
                    }
                }
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func waitForCode() async throws -> String {
        if let outcome { return try outcome.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting = $0 }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel() { finish(.failure(MCPOAuthError.cancelled)) }

    private func accept(_ connection: NWConnection) {
        guard outcome == nil, sockets.count < 8 else { connection.cancel(); return }
        let id = UUID(); sockets[id] = connection
        socketTimeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close(id)
        }
        connection.start(queue: .main)
        receive(id, buffer: Data())
    }

    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = sockets[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.sockets[id] != nil else { return }
                var buffer = buffer; buffer.append(data ?? Data())
                guard buffer.count <= 16384, error == nil else { self.close(id); return }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.handle(id, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
                } else if complete { self.close(id) }
                else { self.receive(id, buffer: buffer) }
            }
        }
    }

    private func handle(_ id: UUID, header: String) {
        guard let redirect, outcome == nil else { respond(id, accepted: false); return }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(redirect.port!)",
              request[1].hasPrefix(callbackPath + "?"),
              let url = URL(string: "http://127.0.0.1:\(redirect.port!)" + request[1]) else { respond(id, accepted: false); return }
        do {
            let code = try MCPOAuthSecurity.callbackCode(url, redirect: redirect, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
            respond(id, accepted: true)
            finish(.success(code), retaining: id)
        } catch MCPOAuthError.cancelled {
            respond(id, accepted: true)
            finish(.failure(MCPOAuthError.cancelled), retaining: id)
        } catch {
            // Stray or forged callbacks never terminate the valid pending attempt.
            respond(id, accepted: false)
        }
    }

    private func respond(_ id: UUID, accepted: Bool) {
        guard let connection = sockets[id] else { return }
        let text = accepted ? String(localized: "Retour reçu. Vous pouvez revenir dans MCP Manager pour voir le résultat.") : String(localized: "Retour invalide. Cette tentative n’a pas été acceptée.")
        let body = Data("<!doctype html><meta charset=utf-8><title>MCP Manager</title><h1>MCP Manager</h1><p>\(text)</p>".utf8)
        var response = Data("HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        socketTimeouts.removeValue(forKey: id)?.cancel()
        sockets.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ result: Result<String, Error>, retaining id: UUID? = nil) {
        guard outcome == nil else { return }
        outcome = result; timeout?.cancel(); timeout = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for key in Array(sockets.keys) where key != id { close(key) }
        if let ready { ready.resume(throwing: result.failure ?? MCPOAuthError.callback); self.ready = nil }
        waiting?.resume(with: result); waiting = nil
    }
}

private extension Result where Success == String, Failure == Error {
    var failure: Error? { if case .failure(let error) = self { return error }; return nil }
}
