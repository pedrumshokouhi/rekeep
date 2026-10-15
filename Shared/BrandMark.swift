import SwiftUI

/// The Rekeep mark: two folded forms.
///
/// The first is a ribbon that rises as the stem and folds over into the bowl of an R.
/// The second is a separate tab tucked beneath it, the leg, like a corner folded down to keep
/// a place. The gap between them carries the mark at small sizes and in monochrome.
nonisolated struct BrandMarkFold: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        let o = CGPoint(x: rect.midX - 50 * s, y: rect.midY - 50 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        // Outer ribbon: stem + bowl
        path.move(to: p(23, 84))
        path.addLine(to: p(23, 26))
        path.addQuadCurve(to: p(37, 12), control: p(23, 12))
        path.addLine(to: p(56, 12))
        path.addCurve(to: p(81, 36.5), control1: p(71.5, 12), control2: p(81, 22.5))
        path.addCurve(to: p(56, 61), control1: p(81, 50.5), control2: p(71.5, 61))
        path.addLine(to: p(41, 61))
        path.addLine(to: p(41, 84))
        path.addQuadCurve(to: p(35, 90), control: p(41, 90))
        path.addLine(to: p(29, 90))
        path.addQuadCurve(to: p(23, 84), control: p(23, 90))
        path.closeSubpath()
        // Counter (cut out with even-odd fill)
        path.move(to: p(41, 28.5))
        path.addLine(to: p(55.5, 28.5))
        path.addCurve(to: p(63.5, 36.5), control1: p(60.5, 28.5), control2: p(63.5, 32))
        path.addCurve(to: p(55.5, 44.5), control1: p(63.5, 41), control2: p(60.5, 44.5))
        path.addLine(to: p(41, 44.5))
        path.closeSubpath()
        return path
    }
}

nonisolated struct BrandMarkTab: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        let o = CGPoint(x: rect.midX - 50 * s, y: rect.midY - 50 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        // The tail of the ribbon, tucked behind the bowl.
        path.move(to: p(48, 49))
        path.addLine(to: p(60, 49))
        path.addQuadCurve(to: p(66.3, 52.6), control: p(64, 49))
        path.addLine(to: p(82.4, 83.8))
        path.addQuadCurve(to: p(78.4, 90), control: p(85.2, 90))
        path.addLine(to: p(68.6, 90))
        path.addQuadCurve(to: p(62.4, 86.4), control: p(64.4, 90))
        path.addLine(to: p(45.2, 54.6))
        path.addQuadCurve(to: p(48, 49), control: p(43, 49))
        path.closeSubpath()
        return path
    }
}

/// The mark in a single ink (inherits foreground style), for menus, empty states, and template images.
struct BrandMark: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            BrandMarkTab()
            // A thin gap around the fold, so the tuck reads even in one ink.
            BrandMarkFold().stroke(lineWidth: size * 0.07).blendMode(.destinationOut)
            BrandMarkFold().fill(style: FillStyle(eoFill: true))
        }
        .compositingGroup()
        .frame(width: size, height: size)
        .accessibilityLabel("Rekeep")
    }
}

/// Two-tone mark: graphite fold, jade tab.
struct BrandMarkTwoTone: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            BrandMarkTab().fill(Palette.jade)
            BrandMarkFold().stroke(lineWidth: size * 0.06).blendMode(.destinationOut)
            BrandMarkFold().fill(Palette.ink, style: FillStyle(eoFill: true))
        }
        .compositingGroup()
        .frame(width: size, height: size)
        .accessibilityLabel("Rekeep")
    }
}
