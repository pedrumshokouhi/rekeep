import AppKit
import QuickLookThumbnailing
import RekeepKit
import SwiftUI

/// Renders a clip's content. `.card` is compact and clipped; `.preview` shows everything.
struct ClipContentView: View {
    enum Mode { case card, preview }
    let clip: Clip
    var mode: Mode

    var body: some View {
        switch clip.kind {
        case .text, .richText: TextContent(text: clip.text ?? clip.title, mode: mode)
        case .code: CodeContent(text: clip.text ?? "", language: clip.codeLanguage, mode: mode)
        case .link: LinkContent(clip: clip, mode: mode)
        case .image: ImageContent(clip: clip, mode: mode)
        case .color: ColorContent(value: clip.colorValue ?? clip.title, mode: mode)
        case .file: FileContent(clip: clip, mode: mode)
        }
    }
}

/// Fades the bottom edge so truncation reads as "there's more", not as a cut.
private struct BottomFade: ViewModifier {
    var height: CGFloat = 22
    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: height)
            }
        }
    }
}

// MARK: - Text

private struct TextContent: View {
    let text: String
    let mode: ClipContentView.Mode
    @Environment(\.searchTerms) private var terms

    var body: some View {
        switch mode {
        case .card:
            Text(SearchHighlight.attributed(excerpt, terms: terms))
                .font(.cardBody)
                .foregroundStyle(Palette.ink)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .clipped()
                .modifier(BottomFade())
        case .preview:
            ScrollView {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Space.l)
            }
        }
    }

    /// Enough text to fill a card; keeps meaningful line breaks, collapses long blank runs.
    private var excerpt: String {
        let head = String(text.prefix(700))
        var lines: [Substring] = []
        var blankRun = 0
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun > 1 || lines.isEmpty { continue }
            } else {
                blankRun = 0
            }
            lines.append(line)
            if lines.count >= 16 { break }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Code

private struct CodeContent: View {
    let text: String
    let language: String?
    let mode: ClipContentView.Mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch mode {
        case .card:
            // Long lines run off the right edge instead of wrapping, like an editor; the overlay
            // pins the text to the top-leading corner so overflow never spills outside the card.
            Palette.cardSunken
                .overlay(alignment: .topLeading) {
                    Text(SyntaxHighlighter.highlight(String(text.prefix(1200)), language: language, dark: scheme == .dark, maxLines: 18))
                        .font(.cardCode)
                        .lineSpacing(1.5)
                        .fixedSize()
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.cardContent, style: .continuous))
                .modifier(BottomFade(height: 18))
                .padding(.horizontal, Radius.cardInset)
        case .preview:
            ScrollView([.vertical, .horizontal]) {
                Text(SyntaxHighlighter.highlight(text, language: language, dark: scheme == .dark, maxLines: 5000))
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Palette.cardSunken)
        }
    }
}

// MARK: - Link

private struct LinkContent: View {
    let clip: Clip
    let mode: ClipContentView.Mode

    private var host: String {
        guard let host = clip.url?.host() else { return clip.url?.scheme?.uppercased() ?? "Link" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private var path: String {
        guard let url = clip.url else { return clip.title }
        var p = url.path()
        if let q = url.query() { p += "?" + q }
        return p == "/" ? "" : p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: mode == .card ? 6 : 10) {
            Monogram(text: host)
            if let title = clip.linkTitle {
                Text(title).font(mode == .card ? .system(size: 13, weight: .semibold) : .title3.weight(.semibold))
                    .foregroundStyle(Palette.ink).lineLimit(mode == .card ? 2 : 4)
            }
            Text(host)
                .font(mode == .card ? .system(size: 15, weight: .semibold) : .title2.weight(.semibold))
                .foregroundStyle(clip.linkTitle == nil ? Palette.ink : Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !path.isEmpty {
                Text(path)
                    .font(mode == .card ? .system(size: 11.5) : .system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(mode == .card ? 3 : 8)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if mode == .preview, let url = clip.url {
                HStack {
                    Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(Palette.inkTertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, mode == .card ? 10 : Space.xl)
        .padding(.top, mode == .card ? 4 : Space.xl)
        .padding(.bottom, mode == .card ? 0 : Space.l)
    }
}

/// A quiet initial tile. Rekeep doesn't fetch favicons unless link previews are enabled.
private struct Monogram: View {
    let text: String
    var body: some View {
        Text(String(text.first.map(String.init) ?? "·").uppercased())
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Palette.inkSecondary)
            .frame(width: 28, height: 28)
            .background(Palette.chipFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Image

private struct ImageContent: View {
    let clip: Clip
    let mode: ClipContentView.Mode
    @State private var image: NSImage?
    @State private var full: NSImage?
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Palette.cardSunken
            if let shown = (mode == .preview ? (full ?? image) : image) {
                Image(nsImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(mode == .card ? 0 : Space.m)
                    .accessibilityLabel(clip.ocrText.map { "Image containing text: \(String($0.prefix(200)))" } ?? "Image")
            } else {
                Image(systemName: "photo").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.inkTertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.cardContent, style: .continuous))
        .padding(.horizontal, mode == .card ? Radius.cardInset : 0)
        .task(id: clip.id) {
            image = ImageCache.shared.cachedPreview(clip.id)
            if image == nil { image = await ImageCache.shared.preview(for: clip.id, store: app.store) }
            if mode == .preview {
                let store = app.store, id = clip.id
                let data = await Task.detached { store.representations(for: id).first { PasteboardType.imageTypes.contains($0.type) }?.data }.value
                if let data { full = NSImage(data: data) }
            }
        }
    }
}

// MARK: - Colour

private struct ColorContent: View {
    let value: String
    let mode: ClipContentView.Mode
    @Environment(AppModel.self) private var app

    var body: some View {
        let parsed = ColorParser.parse(value)
        let fill = parsed.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) } ?? Palette.cardSunken
        let label: Color = (parsed?.prefersDarkLabel ?? true) ? .black.opacity(0.78) : .white.opacity(0.94)
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: Radius.cardContent, style: .continuous).fill(fill)
                RoundedRectangle(cornerRadius: Radius.cardContent, style: .continuous).strokeBorder(Palette.cardStroke, lineWidth: 0.5)
                Text(value)
                    .font(.system(size: mode == .card ? 15 : 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(label)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(mode == .card ? 10 : Space.l)
            }
            if mode == .preview, let parsed {
                VStack(spacing: 6) {
                    ForEach([("HEX", parsed.hex), ("RGB", parsed.rgbString), ("Original", parsed.original)], id: \.0) { row in
                        HStack {
                            Text(row.0).font(.caption.weight(.semibold)).foregroundStyle(Palette.inkTertiary).frame(width: 64, alignment: .leading)
                            Text(row.1).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Copy") { app.deliver(text: row.1, paste: false) }.controlSize(.small)
                        }
                    }
                }
                .padding(Space.l)
            }
        }
        .padding(.horizontal, mode == .card ? Radius.cardInset : Space.l)
        .padding(.top, mode == .card ? 0 : Space.l)
        .accessibilityLabel("Color \(value)")
    }
}

// MARK: - File

private struct FileContent: View {
    let clip: Clip
    let mode: ClipContentView.Mode
    @State private var thumbnail: NSImage?

    private var first: FileReference? { clip.files.first }
    private var isAvailable: Bool { FileAccess.isAvailable(clip.files) }

    var body: some View {
        VStack(spacing: mode == .card ? 8 : 12) {
            Spacer(minLength: 0)
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else if let first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first.path)).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: mode == .card ? 64 : 160, height: mode == .card ? 64 : 160)
            .opacity(isAvailable ? 1 : 0.45)
            .overlay(alignment: .bottomTrailing) {
                if clip.files.count > 1 {
                    Text("\(clip.files.count)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: Palette.graphite).opacity(0.85), in: Capsule())
                }
            }
            Text(clip.title)
                .font(mode == .card ? .system(size: 12, weight: .medium) : .headline)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            if !isAvailable {
                Label("Original moved or deleted", systemImage: "exclamationmark.triangle")
                    .font(.cardMeta)
                    .foregroundStyle(Palette.danger)
            } else if mode == .preview, let first {
                Text(first.path).font(.caption.monospaced()).foregroundStyle(Palette.inkTertiary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(clip.files.compactMap(FileAccess.resolve)) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .task(id: clip.id) {
            guard let first, let url = FileAccess.resolve(first) else { return }
            let side: CGFloat = mode == .card ? 128 : 320
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = rep.nsImage
            }
        }
    }
}
