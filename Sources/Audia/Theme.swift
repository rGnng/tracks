import SwiftUI
import AppKit

/// User-selectable highlight color. `system` follows the macOS accent color;
/// the rest mirror the choices in System Settings > Appearance.
enum HighlightColor: String, CaseIterable, Identifiable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .graphite: return "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .system: return Color(nsColor: .controlAccentColor)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .graphite: return Color(nsColor: .systemGray)
        }
    }

    var swatch: AnyShapeStyle {
        if self == .system {
            return AnyShapeStyle(AngularGradient(
                colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                center: .center
            ))
        }
        return AnyShapeStyle(color)
    }

    /// Light accent choices need dark text on filled rows for readability.
    var prefersDarkForeground: Bool {
        let base: NSColor
        switch self {
        case .system: base = .controlAccentColor
        case .blue: base = .systemBlue
        case .purple: base = .systemPurple
        case .pink: base = .systemPink
        case .red: base = .systemRed
        case .orange: base = .systemOrange
        case .yellow: base = .systemYellow
        case .green: base = .systemGreen
        case .graphite: base = .systemGray
        }
        guard let rgb = base.usingColorSpace(.sRGB) else { return false }
        let brightness = 0.299 * rgb.redComponent
            + 0.587 * rgb.greenComponent
            + 0.114 * rgb.blueComponent
        return brightness > 0.55
    }
}

/// iTunes-style palette with automatic light / dark variants.
/// Colors are built as dynamic NSColors so they follow the system appearance.
enum Theme {
    private static func c(_ light: (CGFloat, CGFloat, CGFloat),
                          _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let p = isDark ? dark : light
            return NSColor(calibratedRed: p.0, green: p.1, blue: p.2, alpha: 1)
        })
    }

    // Surfaces. The dark variants use a deeper charcoal palette than the
    // stock system grays so the window reads closer to a true dark UI while
    // keeping borders, rows, and hover states clearly separated.
    static let contentBackground = c((1.00, 1.00, 1.00), (0.055, 0.055, 0.061))
    static let sidebarBackground = c((0.925, 0.929, 0.941), (0.095, 0.095, 0.102))
    static let toolbarTop = c((0.980, 0.980, 0.985), (0.125, 0.125, 0.134))
    static let toolbarBottom = c((0.918, 0.922, 0.933), (0.091, 0.091, 0.099))

    // Text
    static let primaryText = c((0.10, 0.10, 0.11), (0.96, 0.96, 0.97))
    static let secondaryText = c((0.42, 0.42, 0.45), (0.62, 0.62, 0.66))
    static let sidebarHeaderText = c((0.46, 0.46, 0.50), (0.58, 0.58, 0.62))

    // Lines
    static let divider = c((0.80, 0.80, 0.82), (0.155, 0.155, 0.172))

    // Now Playing "LCD" panel in the top bar
    static let lcdTop = c((0.985, 0.988, 1.000), (0.073, 0.075, 0.089))
    static let lcdBottom = c((0.930, 0.936, 0.955), (0.044, 0.044, 0.057))
    static let lcdFill = LinearGradient(
        colors: [lcdTop, lcdBottom],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Empty-player variant: a deeper, dimmer panel shown before anything is
    /// queued. It intentionally has no controls, only the disc glyph.
    static let lcdIdleFill = LinearGradient(
        colors: [
            c((0.955, 0.958, 0.968), (0.040, 0.040, 0.048)),
            c((0.920, 0.924, 0.936), (0.024, 0.024, 0.032)),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Played portion of the seek bar inside the now-playing panel (neutral gray).
    static let lcdProgress = c((0.55, 0.55, 0.58), (0.62, 0.62, 0.66))

    // Selection / accent. `.accentColor` resolves from the environment, so
    // changing the Highlights setting updates every selection surface.
    static var highlight: Color { .accentColor }
    static var highlightForeground: Color {
        let raw = UserDefaults.standard.string(forKey: "highlightColor") ?? ""
        let choice = HighlightColor(rawValue: raw) ?? .system
        return choice.prefersDarkForeground ? .black : .white
    }

    // Table rows
    static let rowAlternate = c((0.968, 0.970, 0.976), (0.074, 0.074, 0.082))
    static let rowHover = c((0.898, 0.937, 0.988), (0.132, 0.132, 0.142))

    // Controls
    static let sidebarHover = c((0.870, 0.870, 0.890), (0.128, 0.128, 0.138))
    static var sidebarSelection: Color { highlight.opacity(0.20) }
    static let controlBackground = c((1.00, 1.00, 1.00), (0.104, 0.104, 0.113))
    static let controlBorder = c((0.760, 0.760, 0.780), (0.218, 0.218, 0.232))
    static let controlFillActive = c((0.900, 0.900, 0.920), (0.176, 0.176, 0.188))
    static let track = c((0.820, 0.820, 0.840), (0.212, 0.212, 0.226))
}
