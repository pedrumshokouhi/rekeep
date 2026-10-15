import Observation
import OSLog
import RekeepKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

nonisolated let log = Logger(subsystem: "com.pedrumshokouhi.rekeep", category: "mobile")

enum MobileScope: Hashable {
    case history, favorites, snippets
    case collection(UUID)
}

struct MobileToast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var symbol: String = "checkmark.circle.fill"
    var actionTitle: String?
    var action: (() -> Void)?
    static func == (a: MobileToast, b: MobileToast) -> Bool { a.id == b.id }
}

/// Owns the store and performs every user-visible action on iPhone and iPad.
@Observable
@MainActor
final class MobileModel {
    let store: ClipStore
    private(set) var collections: [ClipCollection] = []
    private(set) var collectionCounts: [UUID: Int] = [:]
    private(set) var statistics = StoreStatistics(clipCount: 0, totalBytes: 0, oldest: nil)
    private(set) var revision = 0
    private(set) var startupIssue: String?

    var toast: MobileToast?
    var templateClip: Clip?
    var composeIDs: [UUID] = []
    var isComposing = false

    /// iOS reveals that the clipboard changed without revealing its contents; Rekeep only reads
    /// it when the user taps the system Paste button.
    private(set) var clipboardHasNewContent = false
    private var lastSeenChangeCount: Int

    var privacy: PrivacySettings { didSet { SharedStorage.privacy = privacy } }
    var retention: HistoryRetention {
        didSet { SharedStorage.defaults.set(retention.rawValue, forKey: "rekeep.retention") }
    }
    var showsClipboardBanner: Bool {
        didSet { SharedStorage.defaults.set(showsClipboardBanner, forKey: "rekeep.clipboardBanner") }
    }
    var hasCompletedOnboarding: Bool {
        didSet { SharedStorage.defaults.set(hasCompletedOnboarding, forKey: "rekeep.onboarded") }
    }

    private var undoSnapshots: [ClipStore.Snapshot] = []
    private var toastTask: Task<Void, Never>?

    init() {
        let d = SharedStorage.defaults
        privacy = SharedStorage.privacy
        retention = HistoryRetention(rawValue: d.string(forKey: "rekeep.retention") ?? "") ?? .month
        showsClipboardBanner = d.object(forKey: "rekeep.clipboardBanner") as? Bool ?? true
        hasCompletedOnboarding = d.bool(forKey: "rekeep.onboarded")
        lastSeenChangeCount = d.integer(forKey: "rekeep.lastChangeCount")
        do {
            store = try SharedStorage.openStore(deviceName: UIDevice.current.name)
        } catch {
            log.error("Library failed to open: \(String(describing: error), privacy: .public)")
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("Rekeep-\(UUID().uuidString)")
            store = try! ClipStore(directory: fallback)
            startupIssue = "Rekeep couldn’t open its library. New clips are being kept temporarily."
        }
        NotificationCenter.default.addObserver(forName: .rekeepStoreDidChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didChange() }
        }
        NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        reloadMetadata()
        IntentEnvironment.store = store
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-qa.seed") { seedForQA() }
        if ProcessInfo.processInfo.arguments.contains("-qa.skipOnboarding") { hasCompletedOnboarding = true }
        #endif
    }

    /// Called when the app becomes active: picks up Share-extension writes and clipboard changes.
    func becameActive() {
        didChange()
        checkClipboard()
        let store = store
        let age = retention.interval
        Task.detached(priority: .background) { _ = try? store.applyRetention(maxAge: age, maxCount: nil, maxBytes: nil) }
    }

    private func didChange() {
        revision &+= 1
        reloadMetadata()
    }

    private func reloadMetadata() {
        collections = store.collections()
        collectionCounts = store.collectionCounts()
        statistics = store.statistics()
    }

    func checkClipboard() {
        let pb = UIPasteboard.general
        // hasStrings/hasImages/hasURLs and changeCount do not show the paste prompt.
        clipboardHasNewContent = showsClipboardBanner && pb.changeCount != lastSeenChangeCount && (pb.hasStrings || pb.hasImages || pb.hasURLs)
    }

    func dismissClipboardBanner() {
        lastSeenChangeCount = UIPasteboard.general.changeCount
        SharedStorage.defaults.set(lastSeenChangeCount, forKey: "rekeep.lastChangeCount")
        clipboardHasNewContent = false
    }

    // MARK: - Import

    /// From the system Paste button (no prompt) or drag and drop.
    func importProviders(_ providers: [NSItemProvider], fromClipboard: Bool) {
        if fromClipboard { dismissClipboardBanner() }
        let store = store, privacy = privacy
        Task {
            let contents = await ProviderImporter.content(from: providers)
            var saved = 0
            var skipped: IgnoreReason?
            for content in contents {
                switch await Task.detached(operation: { CapturePipeline.ingest(content, into: store, privacy: privacy) }).value {
                case .inserted, .refreshedDuplicate: saved += 1
                case .ignored(let reason): skipped = reason
                }
            }
            if saved > 0 {
                show(MobileToast(title: saved == 1 ? "Saved" : "Saved \(saved) items"))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if skipped == .sensitive {
                show(MobileToast(title: "Not saved — looks like a password or key", symbol: "hand.raised.fill"))
            } else if skipped == .tooLarge {
                show(MobileToast(title: "Too large to save", symbol: "exclamationmark.triangle.fill"))
            } else {
                show(MobileToast(title: "Nothing to save", symbol: "questionmark.circle"))
            }
        }
    }

    func importImageData(_ data: Data) {
        let content = CapturedContent(representations: [Representation(type: imageType(data), data: data)], plainText: nil)
        let store = store, privacy = privacy
        Task.detached { CapturePipeline.ingest(content, into: store, privacy: privacy) }
        show(MobileToast(title: "Photo saved"))
    }

    func importFiles(_ urls: [URL]) {
        let store = store, privacy = privacy
        Task.detached {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let dir = SharedStorage.libraryDirectory.appendingPathComponent("Files/\(UUID().uuidString)", isDirectory: true)
                guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
                let target = dir.appendingPathComponent(url.lastPathComponent)
                guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { continue }
                CapturePipeline.ingest(CapturedContent(representations: [], plainText: nil, fileURLs: [target], filesAreImportedCopies: true), into: store, privacy: privacy)
            }
        }
        show(MobileToast(title: urls.count == 1 ? "File saved" : "\(urls.count) files saved"))
    }

    private func imageType(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return PasteboardType.png }
        if bytes.starts(with: [0xFF, 0xD8]) { return PasteboardType.jpeg }
        if bytes.count >= 12, String(bytes: bytes[4..<12], encoding: .ascii)?.hasPrefix("ftyphei") == true { return PasteboardType.heic }
        return PasteboardType.png
    }

    func newSnippet(text: String, title: String?) {
        var q = ClipQuery(limit: 1000); q.snippetsOnly = true
        guard PurchaseManager.shared.allows(.snippets, count: store.count(q)) else { return }
        let (clip, reps) = ClipFactory.makeSnippet(text: text, title: title, deviceID: store.deviceID, deviceName: store.deviceName)
        _ = try? store.ingest(clip, representations: reps)
    }

    // MARK: - Reuse

    func copy(_ clip: Clip, plainText: Bool = false) {
        if clip.isTemplate, !plainText {
            templateClip = clip
            return
        }
        let reps = plainText ? [] : store.representations(for: clip.id)
        let pb = UIPasteboard.general
        if clip.kind == .file {
            let items = clip.files.compactMap { f -> [String: Any]? in
                guard let data = try? Data(contentsOf: f.url) else { return nil }
                return [f.contentType ?? UTType.data.identifier: data]
            }
            guard !items.isEmpty else { show(MobileToast(title: "The file is no longer available", symbol: "exclamationmark.triangle.fill")); return }
            pb.setItems(items)
        } else if plainText || reps.isEmpty {
            pb.string = clip.plainText
        } else {
            var item: [String: Any] = [:]
            for rep in reps { item[rep.type] = rep.data }
            if clip.kind == .link, let url = clip.url { item[UTType.url.identifier] = url }
            pb.setItems([item])
        }
        // Our own write shouldn't prompt the user to save it again.
        lastSeenChangeCount = pb.changeCount
        SharedStorage.defaults.set(lastSeenChangeCount, forKey: "rekeep.lastChangeCount")
        clipboardHasNewContent = false
        store.markUsed(clip.id)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        show(MobileToast(title: plainText ? "Copied as plain text" : "Copied"))
    }

    func copy(text: String) {
        UIPasteboard.general.string = text
        lastSeenChangeCount = UIPasteboard.general.changeCount
        clipboardHasNewContent = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        show(MobileToast(title: "Copied"))
    }

    func copyTogether(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        copy(text: clips.map(\.plainText).joined(separator: "\n\n"))
    }

    /// Items to hand to the share sheet.
    func shareItems(for clip: Clip) -> [Any] {
        switch clip.kind {
        case .image:
            if let data = store.representations(for: clip.id).first(where: { PasteboardType.imageTypes.contains($0.type) })?.data, let image = UIImage(data: data) { return [image] }
            return []
        case .link: return [clip.url ?? clip.plainText]
        case .file: return clip.files.map(\.url)
        default: return [clip.plainText]
        }
    }

    // MARK: - Organisation

    func toggleFavorite(_ clips: [Clip]) {
        let value = !clips.allSatisfy(\.isFavorite)
        try? store.setFavorite(clips.map(\.id), value)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func delete(_ ids: [UUID]) {
        let snapshots = ids.compactMap { store.snapshot($0) }
        try? store.delete(ids)
        undoSnapshots = snapshots
        composeIDs.removeAll { ids.contains($0) }
        show(MobileToast(title: ids.count == 1 ? "Deleted" : "Deleted \(ids.count)", symbol: "trash", actionTitle: "Undo", action: { [weak self] in self?.undoDelete() }))
    }

    func undoDelete() {
        try? store.restore(undoSnapshots)
        undoSnapshots = []
    }

    @discardableResult
    func createCollection(name: String, symbol: String = "square.stack", accent: CollectionAccent = .graphite, adding ids: [UUID] = []) -> ClipCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PurchaseManager.shared.allows(.collections, count: collections.count) else { return nil }
        guard !trimmed.isEmpty, let c = try? store.saveCollection(ClipCollection(name: trimmed, symbol: symbol, accent: accent)) else { return nil }
        if !ids.isEmpty { try? store.add(ids, to: c.id) }
        return c
    }

    func add(_ ids: [UUID], to c: ClipCollection) {
        try? store.add(ids, to: c.id)
        show(MobileToast(title: "Added to \(c.name)"))
    }

    func startCompose(_ ids: [UUID]) {
        guard PurchaseManager.shared.allows(.compose) else { return }
        composeIDs = ids
        isComposing = true
    }

    func show(_ toast: MobileToast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: toast.action == nil ? .seconds(1.6) : .seconds(4))
            guard !Task.isCancelled else { return }
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    #if DEBUG
    private func seedForQA() {
        guard statistics.clipCount == 0 else { return }
        let now = Date()
        let samples: [(String, Double)] = [
            ("https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views", 2),
            ("#36B797", 6),
            ("Thanks for the thoughtful notes on the launch plan. Let’s keep Thursday for the review and move the press briefing to the following Tuesday.", 11),
            ("Hi {{first_name}},\n\nThanks for reaching out about {{company}}. Happy to walk through it {{date}}.\n\nBest,\nPedrum", 18),
            ("SELECT name, COUNT(*) AS visits\nFROM sessions\nGROUP BY name\nORDER BY visits DESC;", 26),
            ("東京の会議は午後三時から始まります。", 55),
            ("Meeting notes — Q4 planning\n• Ship the shelf redesign\n• Compose beta\n• Privacy copy review", 180),
        ]
        for (text, minutes) in samples {
            let c = CapturedContent(representations: [Representation(type: PasteboardType.plainText, data: Data(text.utf8))], plainText: text, capturedAt: now.addingTimeInterval(-minutes * 60))
            CapturePipeline.ingest(c, into: store, privacy: privacy)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { ctx in
            UIColor(hex: 0xD9C8A9).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            UIColor.white.withAlphaComponent(0.85).setFill(); UIBezierPath(roundedRect: CGRect(x: 140, y: 160, width: 600, height: 480), cornerRadius: 36).fill()
            UIColor(hex: 0x202329).setFill(); UIBezierPath(ovalIn: CGRect(x: 820, y: 260, width: 280, height: 280)).fill()
        }
        if let png = image.pngData() {
            CapturePipeline.ingest(CapturedContent(representations: [Representation(type: PasteboardType.png, data: png)], plainText: nil, capturedAt: now.addingTimeInterval(-8 * 60)), into: store, privacy: privacy)
        }
        if let color = try? store.fetch(ClipQuery(text: "#36B797", limit: 1)).first { try? store.setFavorite([color.id], true) }
        if let t = try? store.fetch(ClipQuery(text: "first_name", limit: 1)).first { try? store.update(t.id) { $0.isSnippet = true; $0.title = "Intro reply" } }
        createCollection(name: "Brand", symbol: "paintpalette", accent: .jade)
        createCollection(name: "Research", symbol: "doc.text.magnifyingglass", accent: .sand)
    }
    #endif
}

/// How long ordinary history is kept (shared definition with the Mac app's settings).
enum HistoryRetention: String, CaseIterable, Identifiable, Codable {
    case day, week, month, year, forever
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "1 Day"
        case .week: "1 Week"
        case .month: "1 Month"
        case .year: "1 Year"
        case .forever: "Forever"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 31 * 86_400
        case .year: 366 * 86_400
        case .forever: nil
        }
    }
}
