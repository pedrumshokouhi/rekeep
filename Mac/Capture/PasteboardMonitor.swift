import AppKit
import RekeepKit
import UniformTypeIdentifiers

/// Watches the general pasteboard and hands new content to the capture pipeline.
///
/// macOS has no pasteboard-changed notification, so this polls `changeCount`, which is
/// cheap and does not count as reading pasteboard content. Content is read only after the
/// privacy preflight passes (not paused, source app not excluded, no concealed markers).
@MainActor
final class PasteboardMonitor {
    enum Event {
        case captured(CapturedContent)
        case ignored(IgnoreReason, sourceBundleID: String?)
    }

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ownWrites: Set<Int> = []
    private var wakeObserver: NSObjectProtocol?

    var policy: () -> PrivacyPolicy
    var onEvent: (Event) -> Void = { _ in }

    init(pasteboard: NSPasteboard = .general, policy: @escaping () -> PrivacyPolicy) {
        self.pasteboard = pasteboard
        self.policy = policy
        lastChangeCount = pasteboard.changeCount
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        // Treat whatever is already on the pasteboard at launch as seen; do not import it silently.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Called by the writer so Rekeep never re-captures what it just put on the pasteboard.
    func noteOwnWrite(changeCount: Int) {
        ownWrites.insert(changeCount)
        if ownWrites.count > 32 { ownWrites.remove(ownWrites.min()!) }
    }

    /// The current macOS pasteboard-privacy state for Rekeep (macOS 15.4+).
    var accessBehavior: PasteboardAccess {
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .alwaysAllow: return .allowed
            case .alwaysDeny: return .denied
            case .ask: return .ask
            default: return .notYetAsked
            }
        }
        return .allowed
    }

    func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ownWrites.remove(count) != nil { return }

        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier
        // Reading the list of types does not read content and does not trigger the privacy prompt.
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        if let reason = policy().preflight(sourceBundleID: bundleID, pasteboardTypes: types) {
            onEvent(.ignored(reason, sourceBundleID: bundleID))
            return
        }
        guard let content = read(sourceBundleID: bundleID, sourceName: front?.localizedName, types: types) else {
            onEvent(.ignored(.unsupported, sourceBundleID: bundleID))
            return
        }
        onEvent(.captured(content))
    }

    private func read(sourceBundleID: String?, sourceName: String?, types: Set<String>) -> CapturedContent? {
        var reps: [Representation] = []
        let items = pasteboard.pasteboardItems ?? []
        guard let first = items.first else { return nil }

        // File references (possibly several items).
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []

        for type in PasteboardType.preserved where first.types.contains(NSPasteboard.PasteboardType(type)) {
            if let data = first.data(forType: NSPasteboard.PasteboardType(type)) {
                reps.append(Representation(type: type, data: data))
            }
        }
        // TIFF is often enormous (screenshots); keep a PNG instead when no compact form exists.
        if let tiffIndex = reps.firstIndex(where: { $0.type == PasteboardType.tiff }),
           !reps.contains(where: { [PasteboardType.png, PasteboardType.jpeg, PasteboardType.heic].contains($0.type) }),
           let bitmap = NSBitmapImageRep(data: reps[tiffIndex].data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            reps[tiffIndex] = Representation(type: PasteboardType.png, data: png)
        } else {
            let hasCompact = reps.contains { [PasteboardType.png, PasteboardType.jpeg].contains($0.type) }
            if hasCompact { reps.removeAll { $0.type == PasteboardType.tiff } }
        }

        let text = first.string(forType: .string)
        var sourceURL: URL?
        if let raw = first.string(forType: NSPasteboard.PasteboardType(PasteboardType.chromiumSourceURL)) {
            sourceURL = URL(string: raw)
        }
        if reps.isEmpty, text == nil, fileURLs.isEmpty { return nil }
        return CapturedContent(representations: reps, plainText: text, fileURLs: fileURLs, sourceBundleID: sourceBundleID, sourceAppName: sourceName, sourceURL: sourceURL)
    }
}

enum PasteboardAccess {
    case allowed, ask, denied, notYetAsked
}
