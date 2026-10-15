import Foundation
import RekeepKit
import UniformTypeIdentifiers

/// Where the library lives, and settings shared between the app and its extensions.
nonisolated enum SharedStorage {
    static let appGroup = "group.com.pedrumshokouhi.rekeep"

    /// iOS: the App Group container, so the Share extension writes to the same library.
    /// macOS: the app's own sandbox container.
    static var libraryDirectory: URL {
        #if os(iOS)
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return container.appendingPathComponent("Library/Application Support/Rekeep", isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rekeep", isDirectory: true)
    }

    static var defaults: UserDefaults {
        #if os(iOS)
        UserDefaults(suiteName: appGroup) ?? .standard
        #else
        .standard
        #endif
    }

    static func openStore(deviceName: String?) throws -> ClipStore {
        try ClipStore(directory: libraryDirectory, deviceName: deviceName)
    }

    /// Privacy settings, readable by extensions.
    static var privacy: PrivacySettings {
        get {
            guard let data = defaults.data(forKey: "rekeep.privacy"), let s = try? JSONDecoder().decode(PrivacySettings.self, from: data) else { return PrivacySettings() }
            return s
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "rekeep.privacy") }
    }
}

/// Converts item providers (Paste button, Share sheet, drag and drop) into captured content.
nonisolated enum ProviderImporter {
    static func content(from providers: [NSItemProvider], sourceAppName: String? = nil) async -> [CapturedContent] {
        var results: [CapturedContent] = []
        var texts: [String] = []
        for provider in providers {
            // Images first: a shared photo often also offers a file URL.
            if let type = PasteboardType.imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) ?? (provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? UTType.image.identifier : nil),
               let data = await loadData(provider, type) {
                let uti = UTType(type)?.preferredFilenameExtension == nil ? PasteboardType.png : type
                results.append(CapturedContent(representations: [Representation(type: uti == UTType.image.identifier ? PasteboardType.png : uti, data: data)], plainText: nil, sourceAppName: sourceAppName))
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(provider) {
                texts.append(url.absoluteString)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let text = await loadText(provider) {
                texts.append(text)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
               let file = await importFile(provider) {
                results.append(CapturedContent(representations: [], plainText: nil, fileURLs: [file], filesAreImportedCopies: true, sourceAppName: sourceAppName))
            }
        }
        // Text-like items from one share become one clip (e.g. a page title + URL).
        if !texts.isEmpty {
            let joined = texts.count == 2 && ContentClassifier.link(in: texts[1]) != nil && ContentClassifier.link(in: texts[0]) == nil
                ? texts[1] : texts.joined(separator: "\n")
            let linkTitle = texts.count == 2 && ContentClassifier.link(in: texts[1]) != nil ? texts[0] : nil
            var content = CapturedContent(representations: [Representation(type: PasteboardType.plainText, data: Data(joined.utf8))], plainText: joined, sourceAppName: sourceAppName)
            if let linkTitle { content.representations.append(Representation(type: "app.rekeep.link-title", data: Data(linkTitle.utf8))) }
            results.insert(content, at: 0)
        }
        return results
    }

    private static func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { c in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in c.resume(returning: data) }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { c in
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in c.resume(returning: obj as? String) }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in c.resume(returning: obj as? URL) }
        }
    }

    /// Copies a shared file into Rekeep's own storage (the original may be temporary).
    private static func importFile(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                guard let url else { c.resume(returning: nil); return }
                let dir = SharedStorage.libraryDirectory.appendingPathComponent("Files/\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let target = dir.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: target)
                    c.resume(returning: target)
                } catch {
                    c.resume(returning: nil)
                }
            }
        }
    }
}

/// Runs captured content through the privacy policy and into the store. Shared by app and extension.
nonisolated enum CapturePipeline {
    @discardableResult
    static func ingest(_ content: CapturedContent, into store: ClipStore, privacy: PrivacySettings, asSnippet: Bool = false) -> IngestResult {
        let decision = PrivacyPolicy(settings: privacy).evaluate(text: content.plainText, totalBytes: content.totalBytes)
        guard case .store(let localOnly, let expiresAt) = decision else {
            if case .ignore(let reason) = decision { return .ignored(reason) }
            return .ignored(.unsupported)
        }
        var content = content
        let linkTitle = content.representations.first { $0.type == "app.rekeep.link-title" }.flatMap { String(data: $0.data, encoding: .utf8) }
        content.representations.removeAll { $0.type == "app.rekeep.link-title" }
        guard let made = ClipFactory.makeClip(from: content, deviceID: store.deviceID, deviceName: store.deviceName) else { return .ignored(.unsupported) }
        var clip = made.0
        clip.isLocalOnly = localOnly
        clip.expiresAt = expiresAt
        clip.isSnippet = asSnippet
        if clip.kind == .link, let linkTitle, !linkTitle.isEmpty { clip.linkTitle = linkTitle }
        var preview: Data?
        if clip.kind == .image, let image = made.1.first(where: { PasteboardType.imageTypes.contains($0.type) }) {
            preview = ClipFactory.thumbnail(from: image.data)
        }
        return (try? store.ingest(clip, representations: made.1, preview: preview)) ?? .ignored(.unsupported)
    }
}
