import AppKit
import Observation
import OSLog
import RekeepKit
import ServiceManagement

nonisolated let log = Logger(subsystem: "com.pedrumshokouhi.rekeep", category: "app")

/// A short, unobtrusive confirmation or error.
struct Toast: Identifiable, Equatable {
    enum Style { case success, info, failure }
    let id = UUID()
    var style: Style
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// Owns the services and performs every user-visible action. Views stay thin.
@Observable
@MainActor
final class AppModel {
    let settings: AppSettings
    let store: ClipStore
    let monitor: PasteboardMonitor
    let writer: PasteboardWriter
    let libraryDirectory: URL

    private(set) var collections: [ClipCollection] = []
    private(set) var collectionCounts: [UUID: Int] = [:]
    private(set) var statistics = StoreStatistics(clipCount: 0, totalBytes: 0, oldest: nil)
    /// Bumped on every store change; observers reload.
    private(set) var revision = 0
    var queue = ReuseQueue()
    var toast: Toast?
    private(set) var pasteboardAccess: PasteboardAccess = .notYetAsked
    private(set) var startupIssue: String?
    private(set) var lastIgnoredReason: IgnoreReason?
    var composeSelection: [UUID] = []
    /// Clips waiting to go into a collection the user is about to name.
    var pendingNewCollectionClipIDs: [UUID] = []
    var isShelfVisible = false

    /// Set by the app delegate: presents UI owned by AppKit controllers.
    var presentShelf: () -> Void = {}
    var hideShelf: (_ thenPerform: (() -> Void)?) -> Void = { $0?() }
    var openLibrary: (_ destination: LibraryDestination?) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var openCompose: () -> Void = {}
    var presentTemplate: (Clip, _ plain: Bool, _ paste: Bool) -> Void = { _, _, _ in }

    private var undoSnapshots: [ClipStore.Snapshot] = []
    private var toastTask: Task<Void, Never>?
    private var maintenanceTimer: Timer?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = support.appendingPathComponent("Rekeep", isDirectory: true)
        #if DEBUG
        // QA runs use their own library so test content never mixes with real history.
        if let qa = UserDefaults.standard.string(forKey: "qa.library-dir") {
            directory = support.appendingPathComponent(qa, isDirectory: true)
        }
        #endif
        libraryDirectory = directory
        var issue: String?
        store = Self.openStore(at: directory, issue: &issue)
        startupIssue = issue
        monitor = PasteboardMonitor(policy: { PrivacyPolicy(settings: PrivacySettings()) })
        writer = PasteboardWriter()
        writer.monitor = monitor
        monitor.policy = { [unowned self] in PrivacyPolicy(settings: self.settings.privacy) }
        monitor.onEvent = { [weak self] event in self?.handle(event) }

        NotificationCenter.default.addObserver(forName: .rekeepStoreDidChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeDidChange() }
        }
        reloadMetadata()
    }

    /// Opens the library; if it is unreadable, moves it aside (never deletes it) and starts fresh.
    private static func openStore(at directory: URL, issue: inout String?) -> ClipStore {
        let name = Host.current().localizedName
        do {
            return try ClipStore(directory: directory, deviceName: name)
        } catch {
            log.error("Library failed to open: \(String(describing: error), privacy: .public)")
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let aside = directory.deletingLastPathComponent().appendingPathComponent("Rekeep (unreadable \(stamp))")
            try? FileManager.default.moveItem(at: directory, to: aside)
            issue = "Rekeep couldn’t read its library, so it started a new one. The old library was kept at “\(aside.lastPathComponent)” in Rekeep’s Application Support folder."
            if let store = try? ClipStore(directory: directory, deviceName: name) { return store }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Rekeep-\(UUID().uuidString)")
            return try! ClipStore(directory: temp, deviceName: name)
        }
    }

    func start() {
        monitor.start()
        refreshPasteboardAccess()
        runMaintenance()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runMaintenance() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    func refreshPasteboardAccess() {
        pasteboardAccess = monitor.accessBehavior
    }

    private func storeDidChange() {
        revision &+= 1
        reloadMetadata()
    }

    private func reloadMetadata() {
        collections = store.collections()
        collectionCounts = store.collectionCounts()
        statistics = store.statistics()
    }

    /// Expiry and retention. Cheap when there is nothing to do.
    func runMaintenance() {
        let store = store
        let age = settings.retention.interval
        let bytes = settings.maxLibraryBytes
        Task.detached(priority: .background) {
            do { try store.applyRetention(maxAge: age, maxCount: nil, maxBytes: bytes) }
            catch { log.error("Retention failed: \(String(describing: error), privacy: .public)") }
        }
    }

    // MARK: - Capture

    private func handle(_ event: PasteboardMonitor.Event) {
        switch event {
        case .ignored(let reason, _):
            lastIgnoredReason = reason
        case .captured(let content):
            refreshPasteboardAccess()
            ingest(content)
        }
    }

    func ingest(_ content: CapturedContent, asSnippet: Bool = false) {
        let policy = PrivacyPolicy(settings: settings.privacy)
        let store = store
        Task.detached(priority: .userInitiated) {
            let decision = policy.evaluate(text: content.plainText, totalBytes: content.totalBytes)
            guard case .store(let localOnly, let expiresAt) = decision else {
                if case .ignore(let reason) = decision {
                    await MainActor.run { self.noteIgnored(reason) }
                }
                return
            }
            guard let made = ClipFactory.makeClip(from: content, deviceID: store.deviceID, deviceName: store.deviceName) else { return }
            var clip = made.0
            let reps = made.1
            clip.isLocalOnly = localOnly
            clip.expiresAt = expiresAt
            clip.isSnippet = asSnippet
            if clip.kind == .file { clip.files = FileAccess.attachBookmarks(clip.files) }
            var preview: Data?
            if clip.kind == .image, let image = reps.first(where: { PasteboardType.imageTypes.contains($0.type) }) {
                preview = ClipFactory.thumbnail(from: image.data)
            }
            do {
                let result = try store.ingest(clip, representations: reps, preview: preview)
                if case .inserted(let id) = result, clip.kind == .image, expiresAt == nil,
                   let image = reps.first(where: { PasteboardType.imageTypes.contains($0.type) }) {
                    if let text = await OCRService.recognize(image.data) { store.setOCRText(text, for: id) }
                }
            } catch {
                log.error("Ingest failed: \(String(describing: error), privacy: .public)")
                await MainActor.run { self.show(Toast(style: .failure, title: "Couldn’t save that copy", detail: "Your library may be full or unavailable.")) }
            }
        }
    }

    private func noteIgnored(_ reason: IgnoreReason) {
        lastIgnoredReason = reason
        if reason == .tooLarge {
            let limit = ByteCountFormatter.string(fromByteCount: settings.privacy.maxItemBytes, countStyle: .file)
            show(Toast(style: .info, title: "Skipped a large copy", detail: "Items over \(limit) aren’t saved. You can change this in Settings."))
        }
    }

    // MARK: - Reuse

    /// The primary action: put the clip on the clipboard. `paste` means the person is about to
    /// paste (from the shelf): Rekeep steps aside so their app has focus, and they press ⌘V.
    func activate(_ clip: Clip, plainText: Bool? = nil, paste: Bool? = nil) {
        let plain = plainText ?? settings.pastePlainTextByDefault
        let shouldPaste = paste ?? true
        if clip.isTemplate {
            presentTemplate(clip, plain, shouldPaste)
            return
        }
        do {
            try writer.write(clip, representations: plain ? [] : store.representations(for: clip.id), plainText: plain)
        } catch {
            show(Toast(style: .failure, title: "Couldn’t copy", detail: error.localizedDescription))
            return
        }
        store.markUsed(clip.id)
        finishReuse(paste: shouldPaste, kind: plain ? "plain text" : nil)
    }

    /// Writes text produced by Rekeep (templates, compose, multi-copy) and finishes like `activate`.
    func deliver(text: String, paste: Bool) {
        writer.write(text: text)
        finishReuse(paste: paste, kind: nil)
    }

    private func finishReuse(paste: Bool, kind: String?) {
        if paste {
            // The shelf never takes focus from the app you were in, so ⌘V lands right there.
            hideShelf(nil)
            show(Toast(style: .success, title: kind == nil ? "Copied" : "Copied as \(kind!)", detail: "Press ⌘V to paste."))
        } else {
            hideShelf(nil)
            show(Toast(style: .success, title: kind == nil ? "Copied" : "Copied as \(kind!)"))
        }
    }

    /// Copies several clips joined by the configured separator.
    func copyTogether(_ clips: [Clip], paste: Bool = false) {
        guard !clips.isEmpty else { return }
        if clips.count == 1 { activate(clips[0], paste: paste); return }
        let text = clips.map(\.plainText).joined(separator: settings.multiSeparator.string)
        clips.forEach { store.markUsed($0.id, bringToFront: false) }
        deliver(text: text, paste: paste)
    }

    // MARK: - Queue

    func enqueue(_ ids: [UUID]) {
        queue.add(contentsOf: ids)
        show(Toast(style: .info, title: ids.count == 1 ? "Added to Queue" : "\(ids.count) added to Queue", detail: "\(queue.remaining) waiting · paste next with \(settings.queueShortcut?.display ?? "the Queue shortcut")"))
    }

    /// Copies (and pastes) the next queued clip.
    func pasteNextFromQueue() {
        guard let id = queue.next() else {
            show(Toast(style: .info, title: queue.isPaused ? "Queue is paused" : "Queue is empty"))
            return
        }
        guard let clip = store.clip(id) else { pasteNextFromQueue(); return }
        do {
            try writer.write(clip, representations: store.representations(for: id), plainText: settings.pastePlainTextByDefault)
            store.markUsed(id, bringToFront: false)
            show(Toast(style: .success, title: queue.remaining == 0 ? "Last item in Queue — press ⌘V" : "Ready to paste · \(queue.remaining) left", detail: queue.remaining == 0 ? nil : "Press ⌘V, then the Queue shortcut for the next one."))
        } catch {
            show(Toast(style: .failure, title: "Couldn’t copy", detail: error.localizedDescription))
        }
    }

    // MARK: - Organisation

    func toggleFavorite(_ clips: [Clip]) {
        let value = !clips.allSatisfy(\.isFavorite)
        try? store.setFavorite(clips.map(\.id), value)
    }

    func delete(_ ids: [UUID]) {
        let snapshots = ids.compactMap { store.snapshot($0) }
        do {
            try store.delete(ids)
            queue.purge(Set(ids))
            composeSelection.removeAll { ids.contains($0) }
            undoSnapshots = snapshots
            show(Toast(style: .info, title: ids.count == 1 ? "Deleted" : "Deleted \(ids.count) clips", actionTitle: "Undo", action: { [weak self] in self?.undoDelete() }))
        } catch {
            show(Toast(style: .failure, title: "Couldn’t delete", detail: error.localizedDescription))
        }
    }

    func undoDelete() {
        guard !undoSnapshots.isEmpty else { return }
        try? store.restore(undoSnapshots)
        undoSnapshots = []
        show(Toast(style: .success, title: "Restored"))
    }

    @discardableResult
    func createCollection(name: String, symbol: String = "square.stack", accent: CollectionAccent = .graphite, adding ids: [UUID] = []) -> ClipCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let c = try? store.saveCollection(ClipCollection(name: trimmed, symbol: symbol, accent: accent)) else { return nil }
        if !ids.isEmpty { try? store.add(ids, to: c.id) }
        return c
    }

    func add(_ ids: [UUID], to collection: ClipCollection) {
        try? store.add(ids, to: collection.id)
        show(Toast(style: .success, title: "Added to \(collection.name)"))
    }

    func newSnippet(text: String, title: String?) {
        let (clip, reps) = ClipFactory.makeSnippet(text: text, title: title, deviceID: store.deviceID, deviceName: store.deviceName)
        _ = try? store.ingest(clip, representations: reps)
    }

    func togglePause() {
        settings.privacy.isCapturePaused.toggle()
        show(Toast(style: .info, title: settings.privacy.isCapturePaused ? "Capture paused" : "Capture resumed", detail: settings.privacy.isCapturePaused ? "New copies won’t be saved until you resume." : nil))
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = enabled
        } catch {
            show(Toast(style: .failure, title: "Couldn’t change login item", detail: error.localizedDescription))
        }
    }

    // MARK: - Toasts

    func show(_ toast: Toast) {
        guard settings.playFeedbackHUD || toast.style == .failure || toast.action != nil else { return }
        self.toast = toast
        toastTask?.cancel()
        let duration: Duration = toast.action == nil ? .seconds(1.6) : .seconds(5)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }
}

/// Where the library window should open.
enum LibraryDestination: Hashable {
    case history, favorites, snippets, compose, queue
    case collection(UUID)
    case clip(UUID)
}
