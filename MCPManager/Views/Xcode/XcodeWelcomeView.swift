import AppKit
import SwiftUI

struct XcodeWelcomeView: View {
    @ObservedObject var supervisor: MCPProcessSupervisor
    let onFinish: () -> Void
    @State private var applications: [NSRunningApplication] = []
    @State private var selectedPID: Int32?
    @State private var probe: MCPServer?
    @State private var localError: String?

    private var busy: Bool {
        guard let probe else { return false }
        return supervisor.status(for: probe) == .starting || supervisor.status(for: probe) == .checking
    }
    private var verified: Bool {
        guard let probe, let pid = selectedPID,
              applications.contains(where: { $0.processIdentifier == pid && !$0.isTerminated }),
              case .running = supervisor.status(for: probe) else { return false }
        return supervisor.verifiedToolIDs.contains(probe.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(Constants.welcomeToMcpManager, systemImage: "hammer.circle")
                .font(.title2.weight(.semibold))
            Text(Constants.linkingTitle)
                .font(.largeTitle.weight(.bold))
            Text(Constants.linkingDescription)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label(Constants.openProjectInstruction, systemImage: "macwindow")
                Label(Constants.selectInstanceInstruction, systemImage: "link")
                Label(Constants.approveInXcodeInstruction, systemImage: "checkmark.shield")
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).mcpCard()
            if applications.isEmpty {
                Label(Constants.xcodeIsNotRunningOpenItThenClickRefresh, systemImage: "info.circle")
            } else {
                Picker(Constants.runningXcode, selection: $selectedPID) {
                    Text(Constants.chooseAnInstance).tag(nil as Int32?)
                    ForEach(applications, id: \.processIdentifier) { app in
                        Text("\(app.bundleURL?.lastPathComponent ?? "Xcode") · PID \(app.processIdentifier)")
                            .tag(Optional(app.processIdentifier))
                    }
                }.disabled(busy || verified)
            }
            if busy {
                HStack { ProgressView().controlSize(.small); Text(Constants.verifyingTheLinkAndLoadingTools) }
            } else if verified {
                Label(Constants.linkVerifiedXcodeToolsAreAccessible, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let message = failure {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                if let probe, let detail = supervisor.diagnosticDetails[probe.id] {
                    MCPDiagnosticButton(detail: detail)
                }
            }
            Text(Constants.sessionPrivacyDescription)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(Constants.later, action: onFinish).disabled(busy).keyboardShortcut(.cancelAction)
                Button(Constants.refresh, action: refresh).disabled(busy || verified)
                Spacer()
                if verified {
                    Button(Constants.continueAction) {
                        guard let probe, supervisor.useVerifiedXcodeSession(from: probe) else { return }
                        onFinish()
                    }.mcpActionStyle(prominent: true)
                } else {
                    Button(Constants.linkAndVerify, action: connect)
                        .mcpActionStyle(prominent: true).disabled(selectedPID == nil || busy)
                }
            }
        }.padding(28).frame(width: 620).background { MCPCanvas() }
            .interactiveDismissDisabled()
            .onAppear(perform: refresh)
            .onDisappear { if let probe { supervisor.stop(probe) } }
    }

    private var failure: String? {
        if let localError { return localError }
        if let probe, case .failed(let message) = supervisor.status(for: probe) { return message }
        return nil
    }

    private func refresh() {
        applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.dt.Xcode" && !$0.isTerminated
        }.sorted { $0.processIdentifier < $1.processIdentifier }
        if !applications.contains(where: { $0.processIdentifier == selectedPID }) { selectedPID = nil }
        if applications.count == 1 { selectedPID = applications[0].processIdentifier }
    }

    private func connect() {
        localError = nil
        guard let app = applications.first(where: { $0.processIdentifier == selectedPID && !$0.isTerminated }),
              let bundle = app.bundleURL else {
            refresh(); localError = Constants.instanceClosedError; return
        }
        let bridge = bundle.appending(path: "Contents/Developer/usr/bin/mcpbridge")
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else {
            localError = Constants.unsupportedVersionError; return
        }
        if let probe { supervisor.stop(probe) }
        let server = MCPServer(name: "Liaison Xcode", command: bridge.path)
        probe = server
        supervisor.connectXcode(server, processID: app.processIdentifier)
    }
}

private extension XcodeWelcomeView {
    enum Constants {
        static let welcomeToMcpManager = String(localized: "Bienvenue dans MCP Manager", table: "Localizable")
        static let linkingTitle = String(localized: "Commençons par relier Xcode", table: "Localizable")
        static let linkingDescription = String(localized: "Cette liaison permet au Manager de tester les outils de Xcode. Le catalogue et les autres MCP restent utilisables sans cette étape.", table: "Localizable")
        static let openProjectInstruction = String(localized: "1. Ouvrez Xcode et le projet sur lequel vous souhaitez travailler.", table: "Localizable")
        static let selectInstanceInstruction = String(localized: "2. Choisissez l’instance ci-dessous, puis testez la liaison.", table: "Localizable")
        static let approveInXcodeInstruction = String(localized: "3. Si Xcode demande une autorisation, acceptez-la dans Xcode.", table: "Localizable")
        static let xcodeIsNotRunningOpenItThenClickRefresh = String(localized: "Aucun Xcode ouvert. Ouvrez-le, puis cliquez sur Actualiser.", table: "Localizable")
        static let runningXcode = String(localized: "Xcode ouvert", table: "Localizable")
        static let chooseAnInstance = String(localized: "Choisir une instance…", table: "Localizable")
        static let verifyingTheLinkAndLoadingTools = String(localized: "Vérification de la liaison et chargement des outils…", table: "Localizable")
        static let linkVerifiedXcodeToolsAreAccessible = String(localized: "Liaison vérifiée : les outils Xcode sont accessibles.", table: "Localizable")
        static let sessionPrivacyDescription = String(localized: "Aucune configuration Xcode n’est modifiée. La session reste en mémoire uniquement ; si Xcode redémarre, une nouvelle liaison peut être nécessaire.", table: "Localizable")
        static let later = String(localized: "Plus tard", table: "Localizable")
        static let refresh = String(localized: "Actualiser", table: "Localizable")
        static let continueAction = String(localized: "Continuer", table: "Localizable")
        static let linkAndVerify = String(localized: "Relier et vérifier", table: "Localizable")
        static let instanceClosedError = String(localized: "Cette instance n’est plus ouverte. Actualisez et sélectionnez Xcode.", table: "Localizable")
        static let unsupportedVersionError = String(localized: "Cette version de Xcode ne fournit pas mcpbridge. Utilisez une version de Xcode qui inclut les outils MCP, ou continuez vers le catalogue.", table: "Localizable")
    }
}
