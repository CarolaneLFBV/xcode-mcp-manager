import Foundation

/// Synthetic presentation checks. All persistence is scoped to a temporary directory.
enum PresentationScenarios {
    enum Failure: Error { case assertion(String), loading }

    /// A deterministic suspended writer: tests overlapping saves without sleeps or Keychain.
    actor SaveProbe {
        private var started = false
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var writer: CheckedContinuation<Void, Never>?
        func persist() async {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { writer = $0 }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiter = $0 }
        }
        func finish() { writer?.resume(); writer = nil }
    }

    @MainActor
    static func runForms() async throws -> [String] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure.assertion(message) }
        }
        let original = MCPServer(name: "  Example  ", command: "  npx  ")
        let editor = ServerEditorViewModel(server: original)
        editor.argumentsText = "  first \n\n second  "
        editor.environmentText = " API_TOKEN \n\n"
        let prepared = editor.preparedDraft
        try require(prepared.name == "Example" && prepared.command == "npx", "Trim fields")
        try require(prepared.arguments == ["first", "second"] && prepared.environmentVariableNames == ["API_TOKEN"], "Normalize lists")
        try require(original.name == "  Example  " && prepared.id == original.id, "Draft isolation and identity")

        let cancelled = EnvironmentEditorViewModel(server: original, loadDrafts: { _ in [] }, persist: { _, _, _ in
            throw Failure.assertion("Cancellation must not persist")
        })
        cancelled.loadIfNeeded()
        cancelled.drafts = [MCPEnvironmentDraft(name: "API_TOKEN", value: "synthetic-value")]
        cancelled.discard()
        try require(cancelled.drafts.isEmpty && !cancelled.isSaving, "Discard clears memory only")

        let unreadable = EnvironmentEditorViewModel(server: original, loadDrafts: { _ in throw Failure.loading })
        unreadable.loadIfNeeded()
        let blocked = await unreadable.save()
        try require(!unreadable.didLoad && unreadable.error != nil && blocked == nil, "Unreadable profile blocks saving")

        let failing = EnvironmentEditorViewModel(server: original, loadDrafts: { _ in [] }, persist: { _, _, _ in throw Failure.loading })
        failing.loadIfNeeded()
        failing.drafts = [MCPEnvironmentDraft(name: "API_TOKEN", value: "synthetic-value")]
        let failed = await failing.save()
        try require(failed == nil && !failing.isSaving && failing.error != nil && failing.drafts.count == 1, "Failure keeps editable draft")
        try require(!failing.error!.contains("synthetic-value"), "Protected error")

        let probe = SaveProbe()
        let successful = EnvironmentEditorViewModel(server: original, loadDrafts: { _ in [] }, persist: { server, _, _ in
            await probe.persist()
            return server
        })
        successful.loadIfNeeded()
        successful.drafts = [MCPEnvironmentDraft(name: "API_TOKEN", value: "synthetic-value")]
        let first = Task { await successful.save() }
        await probe.waitUntilStarted()
        let second = await successful.save()
        try require(second == nil && successful.isSaving, "Overlapping save is ignored")
        await probe.finish()
        let saved = await first.value
        try require(saved?.id == original.id && successful.drafts.isEmpty && !successful.isSaving, "Successful save clears draft")
        return ["Editor normalization and isolation", "Secret cancellation and protected failures", "Single in-flight secret save"]
    }

    @MainActor
    static func run(catalog: MCPCatalog, directory: URL) throws -> [String] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure.assertion(message) }
        }

        let store = MCPServerStore(fileURL: directory.appending(path: "servers.json"))
        let supervisor = MCPProcessSupervisor(toolCache: MCPToolCache(directory: directory.appending(path: "cache")))
        let manager = ManagerViewModel(store: store, supervisor: supervisor)
        let server = catalog.recipes[0].makeDraft()
        manager.saveEditorDraft(server)
        try require(manager.selection == server.id && manager.sidebarMode == .catalog, "Saved draft selection")
        manager.switchSidebarMode(.xcode)
        try require(manager.selection == nil && manager.selectedServer == nil, "Selection must not leak across modes")
        manager.switchSidebarMode(.catalog)
        manager.selection = server.id
        try require(manager.selectedServer?.id == server.id, "Personal selection")

        var loads = 0
        let catalogModel = CatalogViewModel { loads += 1; return catalog }
        catalogModel.loadIfNeeded()
        catalogModel.loadIfNeeded()
        try require(loads == 1 && catalogModel.failure == nil, "Successful catalog load must be idempotent")
        var attempts = 0
        let retryModel = CatalogViewModel {
            attempts += 1
            if attempts == 1 { throw Failure.loading }
            return catalog
        }
        retryModel.loadIfNeeded()
        try require(retryModel.failure != nil && retryModel.catalog == nil, "Catalog failure state")
        retryModel.loadIfNeeded()
        try require(retryModel.failure == nil && retryModel.catalog != nil, "Catalog retry clears failure")

        let installer = XcodeMCPInstaller(codingAssistantDirectory: directory.appending(path: "absent-agent"), developerToolPaths: [:])
        let installation = XcodeInstallationViewModel(server: server, knownToolCount: 3, installer: installer)
        installation.requestInstallation()
        try require(!installation.isInstalling && installation.hasBlockingIssue, "Unavailable agent must block installation")
        installation.acknowledgedWarnings = ["Old warning"]
        var changed = server
        changed.name = "Synthetic changed draft"
        installation.updateDraft(changed)
        try require(installation.configurationChanged && installation.acknowledgedWarnings.isEmpty, "Draft update invalidates tool proof and consent")
        installation.installationState = .installing
        installation.updateDraft(server)
        try require(installation.server.name == changed.name, "Cannot change a draft during installation")
        return ["Navigation and personal selection", "Catalog loading and retry", "Installation blocking and draft state"]
    }
}
