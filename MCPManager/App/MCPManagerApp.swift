import AppKit
import SwiftUI

@main
struct MCPManagerApp: App {
    @StateObject private var store = MCPServerStore()
    @StateObject private var supervisor = MCPProcessSupervisor()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, supervisor: supervisor)
                .frame(minWidth: 920, minHeight: 620)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    supervisor.shutdown()
                }
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button(String(localized: "Nouveau serveur MCP")) {
                    NotificationCenter.default.post(name: .newMCPServer, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}


extension Notification.Name {
    static let newMCPServer = Notification.Name("newMCPServer")
}
