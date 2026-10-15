import AppKit
import RekeepKit
import SwiftUI

/// One clip on the shelf or in the library grid. Shared frame; content-specific renderer inside.
struct ClipCard: View {
    let clip: Clip
    var size: CGSize
    var isSelected = false
    var isMultiSelected = false
    var shortcutNumber: Int? = nil
    var collectionAccents: [CollectionAccent] = []
    var onFavorite: (() -> Void)? = nil

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.card, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ClipContentView(clip: clip, mode: .card)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: size.width, height: size.height)
        .contentSurface()
        .overlay {
            // Hover: a quiet surface lift. Never a layout shift.
            if isHovering && !isSelected {
                shape.fill(Palette.ink.opacity(colorScheme == .dark ? 0.035 : 0.02)).allowsHitTesting(false)
            }
        }
        .overlay {
            // Keyboard/primary selection: a 2.5-pt ring offset outside the card (shape cue, not just colour).
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous)
                    .strokeBorder(Palette.jade, lineWidth: 2.5)
                    .padding(-4)
                    .transition(.opacity)
            } else if isMultiSelected {
                RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous)
                    .strokeBorder(Palette.jade.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .padding(-4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isMultiSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Palette.jade)
                    .offset(x: 6, y: -6)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let shortcutNumber {
                Keycap(text: "⌘\(shortcutNumber)")
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.16 : 0.07), radius: isSelected ? 10 : 4, y: isSelected ? 4 : 1.5)
        .scaleEffect(isSelected && !reduceMotion ? 1.0 : 0.985)
        .animation(Motion.micro, value: isSelected)
        .animation(Motion.micro, value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var header: some View {
        HStack(spacing: 6) {
            SourceIcon(bundleID: clip.sourceBundleID, kind: clip.kind)
            Text(ClipFormatting.typeLabel(for: clip))
                .font(.cardTitle)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isHovering, let onFavorite {
                Button(action: onFavorite) {
                    Image(systemName: clip.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(clip.isFavorite ? Palette.favorite : Palette.inkTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(clip.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .transition(.opacity)
            } else if clip.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.favorite)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Favorite")
            }
            Text(ClipFormatting.relative(clip.capturedAt))
                .font(.cardMeta)
                .monospacedDigit()
                .foregroundStyle(Palette.inkTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text(footerText)
                .font(.cardMeta)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if clip.note?.isEmpty == false {
                Image(systemName: "text.bubble").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.inkTertiary)
                    .accessibilityLabel("Has note")
            }
            if clip.expiresAt != nil {
                Image(systemName: "timer").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.inkTertiary)
                    .help("Temporary — deleted automatically")
            }
            if clip.isLocalOnly {
                Image(systemName: "lock").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.inkTertiary)
                    .help("Kept on this Mac only")
            }
            HStack(spacing: 3) {
                ForEach(Array(collectionAccents.prefix(4).enumerated()), id: \.offset) { _, accent in
                    Circle().fill(accent.color).frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private var footerText: String {
        if clip.kind == .text || clip.kind == .code, let note = clip.note, !note.isEmpty { return note }
        return ClipFormatting.detail(for: clip)
    }

    private var accessibilityLabel: String {
        var parts = [ClipFormatting.typeLabel(for: clip), clip.title]
        if let app = clip.sourceAppName { parts.append("from \(app)") }
        parts.append(ClipFormatting.relative(clip.capturedAt))
        if clip.isFavorite { parts.append("favorite") }
        return parts.joined(separator: ", ")
    }
}

/// The source app's icon when known; otherwise a quiet type glyph. Never invents a source.
struct SourceIcon: View {
    var bundleID: String?
    var kind: ClipKind
    var size: CGFloat = 16

    var body: some View {
        if let icon = ImageCache.shared.appIcon(bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: size, height: size)
                .background(Palette.chipFill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
