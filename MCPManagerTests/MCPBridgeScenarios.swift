import Foundation
#if canImport(MCPManager)
@testable import MCPManager
#endif

enum MCPBridgeScenarios {
    @MainActor static func run() async throws {
        let bridgeError: JSONValue = .object(["isError": .bool(true), "content": .array([
            .object(["type": .string("text"), "text": .string("The message contained an unknown method 'server/discover'")])
        ])])
        do { try MCPWire.validateDiscovery(bridgeError); preconditionFailure("False modern handshake") }
        catch let error as MCPClientError { precondition(error.allowsLegacyFallback) }
        do { try MCPWire.validateDiscovery(.object([:])); preconditionFailure("Empty discovery accepted") }
        catch let error as MCPClientError { precondition(error == .unsupportedProtocol) }
        try MCPWire.validateDiscovery(.object(["supportedVersions": .array([.string(MCPWire.modernProtocolVersion)])]))
        let helperError: JSONValue = .object(["isError": .bool(true), "content": .array([
            .object(["text": .string("Error Domain=NSCocoaErrorDomain Code=4099 helper application PRIVATE_FIXTURE")])
        ])])
        do { _ = try MCPWire.tools(from: helperError); preconditionFailure("Error accepted as tools") }
        catch let error as MCPClientError {
            guard case .xcodeServiceUnavailable = error else { preconditionFailure("Wrong error category") }
            precondition(error.diagnosticDescription.contains("PRIVATE_FIXTURE"))
            precondition(!error.protectedDescription.contains("PRIVATE_FIXTURE"))
        }
        for error in [MCPClientError.rpc(code: -1, message: "PRIVATE_FIXTURE"), .invalidMessage("PRIVATE_FIXTURE"), .timeout("PRIVATE_FIXTURE"), .httpStatus(401, "PRIVATE_FIXTURE")] {
            precondition(!error.protectedDescription.contains("PRIVATE_FIXTURE"))
        }

        let root = FileManager.default.temporaryDirectory.appending(path: "bridge-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "bridge.py")
        try Data(#"""
import json, sys, os
initialized = False
notified = False
listed = False
for line in sys.stdin:
    m = json.loads(line)
    method = m['method']
    if method == 'notifications/initialized':
        notified = initialized
        continue
    if method == 'server/discover':
        result = {'isError': True, 'content': [{'type':'text','text': "The message contained an unknown method 'server/discover'"}]}
    elif method == 'initialize':
        initialized = True
        result = {'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'Fixture','version':'1'}}
    elif method == 'tools/list' and notified and not listed and '_meta' not in m.get('params',{}) and os.environ.get('MCP_XCODE_PID') in (None, '4242') and not os.environ.get('MCP_XCODE_SESSION_ID'):
        listed = True
        result = {'tools':[{'name':'bridge_fixture','inputSchema':{'type':'object'}}]}
    elif os.environ.get('MCP_XCODE_PID') == '999999':
        result = {'isError':True,'content':[{'type':'text','text':'Error Domain=RBSAssertionErrorDomain Code=2 Specified target process does not exist PRIVATE_FIXTURE'}]}
    else:
        result = {'isError':True,'content':[{'type':'text','text':'PRIVATE_FIXTURE before initialization'}]}
    print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':result}),flush=True)
"""#.utf8).write(to: script)
        let config = root.appending(path: "config.json")
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["fixture": ["command":"/usr/bin/python3", "args":[script.path], "env":["FIXTURE_SECRET":"PRIVATE_FIXTURE"]]]])
        try data.write(to: config)
        let server = try LocalMCPDiscoveryService(includeDeveloperTools: false).parseJSONConfiguration(data, source: .init(kind: .claudeCode, location: config.path))[0].server
        let cache = MCPToolCache(directory: root.appending(path: "cache"))
        let supervisor = MCPProcessSupervisor(toolCache: cache)
        defer { supervisor.stop(server) }
        supervisor.startOrCheck(server)
        for _ in 0..<400 {
            if supervisor.tools[server.id] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(supervisor.tools[server.id]?.map(\.name) == ["bridge_fixture"], "Fallback did not discover tools")
        let logs = supervisor.logs[server.id, default: []].joined(separator: "\n")
        precondition(logs.contains(String(localized: "Protocole historique négocié.")))
        precondition(!logs.contains(String(localized: "Protocole moderne négocié.")))
        precondition(!logs.contains("PRIVATE_FIXTURE"))
        let restarted = MCPProcessSupervisor(toolCache: cache)
        restarted.restoreCachedTools(for: server)
        precondition(restarted.tools[server.id]?.map(\.name) == ["bridge_fixture"])
        precondition(restarted.status(for: server) == .stopped)
        precondition(!restarted.verifiedToolIDs.contains(server.id))
        supervisor.startOrCheck(server)
        for _ in 0..<400 {
            if supervisor.diagnosticDetails[server.id] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(supervisor.diagnosticDetails[server.id]?.contains("PRIVATE_FIXTURE") == true)
        precondition(supervisor.tools[server.id]?.map(\.name) == ["bridge_fixture"])
        precondition(cache.load(for: server)?.tools.map(\.name) == ["bridge_fixture"])
        precondition(!supervisor.logs[server.id, default: []].joined().contains("PRIVATE_FIXTURE"))
        supervisor.clearLogs(for: server.id)
        precondition(supervisor.diagnosticDetails[server.id] == nil)
        supervisor.startOrCheck(server)
        for _ in 0..<400 {
            if supervisor.diagnosticDetails[server.id] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(supervisor.diagnosticDetails[server.id] != nil)
        supervisor.stop(server)
        precondition(supervisor.diagnosticDetails[server.id] == nil)
        let bridge = root.appending(path: "mcpbridge")
        var executable = Data("#!/usr/bin/python3\n".utf8)
        executable.append(try Data(contentsOf: script))
        try executable.write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let relinkConfig = root.appending(path: "relink.json")
        let relinkData = try JSONSerialization.data(withJSONObject: ["mcpServers": ["fixture": ["command":bridge.path, "args":[], "env":["MCP_XCODE_PID":"999999", "MCP_XCODE_SESSION_ID":"old-session", "FIXTURE_SECRET":"PRIVATE_FIXTURE"]]]])
        try relinkData.write(to: relinkConfig)
        let target = try LocalMCPDiscoveryService(includeDeveloperTools: false).parseJSONConfiguration(relinkData, source: .init(kind: .claudeCode, location: relinkConfig.path))[0].server
        precondition(target.supportsXcodeRelink)
        precondition(!server.supportsXcodeRelink)
        let filtered = try MCPLocalCredentialResolver(inherited: [:]).resolve(target, ignoringEnvironment: MCPProcessSupervisor.xcodeContextVariables)
        precondition(filtered.environment["MCP_XCODE_PID"] == nil)
        precondition(filtered.environment["MCP_XCODE_SESSION_ID"] == nil)
        precondition(filtered.environment["FIXTURE_SECRET"] == "PRIVATE_FIXTURE")
        let relinker = MCPProcessSupervisor(toolCache: cache)
        defer { relinker.stop(target) }
        precondition(!relinker.canRelinkXcode(target))
        relinker.startOrCheck(target)
        for _ in 0..<400 {
            if case .failed = relinker.status(for: target) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed = relinker.status(for: target) else { preconditionFailure("Stale context was not rejected") }
        precondition(relinker.canRelinkXcode(target))
        relinker.relinkXcode(target, processID: 4242)
        for _ in 0..<400 {
            if relinker.tools[target.id] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(relinker.tools[target.id]?.map(\.name) == ["bridge_fixture"])
        try await Task.sleep(for: .milliseconds(100))
        guard case .running = relinker.status(for: target) else { preconditionFailure("Old process exit broke relink") }
        precondition(!relinker.canRelinkXcode(target))
        let afterRelink = try Data(contentsOf: relinkConfig)
        precondition(afterRelink == relinkData)
        precondition(!relinker.logs[target.id, default: []].joined().contains("PRIVATE_FIXTURE"))
        let firstRun = MCPProcessSupervisor(toolCache: cache)
        let probe = MCPServer(name: "First-run probe", command: bridge.path)
        defer { firstRun.stop(probe); firstRun.stop(target) }
        precondition(!firstRun.useVerifiedXcodeSession(from: probe))
        firstRun.connectXcode(probe, processID: 4242)
        for _ in 0..<200 {
            if firstRun.verifiedToolIDs.contains(probe.id) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(firstRun.useVerifiedXcodeSession(from: probe))
        firstRun.stop(probe)
        firstRun.startOrCheck(target)
        for _ in 0..<200 {
            if firstRun.verifiedToolIDs.contains(target.id) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(firstRun.verifiedToolIDs.contains(target.id), "Welcome session did not override stale source context")
        let afterWelcome = try Data(contentsOf: relinkConfig)
        precondition(afterWelcome == relinkData)
        print("OK · Première liaison sans échec préalable, validation réelle et réutilisation de session sans modifier la source")
        print("OK · Relink après échec, PID/session retirés, autres variables conservées, source intacte et ancien processus isolé")
        print("OK · Bridge result/isError, handshake complet, liste des outils et diagnostics sans secrets")
    }
}
