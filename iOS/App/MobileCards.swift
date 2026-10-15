import UniformTypeIdentifiers
import QuickLookThumbnailing
import RekeepKit
import SwiftUI
import UIKit

/// The same card language as the Mac shelf, laid out for a vertical feed or an iPad grid.
struct MobileClipCard: View {
    let clip: Clip
    var compact = false
    var isSelected = false
    @Environment(MobileModel.self) private var model

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: clip.isTemplate ? "curlybraces" : clip.kind.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                Text(ClipFormatting.typeLabel(for: clip))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary)
                if let app = clip.sourceAppName {
                    Text("· \(app)").font(.footnote).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if clip.isFavorite {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.favorite).accessibilityLabel("Favorite")
                }
                Text(ClipFormatting.relative(clip.capturedAt))
                    .font(.footnote).monospacedDigit()
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            MobileClipContent(clip: clip, mode: .card(compact: compact))
                .padding(.horizontal, clip.kind == .image || clip.kind == .color || clip.kind == .code ? 6 : 14)

            HStack(spacing: 6) {
                Text(clip.note?.isEmpty == false ? clip.note! : ClipFormatting.detail(for: clip))
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
                Spacer()
                ForEach(Array(model.store.collectionIDs(for: clip.id).compactMap { id in model.collections.first { $0.id == id } }.prefix(4))) { c in
                    Circle().fill(c.accent.color).frame(width: 6, height: 6).accessibilityLabel(c.name)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: shape)
        .overlay(shape.strokeBorder(isSelected ? Palette.jade : Palette.cardStroke, lineWidth: isSelected ? 2.5 : 0.5))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ClipFormatting.typeLabel(for: clip)), \(clip.title), \(ClipFormatting.relative(clip.capturedAt))\(clip.isFavorite ? ", favorite" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

struct MobileClipContent: View {
    enum Mode: Equatable { case card(compact: Bool), detail }
    let clip: Clip
    var mode: Mode
    @Environment(MobileModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.searchTerms) private var terms
    @State private var image: UIImage?

    private var isCard: Bool { if case .card = mode { return true } else { return false } }
    private var compact: Bool { mode == .card(compact: true) }

    var body: some View {
        switch clip.kind {
        case .text, .richText:
            Text(SearchHighlight.attributed(isCard ? String((clip.text ?? clip.title).prefix(600)) : (clip.text ?? clip.title), terms: isCard ? terms : []))
                .font(isCard ? .subheadline : .body)
                .foregroundStyle(Palette.ink)
                .lineLimit(isCard ? (compact ? 4 : 6) : nil)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code:
            ScrollView(.horizontal, showsIndicators: !isCard) {
                Text(SyntaxHighlighter.highlight(isCard ? String((clip.text ?? "").prefix(900)) : (clip.text ?? ""), language: clip.codeLanguage, dark: scheme == .dark, maxLines: isCard ? (compact ? 6 : 9) : 5000))
                    .font(.system(size: isCard ? 12 : 13, design: .monospaced))
                    .lineSpacing(1.5)
                    .fixedSize()
                    .padding(10)
                    .textSelection(.enabled)
            }
            .scrollDisabled(isCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardSunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .link:
            VStack(alignment: .leading, spacing: 4) {
                if let title = clip.linkTitle {
                    Text(title).font(.headline).foregroundStyle(Palette.ink).lineLimit(2)
                }
                Text(host).font(clip.linkTitle == nil ? .headline : .subheadline).foregroundStyle(clip.linkTitle == nil ? Palette.ink : Palette.inkSecondary)
                if let path = path {
                    Text(path).font(.footnote).foregroundStyle(Palette.inkSecondary).lineLimit(isCard ? 2 : nil).truncationMode(.middle)
                }
                if !isCard, let url = clip.url {
                    Link(destination: url) { Label("Open Link", systemImage: "safari") }.padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            ZStack {
                Palette.cardSunken
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .accessibilityLabel(clip.ocrText.map { "Image containing text: \(String($0.prefix(200)))" } ?? "Image")
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(ImageFrame(isCard: isCard, compact: compact, aspect: imageAspect))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task(id: clip.id) { await loadImage() }
        case .color:
            let c = ColorParser.parse(clip.colorValue ?? "")
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(c.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) } ?? Palette.cardSunken)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke, lineWidth: 0.5))
                Text(clip.colorValue ?? "")
                    .font(.system(isCard ? .headline : .title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle((c?.prefersDarkLabel ?? true) ? Color.black.opacity(0.78) : Color.white.opacity(0.94))
                    .padding(12)
            }
            .frame(minHeight: isCard ? (compact ? 72 : 96) : 220)
        case .file:
            HStack(spacing: 12) {
                Image(systemName: "doc.fill").font(.system(size: 30)).foregroundStyle(Palette.inkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.title).font(.headline).foregroundStyle(Palette.ink).lineLimit(2).truncationMode(.middle)
                    Text(ClipFormatting.detail(for: clip)).font(.footnote).foregroundStyle(Palette.inkSecondary)
                    if !clip.files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                        Label("No longer available", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.danger)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var host: String {
        guard let h = clip.url?.host() else { return clip.title }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    private var path: String? {
        guard let url = clip.url else { return nil }
        let p = url.path()
        return p.isEmpty || p == "/" ? nil : p
    }
    private var imageAspect: CGFloat? {
        guard let w = clip.imageWidth, let h = clip.imageHeight, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    private func loadImage() async {
        let store = model.store, id = clip.id, full = !isCard
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            if full { return store.representations(for: id).first { PasteboardType.imageTypes.contains($0.type) }?.data }
            return store.preview(for: id)
        }.value
        guard let data else { return }
        image = await Task.detached { UIImage(data: data)?.preparingForDisplay() }.value
    }
}

/// Cards use a fixed preview height; the detail view keeps the image's own proportions.
private struct ImageFrame: ViewModifier {
    var isCard: Bool
    var compact: Bool
    var aspect: CGFloat?
    func body(content: Content) -> some View {
        if isCard {
            content.frame(height: compact ? 150 : 210)
        } else {
            content.aspectRatio(aspect ?? 1.5, contentMode: .fit)
        }
    }
}
