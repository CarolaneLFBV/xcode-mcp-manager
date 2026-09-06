import SwiftUI

/// Glass belongs to the navigation layer; technical content uses quiet, solid cards.
struct MCPCanvas: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(white: 0.115), Color(white: 0.085)]
                : [Color(white: 0.985), Color(white: 0.955)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct MCPCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(colorScheme == .dark ? Color(white: 0.15) : .white,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.35 : 0.065), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.10 : 0.025), radius: 12, y: 4)
    }
}

private struct MCPGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.mcpCard(radius: radius)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false)
                }
        }
    }
}

struct MCPPanelStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            configuration.label.font(.headline)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mcpCard()
    }
}

private struct MCPProminentButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    // Native glassProminent loses its tint in an inactive window. Own both
    // colors here, including disabled states, instead of overriding its label.
    private var fill: Color {
        Color(white: colorScheme == .dark ? (isEnabled ? 0.92 : 0.26) : (isEnabled ? 0.16 : 0.88))
    }
    private var ink: Color {
        Color(white: colorScheme == .dark ? (isEnabled ? 0.06 : 0.70) : (isEnabled ? 1 : 0.35))
    }
    private var large: Bool { controlSize == .large || controlSize == .extraLarge }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, large ? 18 : 14)
            .padding(.vertical, large ? 10 : 7)
            .background(fill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.primary.opacity(configuration.isPressed ? 0.35 : 0.12))
                    .allowsHitTesting(false)
            }
            .brightness(configuration.isPressed && isEnabled ? (colorScheme == .dark ? -0.06 : 0.06) : 0)
            .contentShape(Capsule())
    }
}

private struct MCPSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large || controlSize == .extraLarge
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, large ? 18 : 14)
            .padding(.vertical, large ? 10 : 7)
            .mcpGlass(radius: 22)
            .overlay {
                Capsule().fill(.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
    }
}

private struct MCPActionStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(MCPProminentButtonStyle())
        } else {
            content.buttonStyle(MCPSecondaryButtonStyle())
        }
    }
}

extension View {
    func mcpCard(radius: CGFloat = 20) -> some View {
        modifier(MCPCardSurface(radius: radius))
    }

    func mcpGlass(radius: CGFloat = 20) -> some View {
        modifier(MCPGlassSurface(radius: radius))
    }

    func mcpActionStyle(prominent: Bool = false) -> some View {
        modifier(MCPActionStyle(prominent: prominent))
    }
}

struct MCPNavigationButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 22)
                Text(title).font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 0)
                if isSelected {
                    Circle().fill(.primary.opacity(0.6)).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14).fill(.clear).mcpGlass(radius: 14)
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(.primary.opacity(isHovered ? 0.045 : 0))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
