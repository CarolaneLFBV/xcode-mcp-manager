import Foundation
import Combine

/// Owns the installation draft, preflight and warning-consent state.
/// Secrets update the draft only; only install writes a global Xcode target.
@MainActor
final class XcodeInstallationViewModel: ObservableObject {
    enum InstallationState {
        case ready
        case installing
        case installed(XcodeInstallationReceipt)
        case failed(String)
    }

    @Published var server: MCPServer
    let knownToolCount: Int?
    let onInstalled: () -> Void
    let onServerUpdated: (MCPServer) -> Void

    @Published var targets: [XcodeInstallationTarget]
    @Published var selectedKind: XcodeInstallationTarget.Kind
    @Published var installationState: InstallationState = .ready
    @Published var showingEnvironment = false
    @Published var confirmingWarnings = false
    @Published var acknowledgedWarnings: [String] = []
    @Published var configurationChanged = false

    let installer: XcodeMCPInstaller

    init(server: MCPServer, knownToolCount: Int?, preferredTarget: XcodeInstallationTarget.Kind? = nil, installer: XcodeMCPInstaller = XcodeMCPInstaller(), onServerUpdated: @escaping (MCPServer) -> Void = { _ in }, onInstalled: @escaping () -> Void = {}) {
        self.installer = installer
        self.server = server
        self.knownToolCount = knownToolCount
        self.onInstalled = onInstalled
        self.onServerUpdated = onServerUpdated
        let detectedTargets = installer.detectTargets(for: server)
        targets = detectedTargets
        selectedKind = preferredTarget ?? detectedTargets.first(where: {
            $0.kind == .codex && $0.isAvailable
        })?.kind ?? detectedTargets.first?.kind ?? .codex
    }

    var selectedTarget: XcodeInstallationTarget? {
        targets.first { $0.kind == selectedKind }
    }

    var issues: [XcodePreflightIssue] {
        guard let selectedTarget else { return [] }
        return installer.preflight(for: server, target: selectedTarget)
    }

    var hasBlockingIssue: Bool {
        issues.contains { $0.severity == .error }
    }

    var isInstalling: Bool {
        if case .installing = installationState { return true }
        return false
    }

    func requestInstallation() {
        guard !hasBlockingIssue, !isInstalling, selectedTarget != nil else { return }
        acknowledgedWarnings = issues.filter { $0.severity == .warning }.map(\.message)
        if acknowledgedWarnings.isEmpty { install() }
        else { confirmingWarnings = true }
    }

    func install(allowWarnings: Bool = false) {
        guard let selectedTarget, !isInstalling, !hasBlockingIssue else { return }
        let currentWarnings = issues.filter { $0.severity == .warning }.map(\.message)
        if !currentWarnings.isEmpty && (!allowWarnings || currentWarnings != acknowledgedWarnings) {
            acknowledgedWarnings = currentWarnings
            confirmingWarnings = true
            return
        }
        installationState = .installing
        Task {
            do {
                let receipt = try await installer.install(server, into: selectedTarget)
                installationState = .installed(receipt)
                targets = installer.detectTargets(for: server)
                onInstalled()
            } catch {
                installationState = .failed(error.localizedDescription)
            }
        }
    }

    func updateDraft(_ saved: MCPServer) {
        guard !isInstalling else { return }
        server = saved
        configurationChanged = true
        installationState = .ready
        acknowledgedWarnings = []
        targets = installer.detectTargets(for: saved)
        onServerUpdated(saved)
    }

    func selectTarget(_ target: XcodeInstallationTarget) {
        guard target.isAvailable, !isInstalling else { return }
        selectedKind = target.kind
        installationState = .ready
        acknowledgedWarnings = []
    }
}
