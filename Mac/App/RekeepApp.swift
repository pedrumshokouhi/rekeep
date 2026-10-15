import AppKit
import RekeepKit
import SwiftUI

@main
struct RekeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(delegate.app)
        } label: {
            Image(nsImage: MenuBarIcon.image(paused: delegate.app.settings.privacy.isCapturePaused))
                .accessibilityLabel("Rekeep")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Renders the brand mark as a template image for the menu bar.
@MainActor
enum MenuBarIcon {
    private static var cache: [Bool: NSImage] = [:]

    static func image(paused: Bool) -> NSImage {
        if let cached = cache[paused] { return cached }
        let renderer = ImageRenderer(content: BrandMark(size: 16).foregroundStyle(.black).opacity(paused ? 0.45 : 1).frame(width: 18, height: 18))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Rekeep")!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        cache[paused] = image
        return image
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Open Shelf") { app.presentShelf() }
            .keyboardShortcut(KeyEquivalent(Character(KeyShortcut.keyName(app.settings.shortcut.keyCode).lowercased())), modifiers: EventModifiers(app.settings.shortcut.flags))
        Button("Open Library") { app.openLibrary(nil) }
        Divider()
        if !app.queue.isEmpty {
            Button("Paste Next from Queue (\(app.queue.remaining))") { app.pasteNextFromQueue() }
            Divider()
        }
        Button(app.settings.privacy.isCapturePaused ? "Resume Capture" : "Pause Capture") { app.togglePause() }
        Text(statusLine)
        Divider()
        Button("Settings…") { app.openSettings() }
            .keyboardShortcut(",")
        Button("Quit Rekeep") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        let count = app.statistics.clipCount
        let size = ByteCountFormatter.string(fromByteCount: app.statistics.totalBytes, countStyle: .file)
        return "\(count.formatted()) clips · \(size) · Saved on this Mac"
    }
}

extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    private var shelf: ShelfController!
    private var toasts: ToastController!
    private var templates: TemplateController!
    private var library: WindowHost?
    private var settingsWindow: WindowHost?
    private var onboarding: WindowHost?
    private var compose: WindowHost?
    private(set) var libraryModel: LibraryModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        shelf = ShelfController(app: app)
        toasts = ToastController(app: app)
        templates = TemplateController(app: app)
        libraryModel = LibraryModel(app: app)

        app.presentShelf = { [weak self] in self?.shelf.show() }
        app.hideShelf = { [weak self] completion in
            guard let self, self.shelf.isVisible else { completion?(); return }
            self.shelf.hide(then: completion)
        }
        app.openLibrary = { [weak self] destination in self?.showLibrary(destination) }
        app.openSettings = { [weak self] in self?.showSettings() }
        app.openCompose = { [weak self] in self?.showLibrary(.compose) }
        app.presentTemplate = { [weak self] clip, plain, paste in self?.templates.present(clip, plain: plain, paste: paste) }
        IntentEnvironment.store = app.store
        IntentEnvironment.openShelf = { [weak self] in self?.shelf.show() }

        observeShelfVisibility()
        observePaywall()
        registerHotKeys()
        observeShortcutChanges()
        app.start()

        #if DEBUG
        QASupport.run(app: app, shelf: shelf, delegate: self)
        #endif

        if !app.settings.hasCompletedOnboarding, !QASupport.skipsOnboarding {
            showOnboarding()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary(nil)
        return true
    }

    private func observeShelfVisibility() {
        withObservationTracking { _ = shelf.shelf.isVisible } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.app.isShelfVisible = self.shelf.shelf.isVisible
                self.observeShelfVisibility()
            }
        }
    }

    private var paywall: WindowHost?

    private func observePaywall() {
        withObservationTracking { _ = PurchaseManager.shared.paywallReason } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let reason = PurchaseManager.shared.paywallReason {
                    self.shelf.hide()
                    self.paywall?.close()
                    self.paywall = WindowHost(title: "Rekeep Pro", autosave: nil, size: NSSize(width: 460, height: 600), minSize: NSSize(width: 460, height: 560), toolbar: false, resizable: false, transparentTitlebar: true) {
                        PaywallView(reason: reason)
                    }
                    self.paywall?.show()
                    PurchaseManager.shared.paywallReason = nil
                }
                self.observePaywall()
            }
        }
    }

    // MARK: Hot keys

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        if !center.register("shelf", app.settings.shortcut, action: { [weak self] in self?.shelf.toggle() }) {
            app.show(Toast(style: .failure, title: "Shortcut unavailable", detail: "\(app.settings.shortcut.display) is used by another app. Choose a different one in Settings."))
        }
        center.register("queue", app.settings.queueShortcut, action: { [weak self] in self?.app.pasteNextFromQueue() })
        center.unregisterAll(prefix: "collection.")
        for (id, shortcut) in app.settings.collectionShortcuts {
            guard let uuid = UUID(uuidString: id) else { continue }
            center.register("collection.\(id)", shortcut) { [weak self] in
                guard let self else { return }
                if self.shelf.isVisible, self.shelf.shelf.scope == .collection(uuid) { self.shelf.hide(); return }
                if !self.shelf.isVisible { self.shelf.show() }
                self.shelf.shelf.scope = .collection(uuid)
            }
        }
    }

    private func observeShortcutChanges() {
        withObservationTracking {
            _ = app.settings.shortcut
            _ = app.settings.queueShortcut
            _ = app.settings.collectionShortcuts
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.registerHotKeys()
                self?.observeShortcutChanges()
            }
        }
    }

    // MARK: Windows

    func showLibrary(_ destination: LibraryDestination?) {
        if let destination { libraryModel.go(to: destination) }
        if library == nil {
            library = WindowHost(title: "Rekeep", autosave: "RekeepLibrary", size: NSSize(width: 1120, height: 720), minSize: NSSize(width: 760, height: 480), toolbar: true) { [unowned self] in
                LibraryView(model: self.libraryModel).environment(self.app)
            }
        }
        library?.show()
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = WindowHost(title: "Rekeep Settings", autosave: "RekeepSettings", size: NSSize(width: 640, height: 560), minSize: NSSize(width: 600, height: 480), toolbar: false, resizable: false) { [unowned self] in
                SettingsView().environment(self.app)
            }
        }
        settingsWindow?.show()
    }

    func showOnboarding() {
        if onboarding == nil {
            onboarding = WindowHost(title: "Welcome to Rekeep", autosave: nil, size: NSSize(width: 720, height: 560), minSize: NSSize(width: 720, height: 560), toolbar: false, resizable: false, transparentTitlebar: true) { [unowned self] in
                OnboardingView(finish: { [weak self] in
                    self?.app.settings.hasCompletedOnboarding = true
                    self?.onboarding?.close()
                    self?.onboarding = nil
                }).environment(self.app)
            }
        }
        onboarding?.show()
    }
}

/// An AppKit window hosting SwiftUI. Rekeep becomes a regular (Dock + ⌘Tab) app while any is open.
@MainActor
final class WindowHost: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private static var openCount = 0

    init<V: View>(title: String, autosave: String?, size: NSSize, minSize: NSSize, toolbar: Bool, resizable: Bool = true, transparentTitlebar: Bool = false, @ViewBuilder content: () -> V) {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: true)
        super.init()
        let controller = NSHostingController(rootView: content())
        if toolbar { controller.sceneBridgingOptions = [.toolbars, .title] }
        controller.sizingOptions = []
        window.contentViewController = controller
        window.title = title
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        if toolbar {
            window.toolbarStyle = .unified
        } else {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = transparentTitlebar ? .hidden : .visible
        }
        if let autosave {
            window.setFrameAutosaveName(autosave)
        }
        if autosave == nil || !window.setFrameUsingName(autosave!) { window.center() }
    }

    func show() {
        if !window.isVisible {
            Self.openCount += 1
            NSApp.setActivationPolicy(.regular)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        Self.openCount = max(0, Self.openCount - 1)
        if Self.openCount == 0 {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
