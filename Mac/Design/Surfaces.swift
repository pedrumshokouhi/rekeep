import SwiftUI

/// The control layer: native Liquid Glass where available, with a deliberate opaque fallback
/// for Reduce Transparency and for systems without glass.
struct ControlSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// QA: render the opaque variant (in-process snapshots can't capture live glass).
    private static var forceSolid: Bool { UserDefaults.standard.bool(forKey: "qa.solid") }

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased || Self.forceSolid {
            content
                .background(Palette.shelfSolid, in: shape)
                .overlay(shape.strokeBorder(Palette.cardStroke, lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
    }
}

extension View {
    func controlSurface<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(ControlSurface(shape: shape, interactive: interactive))
    }

    /// The content layer: stable, near-opaque, readable over any wallpaper.
    func contentSurface(radius: CGFloat = Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Palette.card, in: shape)
            .overlay(shape.strokeBorder(Palette.cardStroke, lineWidth: 0.5))
    }
}

/// A small keycap used in hints and shortcut badges.
struct Keycap: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(Palette.chipFill, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

/// "↩ Paste" style hint.
struct KeyHint: View {
    var keys: [String]
    var label: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { Keycap(text: $0.element) }
            Text(label).font(.hint).foregroundStyle(Palette.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
