import RekeepKit
import SwiftUI
#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Rekeep's visual language. Every value here is used; nothing is decorative by default.
enum Brand {
    static let name = "Rekeep"
    static let tagline = "Copy once. Keep moving."
}

// MARK: - Colour

extension Color {
    /// Builds a colour that resolves per appearance, including Increase Contrast variants.
    static func dynamic(light: PlatformColor, dark: PlatformColor, lightHC: PlatformColor? = nil, darkHC: PlatformColor? = nil) -> Color {
        #if canImport(AppKit)
        Color(nsColor: PlatformColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: lightHC ?? light
            case .accessibilityHighContrastDarkAqua: darkHC ?? dark
            default: light
            }
        })
        #else
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark { return high ? (darkHC ?? dark) : dark }
            return high ? (lightHC ?? light) : light
        })
        #endif
    }

    init(platform color: PlatformColor) {
        #if canImport(AppKit)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        #if canImport(AppKit)
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        #else
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        #endif
    }
}

enum Palette {
    // Base tokens
    static let porcelain = PlatformColor(hex: 0xF5F5F2)
    static let silver = PlatformColor(hex: 0xE6E8EB)
    static let graphite = PlatformColor(hex: 0x202329)
    static let charcoal = PlatformColor(hex: 0x111318)
    static let jadeBrand = PlatformColor(hex: 0x36B797)

    /// Jade for fills and focus rings: white labels on it meet 4.5:1 (measured), and it holds 4:1 against charcoal.
    static let jade = Color.dynamic(light: PlatformColor(hex: 0x1D8466), dark: PlatformColor(hex: 0x1D8466), lightHC: PlatformColor(hex: 0x14684F), darkHC: PlatformColor(hex: 0x14684F))
    /// Jade for text and glyphs: deepened to meet 4.5:1 on porcelain/white.
    static let jadeInk = Color.dynamic(light: PlatformColor(hex: 0x157A61), dark: PlatformColor(hex: 0x5AD3B2), lightHC: PlatformColor(hex: 0x0D5C48), darkHC: PlatformColor(hex: 0x86EBD0))

    /// Card surface: stable and nearly opaque so content reads over any wallpaper.
    static let card = Color.dynamic(light: PlatformColor(hex: 0xFFFFFF), dark: PlatformColor(hex: 0x1C1F25), lightHC: PlatformColor.white, darkHC: PlatformColor(hex: 0x15171C))
    static let cardSunken = Color.dynamic(light: PlatformColor(hex: 0xF3F3F0), dark: PlatformColor(hex: 0x16191E))
    static let cardStroke = Color.dynamic(light: PlatformColor(white: 0, alpha: 0.08), dark: PlatformColor(white: 1, alpha: 0.08), lightHC: PlatformColor(white: 0, alpha: 0.45), darkHC: PlatformColor(white: 1, alpha: 0.5))
    static let hairline = Color.dynamic(light: PlatformColor(white: 0, alpha: 0.07), dark: PlatformColor(white: 1, alpha: 0.07), lightHC: PlatformColor(white: 0, alpha: 0.35), darkHC: PlatformColor(white: 1, alpha: 0.4))

    static let ink = Color.dynamic(light: graphite, dark: PlatformColor(hex: 0xECEDEF), lightHC: PlatformColor.black, darkHC: PlatformColor.white)
    static let inkSecondary = Color.dynamic(light: PlatformColor(hex: 0x5C616B), dark: PlatformColor(hex: 0xA4A9B2), lightHC: PlatformColor(hex: 0x30343B), darkHC: PlatformColor(hex: 0xD3D6DB))
    static let inkTertiary = Color.dynamic(light: PlatformColor(hex: 0x6B707A), dark: PlatformColor(hex: 0x8E939C), lightHC: PlatformColor(hex: 0x4A4F57), darkHC: PlatformColor(hex: 0xB9BDC4))

    /// Opaque shelf fallback for Reduce Transparency / pre-glass systems.
    static let shelfSolid = Color.dynamic(light: PlatformColor(hex: 0xECECE8), dark: PlatformColor(hex: 0x16181D))
    static let chipFill = Color.dynamic(light: PlatformColor(white: 0, alpha: 0.05), dark: PlatformColor(white: 1, alpha: 0.07))
    static let chipFillSelected = Color.dynamic(light: PlatformColor(white: 0, alpha: 0.09), dark: PlatformColor(white: 1, alpha: 0.14))

    static let danger = Color.dynamic(light: PlatformColor(hex: 0xC23A2E), dark: PlatformColor(hex: 0xF0705F))
    static let favorite = Color.dynamic(light: PlatformColor(hex: 0xB7832F), dark: PlatformColor(hex: 0xE2B45D))
}

extension CollectionAccent {
    /// Muted accents; never saturated enough to compete with content.
    var color: Color {
        switch self {
        case .graphite: Color.dynamic(light: PlatformColor(hex: 0x5E636C), dark: PlatformColor(hex: 0x9EA3AC))
        case .jade: Palette.jade
        case .slate: Color.dynamic(light: PlatformColor(hex: 0x4F6D8F), dark: PlatformColor(hex: 0x86A6C9))
        case .sand: Color.dynamic(light: PlatformColor(hex: 0xA6834E), dark: PlatformColor(hex: 0xD4B07A))
        case .clay: Color.dynamic(light: PlatformColor(hex: 0xB0644B), dark: PlatformColor(hex: 0xDE9076))
        case .plum: Color.dynamic(light: PlatformColor(hex: 0x7D5A86), dark: PlatformColor(hex: 0xB896C1))
        case .moss: Color.dynamic(light: PlatformColor(hex: 0x667A45), dark: PlatformColor(hex: 0xA2B67D))
        case .ocean: Color.dynamic(light: PlatformColor(hex: 0x2F7A8C), dark: PlatformColor(hex: 0x6FB6C6))
        }
    }
}

// MARK: - Geometry (4-pt grid, concentric radii)

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum Radius {
    /// Shelf tray. Inner elements subtract their inset to stay concentric.
    static let shelf: CGFloat = 28
    static let shelfInset: CGFloat = 14
    static let card: CGFloat = shelf - shelfInset            // 14
    static let cardInset: CGFloat = 6
    static let cardContent: CGFloat = card - cardInset       // 8
    static let chip: CGFloat = 9
    static let control: CGFloat = 8
}

/// Card size presets.
enum ShelfDensity: String, CaseIterable, Identifiable, Codable {
    case compact, comfortable, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .large: "Large Preview"
        }
    }
    var cardSize: CGSize {
        switch self {
        case .compact: CGSize(width: 200, height: 204)
        case .comfortable: CGSize(width: 236, height: 244)
        case .large: CGSize(width: 292, height: 300)
        }
    }
    var spacing: CGFloat { self == .compact ? 12 : 14 }
}

enum Motion {
    static let micro = Animation.snappy(duration: 0.14)
    static let panel = Animation.smooth(duration: 0.22)
    static let view = Animation.smooth(duration: 0.28)
    static let reflow = Animation.spring(response: 0.3, dampingFraction: 0.9)
}

// MARK: - Typography

extension Font {
    static let cardTitle = Font.system(size: 12, weight: .semibold)
    static let cardBody = Font.system(size: 12.5, weight: .regular)
    static let cardMeta = Font.system(size: 10.5, weight: .medium)
    static let cardCode = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let chip = Font.system(size: 12, weight: .medium)
    static let hint = Font.system(size: 11, weight: .medium)
}
