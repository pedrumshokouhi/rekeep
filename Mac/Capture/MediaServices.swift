import AppKit
import RekeepKit
import Vision

/// On-device text recognition for image clips. Runs off the main thread; never touches the network.
nonisolated enum OCRService {
    static func recognize(_ data: Data) async -> String? {
        await Task.detached(priority: .utility) {
            guard let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cg)
            do { try handler.perform([request]) } catch { return nil }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.value
    }
}

/// Caches app icons and decoded previews so scrolling never decodes on the main thread twice.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let previews = NSCache<NSString, NSImage>()
    private var appIcons: [String: NSImage] = [:]

    init() { previews.countLimit = 300 }

    func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = appIcons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        appIcons[bundleID] = icon
        return icon
    }

    func cachedPreview(_ id: UUID) -> NSImage? { previews.object(forKey: id.uuidString as NSString) }

    func preview(for id: UUID, store: ClipStore) async -> NSImage? {
        if let cached = cachedPreview(id) { return cached }
        let data = await Task.detached(priority: .userInitiated) { store.preview(for: id) }.value
        guard let data else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let img = NSImage(data: data) else { return nil }
            // Force decode off the main thread.
            _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return img
        }.value
        if let image { previews.setObject(image, forKey: id.uuidString as NSString) }
        return image
    }

    func invalidate(_ id: UUID) { previews.removeObject(forKey: id.uuidString as NSString) }
}
