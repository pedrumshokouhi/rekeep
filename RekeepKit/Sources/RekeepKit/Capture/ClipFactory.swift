import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Platform-neutral description of something captured from a pasteboard, share sheet, or import.
public struct CapturedContent: Sendable {
    public var representations: [Representation]
    public var plainText: String?
    public var fileURLs: [URL]
    public var filesAreImportedCopies: Bool
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var sourceURL: URL?
    public var capturedAt: Date

    public init(representations: [Representation], plainText: String?, fileURLs: [URL] = [], filesAreImportedCopies: Bool = false, sourceBundleID: String? = nil, sourceAppName: String? = nil, sourceURL: URL? = nil, capturedAt: Date = .now) {
        self.representations = representations
        self.plainText = plainText
        self.fileURLs = fileURLs
        self.filesAreImportedCopies = filesAreImportedCopies
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.sourceURL = sourceURL
        self.capturedAt = capturedAt
    }

    public var totalBytes: Int64 { representations.reduce(0) { $0 + Int64($1.data.count) } }
}

/// Well-known pasteboard type identifiers.
public enum PasteboardType {
    public static let plainText = UTType.utf8PlainText.identifier
    public static let rtf = UTType.rtf.identifier
    public static let rtfd = UTType.flatRTFD.identifier
    public static let html = UTType.html.identifier
    public static let url = UTType.url.identifier
    public static let fileURL = UTType.fileURL.identifier
    public static let png = UTType.png.identifier
    public static let tiff = UTType.tiff.identifier
    public static let jpeg = UTType.jpeg.identifier
    public static let heic = UTType.heic.identifier
    public static let pdf = UTType.pdf.identifier
    public static let chromiumSourceURL = "org.chromium.source-url"

    public static let imageTypes: [String] = [png, tiff, jpeg, heic, UTType.gif.identifier, UTType.webP.identifier]

    /// Representations worth keeping, in preference order. Anything else is dropped to save space.
    public static let preserved: [String] = [plainText, rtf, html, url, png, tiff, jpeg, heic, UTType.gif.identifier, pdf, rtfd]
}

/// Turns captured content into a `Clip` plus the representations to persist.
public enum ClipFactory {

    public static func makeClip(from content: CapturedContent, deviceID: String, deviceName: String?) -> (Clip, [Representation])? {
        let reps = content.representations
        let text = normalized(content.plainText)
        let imageRep = PasteboardType.imageTypes.lazy.compactMap { type in reps.first(where: { $0.type == type }) }.first

        // Files
        if !content.fileURLs.isEmpty {
            let files = content.fileURLs.map { url -> FileReference in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
                return FileReference(path: url.path, name: url.lastPathComponent, byteSize: values?.fileSize.map(Int64.init), contentType: values?.contentType?.identifier, isImportedCopy: content.filesAreImportedCopies)
            }
            let title = files.count == 1 ? files[0].name : "\(files.count) files"
            let fp = fingerprint("file", files.map(\.path).joined(separator: "\n"))
            let kept = reps.filter { $0.type == PasteboardType.fileURL || $0.type == PasteboardType.plainText }
            let clip = Clip(kind: .file, title: title, text: nil, files: files, createdAt: content.capturedAt, sourceBundleID: content.sourceBundleID, sourceAppName: content.sourceAppName, sourceURL: content.sourceURL, deviceID: deviceID, deviceName: deviceName, byteSize: bytes(kept), fingerprint: fp)
            return (clip, kept)
        }

        // Images (when there's no meaningful accompanying text)
        let textIsIncidental = text == nil || text.map { ContentClassifier.link(in: $0) != nil } == true
        if let imageRep, textIsIncidental {
            let size = imageSize(imageRep.data)
            let title = size.map { "Image \($0.width) × \($0.height)" } ?? "Image"
            let fp = fingerprint("image", imageRep.data)
            let kept = reps.filter { PasteboardType.imageTypes.contains($0.type) || $0.type == PasteboardType.url || $0.type == PasteboardType.pdf }
            let sourceURL = content.sourceURL ?? text.flatMap { ContentClassifier.link(in: $0) }
            let clip = Clip(kind: .image, title: title, imageWidth: size?.width, imageHeight: size?.height, createdAt: content.capturedAt, sourceBundleID: content.sourceBundleID, sourceAppName: content.sourceAppName, sourceURL: sourceURL, deviceID: deviceID, deviceName: deviceName, byteSize: bytes(kept), fingerprint: fp)
            return (clip, kept)
        }

        guard let text else { return nil }

        var kept = reps.filter { PasteboardType.preserved.contains($0.type) && !PasteboardType.imageTypes.contains($0.type) }
        if !kept.contains(where: { $0.type == PasteboardType.plainText }), let data = text.data(using: .utf8) {
            kept.insert(Representation(type: PasteboardType.plainText, data: data), at: 0)
        }

        var clip = Clip(kind: .text, title: title(for: text), text: text, createdAt: content.capturedAt, sourceBundleID: content.sourceBundleID, sourceAppName: content.sourceAppName, sourceURL: content.sourceURL, deviceID: deviceID, deviceName: deviceName, byteSize: bytes(kept), fingerprint: fingerprint("text", text))

        switch ContentClassifier.classify(text) {
        case .link(let url):
            clip.kind = .link
            clip.url = url
            clip.title = linkTitle(url)
            // A plain link has no formatting worth keeping.
            clip.byteSize = bytes(kept)
        case .color(let color):
            clip.kind = .color
            clip.colorValue = color.original
            clip.title = color.original
        case .code(let language):
            clip.kind = .code
            clip.codeLanguage = language
        case .text:
            break
        }
        return (clip, kept)
    }

    /// Builds a snippet the user typed by hand.
    public static func makeSnippet(text: String, title: String?, deviceID: String, deviceName: String?) -> (Clip, [Representation]) {
        let content = CapturedContent(representations: [Representation(type: PasteboardType.plainText, data: Data(text.utf8))], plainText: text)
        var (clip, reps) = makeClip(from: content, deviceID: deviceID, deviceName: deviceName) ?? (Clip(kind: .text, title: title ?? "Snippet", text: text, deviceID: deviceID, fingerprint: fingerprint("text", text)), [])
        clip.isSnippet = true
        if let title, !title.isEmpty { clip.title = title }
        return (clip, reps)
    }

    // MARK: - Helpers

    public static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        // Normalise line endings, keep meaningful whitespace and indentation.
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return unified.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : unified
    }

    public static func title(for text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.count > 140 ? String(firstLine.prefix(139)) + "…" : firstLine
    }

    public static func linkTitle(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path()
        return path.isEmpty || path == "/" ? trimmedHost : trimmedHost + path
    }

    public static func fingerprint(_ namespace: String, _ text: String) -> String {
        fingerprint(namespace, Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    public static func fingerprint(_ namespace: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(namespace.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(_ reps: [Representation]) -> Int64 { reps.reduce(0) { $0 + Int64($1.data.count) } }

    public static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    /// A downscaled JPEG/PNG preview for cards. Runs off the main thread.
    public static func thumbnail(from data: Data, maxPixel: Int = 720) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        let hasAlpha: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: false
            default: true
            }
        }()
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
