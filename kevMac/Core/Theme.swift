import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case rareJade = "Rare Jade"
    case deepOcean = "Deep Ocean"
    case floral = "Floral"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var isTrueDark: Bool { self == .default }

    var accentColor: Color {
        switch self {
        case .default: return Color.accentColor
        case .rareJade: return Color(red: 0.25, green: 0.65, blue: 0.55)
        case .deepOcean: return Color(red: 0.2, green: 0.5, blue: 0.95)
        case .floral: return Color(hex: "#DC308F")
        }
    }

    var palette: ThemePalette? {
        switch self {
        case .default: return nil
        case .rareJade:
            return ThemePalette(
                centerDark: [Color.black.opacity(0.2), Color.black.opacity(0.65)],
                primaryGlow: [Color(red: 0.35, green: 0.85, blue: 0.65).opacity(0.25), Color(red: 0.15, green: 0.55, blue: 0.45).opacity(0.08), .clear],
                diffuseWash: [.clear, Color(red: 0.2, green: 0.6, blue: 0.5).opacity(0.1)],
                animationSpeed: 175.0
            )
        case .deepOcean:
            return ThemePalette(
                centerDark: [Color.black.opacity(0.2), Color.black.opacity(0.7)],
                primaryGlow: [Color(red: 0.2, green: 0.5, blue: 0.95).opacity(0.25), Color(red: 0.1, green: 0.3, blue: 0.7).opacity(0.08), .clear],
                diffuseWash: [.clear, Color(red: 0.1, green: 0.25, blue: 0.6).opacity(0.12)],
                animationSpeed: 175.0
            )
        case .floral:
            return ThemePalette(
                centerDark: [Color.black.opacity(0.15), Color.black.opacity(0.6)],
                primaryGlow: [Color(hex: "#DC308F").opacity(0.20), Color(hex: "#D0A8C9").opacity(0.10), .clear],
                diffuseWash: [.clear, Color(hex: "#DC308F").opacity(0.08)],
                animationSpeed: 175.0
            )
        }
    }
}

struct ThemePalette {
    let centerDark: [Color]
    let primaryGlow: [Color]
    let diffuseWash: [Color]
    let animationSpeed: Double
}

// MARK: - Card background

extension View {
    func cardBackground(_ theme: AppTheme, fillColor: Color? = nil, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background {
                if theme.isTrueDark {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(fillColor ?? Color(red: 0.10, green: 0.10, blue: 0.10))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.isTrueDark ? Color(red: 0.16, green: 0.16, blue: 0.16) : .white.opacity(0.12), lineWidth: 1)
            )
    }
}

// MARK: - Press feedback (instant, on pointer-down)

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Ambient Background View

struct AmbientThemeBackground: View {
    let theme: AppTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var p1 = false
    @State private var p2 = false
    @State private var running = false

    var body: some View {
        ZStack {
            if theme.isTrueDark {
                Color(red: 0.05, green: 0.05, blue: 0.05).ignoresSafeArea()
            } else {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                if let palette = theme.palette {
                    RadialGradient(gradient: Gradient(colors: palette.centerDark), center: .center, startRadius: 0, endRadius: 260)
                    RadialGradient(gradient: Gradient(colors: palette.primaryGlow), center: p1 ? UnitPoint(x: 0.18, y: 0.22) : UnitPoint(x: 0.82, y: 0.78), startRadius: 0, endRadius: 310).blendMode(.screen)
                    RadialGradient(gradient: Gradient(colors: palette.primaryGlow.reversed()), center: p2 ? UnitPoint(x: 0.78, y: 0.20) : UnitPoint(x: 0.22, y: 0.80), startRadius: 0, endRadius: 280).opacity(0.55).blendMode(.screen)
                    LinearGradient(gradient: Gradient(colors: palette.diffuseWash), startPoint: p1 ? .topTrailing : .bottomLeading, endPoint: .center).blendMode(.softLight)
                }
            }
        }
        .onAppear {
            // Reduced motion: show the static gradient, skip the slow ambient drift
            guard !running, !reduceMotion, let speed = theme.palette?.animationSpeed else { return }
            running = true
            withAnimation(.easeInOut(duration: speed).repeatForever(autoreverses: true)) { p1 = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + speed * 0.5) {
                guard running else { return }
                withAnimation(.easeInOut(duration: speed * 1.3).repeatForever(autoreverses: true)) { p2 = true }
            }
        }
        .onDisappear { running = false; p1 = false; p2 = false }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (255, int >> 24, int >> 16 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
