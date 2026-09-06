import AppKit
import SwiftUI

struct ServerRow: View {
    let server: MCPServer
    let status: MCPProcessSupervisor.Status
    let targets: [XcodeInstallationTarget]?
    var inXcode = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: server.transport == .stdio ? "terminal" : "network")
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(subtitle)
            }
            Spacer()
            if targets?.contains(where: { $0.detectionError != nil }) == true {
                Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .help(Constants.configurationNeedsChecking)
            } else if status != .stopped {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .help("Test local : \(status.title)")
            }
        }
        .opacity(server.enabled ? 1 : 0.55)
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        if inXcode, let target = targets?.first {
            return "\(target.kind.shortTitle) · \(server.transport == .stdio ? "STDIO" : "HTTP")\(target.isDisabled ? Constants.disabled : "")"
        }
        return installationSummary
    }

    private var installationSummary: String {
        guard let targets else { return Constants.checkingXcode }
        let installed = targets.filter(\.isAlreadyConfigured)
        let summary = installed.map { target in
            target.isProjectConfiguration ? target.statusTitle
                : "\(target.kind.shortTitle) · Global\(target.isDisabled ? Constants.disabledParentheticalSuffix : " ✓")"
        }.joined(separator: " · ")
        if targets.contains(where: { $0.detectionError != nil }) {
            return summary.isEmpty ? Constants.xcodeStatusNeedsChecking : summary + Constants.otherScopeNeedsChecking
        }
        return summary.isEmpty ? Constants.notConfiguredGlobally : summary
    }

    private var statusColor: Color {
        switch status {
        case .running, .reachable: .green
        case .starting, .checking: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

private extension ServerRow {
    enum Constants {
        static let configurationNeedsChecking = String(localized: "Configuration à vérifier", table: "Localizable")
        static let disabled = String(localized: " · désactivé", table: "Localizable")
        static let checkingXcode = String(localized: "Vérification Xcode…", table: "Localizable")
        static let disabledParentheticalSuffix = String(localized: " (désactivé)", table: "Localizable")
        static let xcodeStatusNeedsChecking = String(localized: "Xcode · état à vérifier", table: "Localizable")
        static let otherScopeNeedsChecking = String(localized: " · autre portée à vérifier", table: "Localizable")
        static let notConfiguredGlobally = String(localized: "Non configuré globalement", table: "Localizable")
    }
}
