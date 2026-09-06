import AppKit
import SwiftUI

struct StatusBadge: View {
    let status: MCPProcessSupervisor.Status

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .running, .reachable: .green
        case .starting, .checking: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
