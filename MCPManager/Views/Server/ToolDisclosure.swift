import AppKit
import SwiftUI

struct ToolDisclosure: View {
    let tool: MCPTool

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let description = tool.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                schema(title: Constants.inputSchema, value: tool.inputSchema)
                if let outputSchema = tool.outputSchema {
                    schema(title: Constants.outputSchema, value: outputSchema)
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title ?? tool.name)
                    .fontWeight(.medium)
                if tool.title != nil {
                    Text(tool.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func schema(title: String, value: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.prettyPrinted)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private extension ToolDisclosure {
    enum Constants {
        static let inputSchema = String(localized: "Schéma d’entrée", table: "Localizable")
        static let outputSchema = String(localized: "Schéma de sortie", table: "Localizable")
    }
}
