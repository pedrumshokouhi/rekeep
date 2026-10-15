import RekeepKit
import SwiftUI
import UIKit

@Observable
@MainActor
final class KeyboardState {
    enum Scope: String, CaseIterable, Identifiable {
        case recent = "Recent", favorites = "Favorites", snippets = "Snippets"
        var id: String { rawValue }
    }

    var hasFullAccess = false
    var needsGlobe = true
    var scope: Scope = .recent { didSet { load() } }
    private(set) var clips: [Clip] = []
    var note: String?
    var insert: (String) -> Void = { _ in }
    var deleteBackward: () -> Void = {}
    var nextKeyboard: () -> Void = {}
    private var store: ClipStore?

    func load() {
        guard hasFullAccess else { clips = []; return }
        if store == nil { store = try? SharedStorage.openStore(deviceName: nil) }
        guard let store else { return }
        var q = ClipQuery(limit: 40)
        switch scope {
        case .recent: break
        case .favorites: q.favoritesOnly = true
        case .snippets: q.snippetsOnly = true
        }
        // Text-like clips only: a keyboard can insert text, not images or files.
        q.kinds = [.text, .link, .code, .color]
        clips = (try? store.fetch(q)) ?? []
    }

    func use(_ clip: Clip) {
        var text = clip.plainText
        if clip.isTemplate {
            // Built-in values are filled; custom placeholders stay visible to complete by hand.
            let values = Dictionary(uniqueKeysWithValues: TemplateEngine.placeholders(in: text).filter(\.isBuiltIn).map { ($0.name.lowercased(), TemplateEngine.defaultValue(for: $0)) })
            text = TemplateEngine.render(text, values: values)
        }
        insert(text)
        store?.markUsed(clip.id, bringToFront: false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

struct KeyboardView: View {
    @Bindable var state: KeyboardState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(KeyboardState.Scope.allCases) { s in
                    Button { state.scope = s } label: {
                        Text(s.rawValue)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(state.scope == s ? Palette.ink : Palette.inkSecondary)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(state.scope == s ? Palette.chipFillSelected : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state.scope == s ? .isSelected : [])
                }
                Spacer()
                BrandMarkTwoTone(size: 20).opacity(0.9)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if !state.hasFullAccess {
                FullAccessHelp()
            } else if state.clips.isEmpty {
                Text(state.scope == .recent ? "Clips you save in Rekeep appear here." : "Nothing in \(state.scope.rawValue) yet.")
                    .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHGrid(rows: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(state.clips) { clip in
                            Button { state.use(clip) } label: { KeyClipTile(clip: clip) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Insert \(clip.title)")
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.never)
            }

            HStack(spacing: 6) {
                if state.needsGlobe {
                    KeyButton(symbol: "globe", label: "Next keyboard", action: state.nextKeyboard)
                }
                KeyButton(text: "space", label: "Space", wide: true) { state.insert(" ") }
                KeyButton(symbol: "delete.left", label: "Delete", action: state.deleteBackward)
                KeyButton(symbol: "return", label: "Return") { state.insert("\n") }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }
}

private struct KeyClipTile: View {
    let clip: Clip
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: clip.isTemplate ? "curlybraces" : clip.kind.symbol).font(.caption2.weight(.semibold))
                Text(ClipFormatting.typeLabel(for: clip)).font(.caption2.weight(.semibold))
                Spacer(minLength: 0)
                if clip.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.favorite) }
            }
            .foregroundStyle(Palette.inkTertiary)
            if clip.kind == .color, let c = ColorParser.parse(clip.colorValue ?? "") {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)).frame(width: 18, height: 18)
                    Text(clip.colorValue ?? "").font(.footnote.monospaced())
                }
            } else {
                Text(clip.kind == .link ? (clip.url?.host() ?? clip.title) : clip.plainText)
                    .font(clip.kind == .code ? .caption.monospaced() : .footnote)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(width: 150, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke, lineWidth: 0.5))
    }
}

private struct KeyButton: View {
    var symbol: String? = nil
    var text: String? = nil
    var label: String
    var wide = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 17, weight: .regular)) }
                else { Text(text ?? "").font(.system(size: 16)) }
            }
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: wide ? .infinity : 54, minHeight: 42)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct FullAccessHelp: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("Turn on Allow Full Access to see your clips").font(.subheadline.weight(.semibold))
            Text("Settings › Apps › Rekeep › Keyboards. Rekeep needs it only to read your saved clips on this device. The keyboard never records what you type and never uses the internet.")
                .font(.caption).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
