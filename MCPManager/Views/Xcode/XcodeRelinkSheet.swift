import AppKit
import SwiftUI

struct XcodeRelinkSheet: View {
    let onRelink: (Int32) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var applications: [NSRunningApplication] = []
    @State private var selectedPID: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Constants.linkToARunningXcode).font(.title2.weight(.semibold))
            Text(Constants.instanceSelectionDescription)
                .foregroundStyle(.secondary)
            if applications.isEmpty {
                Label(Constants.noRunningInstanceDescription, systemImage: "info.circle")
            } else {
                Picker(Constants.xcodeInstance, selection: $selectedPID) {
                    Text(Constants.chooseAnInstance).tag(nil as Int32?)
                    ForEach(applications, id: \.processIdentifier) { app in
                        Text("\(app.localizedName ?? "Xcode") · PID \(app.processIdentifier) · \(app.bundleURL?.lastPathComponent ?? "")")
                            .tag(Optional(app.processIdentifier))
                    }
                }
            }
            Text(Constants.bridgeRestartDescription)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(Constants.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Constants.refreshList, action: refresh)
                Spacer()
                Button(Constants.linkToThisInstance) {
                    guard let pid = selectedPID, applications.contains(where: { $0.processIdentifier == pid && !$0.isTerminated }) else {
                        refresh(); return
                    }
                    dismiss(); onRelink(pid)
                }.mcpActionStyle(prominent: true).disabled(selectedPID == nil)
            }
        }.padding(24).frame(width: 590).onAppear(perform: refresh)
    }

    private func refresh() {
        applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.dt.Xcode" && !$0.isTerminated
        }.sorted { $0.processIdentifier < $1.processIdentifier }
        if !applications.contains(where: { $0.processIdentifier == selectedPID }) { selectedPID = nil }
        if applications.count == 1 { selectedPID = applications[0].processIdentifier }
    }
}

private extension XcodeRelinkSheet {
    enum Constants {
        static let linkToARunningXcode = String(localized: "Relier à un Xcode ouvert", table: "Localizable")
        static let instanceSelectionDescription = String(localized: "Choisissez l’instance à utiliser pour le test local. L’ancienne session sera ignorée, sans modifier la configuration de l’assistant Xcode.", table: "Localizable")
        static let noRunningInstanceDescription = String(localized: "Aucune instance Xcode ouverte. Ouvrez Xcode et votre projet, puis actualisez cette liste.", table: "Localizable")
        static let xcodeInstance = String(localized: "Instance Xcode", table: "Localizable")
        static let chooseAnInstance = String(localized: "Choisir une instance…", table: "Localizable")
        static let bridgeRestartDescription = String(localized: "Le Manager relancera uniquement son bridge. Ce choix reste actif jusqu’à la fermeture du Manager. Une autorisation peut être demandée par Xcode.", table: "Localizable")
        static let cancel = String(localized: "Annuler", table: "Localizable")
        static let refreshList = String(localized: "Actualiser la liste", table: "Localizable")
        static let linkToThisInstance = String(localized: "Relier à cette instance", table: "Localizable")
    }
}
