import SwiftUI

// MARK: - ScopeTheme

enum ScopeTheme {
    // MARK: Radii
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 20
    }

    // MARK: Spacing
    enum Spacing {
        static let xxxs: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: Typography
    enum Font {
        static let caption = SwiftUI.Font.system(size: 10, weight: .medium)
        static let footnote = SwiftUI.Font.system(size: 11, weight: .regular)
        static let footnoteMedium = SwiftUI.Font.system(size: 11, weight: .medium)
        static let footnoteSemibold = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let bodySemibold = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 18, weight: .semibold)
        static let largeNumber = SwiftUI.Font.system(size: 22, weight: .bold, design: .rounded)
        static let mono = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
        static let tag = SwiftUI.Font.system(size: 9, weight: .medium)
    }

    // MARK: Shadows
    enum Shadow {
        static let subtle = ScopeShadow(color: .black.opacity(0.06), radius: 4, y: 1)
        static let medium = ScopeShadow(color: .black.opacity(0.08), radius: 6, y: 2)
        static let elevated = ScopeShadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    // MARK: Colors
    enum Colors {
        static let separator = Color(nsColor: .separatorColor)
        static let windowBg = Color(nsColor: .windowBackgroundColor)
        static let controlBg = Color(nsColor: .controlBackgroundColor)
        static let underPage = Color(nsColor: .underPageBackgroundColor)
        static let textBg = Color(nsColor: .textBackgroundColor)
    }

    // MARK: Opacity
    enum Opacity {
        static let selection: Double = 0.12
        static let hover: Double = 0.08
        static let border: Double = 0.2
        static let subtleBorder: Double = 0.12
        static let badge: Double = 0.1
    }
}

// MARK: - Shadow Model

struct ScopeShadow {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

// MARK: - View Modifiers

struct ScopeCardModifier: ViewModifier {
    var radius: CGFloat = ScopeTheme.Radius.small
    var hasBorder: Bool = false

    func body(content: Content) -> some View {
        content
            .background(ScopeTheme.Colors.controlBg.opacity(0.5), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct ScopeToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ScopeTheme.Colors.windowBg, in: Rectangle())
    }
}

struct ScopeFloatingPanelModifier: ViewModifier {
    var radius: CGFloat = ScopeTheme.Radius.small

    func body(content: Content) -> some View {
        content
            .background(ScopeTheme.Colors.controlBg, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - View Extensions

extension View {
    func scopeCard(radius: CGFloat = ScopeTheme.Radius.small, hasBorder: Bool = true) -> some View {
        modifier(ScopeCardModifier(radius: radius, hasBorder: hasBorder))
    }

    func scopeToolbar() -> some View {
        modifier(ScopeToolbarModifier())
    }

    func scopeFloatingPanel(radius: CGFloat = ScopeTheme.Radius.small) -> some View {
        modifier(ScopeFloatingPanelModifier(radius: radius))
    }

    func scopeShadow(_ shadow: ScopeShadow = ScopeTheme.Shadow.subtle) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }
}

