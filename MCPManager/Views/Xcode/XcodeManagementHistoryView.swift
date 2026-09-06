import SwiftUI

struct XcodeManagementHistoryView: View {
    let receipts: [XcodeManagementReceipt]
    let isWorking: Bool
    let error: String?
    let onRestore: (XcodeManagementReceipt) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(Constants.restorationDescription)
                    .foregroundStyle(.secondary)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if receipts.isEmpty {
                    ContentUnavailableView(Constants.noXcodeOperations, systemImage: "clock.arrow.circlepath")
                } else {
                    List(receipts) { receipt in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(receipt.binding.name) · \(receipt.binding.kind.shortTitle)").font(.headline)
                                Text("\(receipt.action.title) · \(receipt.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if (!receipt.completed || receipt.restoring) && !receipt.restored {
                                    Text(Constants.operationInterruptedRestorationRequired).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if receipt.restored { Text(Constants.restored).foregroundStyle(.secondary) }
                            else {
                                Button(Constants.restore) { onRestore(receipt) }
                                    .disabled(isWorking || receipts.contains { $0.binding == receipt.binding && $0.date > receipt.date && !$0.restored })
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }.padding(20)
                .navigationTitle(Constants.xcodeHistory)
                .toolbar { Button(Constants.close) { dismiss() }.disabled(isWorking) }
        }.frame(minWidth: 700, minHeight: 440)
            .interactiveDismissDisabled(isWorking)
    }
}

private extension XcodeManagementHistoryView {
    enum Constants {
        static let restorationDescription = String(localized: "Restaurez la dernière action d’un serveur. Les modifications des autres serveurs sont conservées.", table: "Localizable")
        static let noXcodeOperations = String(localized: "Aucune opération Xcode", table: "Localizable")
        static let operationInterruptedRestorationRequired = String(localized: "Opération interrompue · restauration nécessaire", table: "Localizable")
        static let restored = String(localized: "Restauré", table: "Localizable")
        static let restore = String(localized: "Restaurer", table: "Localizable")
        static let xcodeHistory = String(localized: "Historique Xcode", table: "Localizable")
        static let close = String(localized: "Fermer", table: "Localizable")
    }
}
