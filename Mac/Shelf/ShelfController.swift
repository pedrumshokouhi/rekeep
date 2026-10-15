import AppKit
import Carbon.HIToolbox
import RekeepKit
import SwiftUI

/// A borderless, non-activating panel. It takes keyboard focus without activating Rekeep,
/// so the app the user was working in stays frontmost and receives the paste.
final class FloatingPanel: NSPanel {
    var allowsKey = true

    init(contentRect: NSRect, level: NSWindow.Level = .statusBar) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Places, shows, hides, and drives the shelf from the keyboard.
@MainActor
final class ShelfController: NSObject, NSWindowDelegate {
    let app: AppModel
    let shelf: ShelfModel
    private let panel: FloatingPanel
    private let preview: PreviewController
    private var keyMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?

    /// Extra transparent margin so the glass shadow isn't clipped by the window edge.
    private let shadowMargin: CGFloat = 28

    init(app: AppModel) {
        self.app = app
        shelf = ShelfModel(app: app)
        panel = FloatingPanel(contentRect: .zero)
        preview = PreviewController(app: app, shelf: shelf)
        super.init()
        panel.delegate = self
        let root = ShelfView(shelf: shelf)
            .padding(shadowMargin)
            .environment(app)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setAccessibilityLabel("Rekeep Shelf")
    }

    var isVisible: Bool { panel.isVisible && shelf.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        hideWorkItem?.cancel()
        let screen = Self.targetScreen()
        panel.setFrame(frame(on: screen), display: false)
        shelf.willPresent()
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
        app.refreshPasteboardAccess()
        // Start the entrance on the next runloop turn so the first frame is the "from" state.
        DispatchQueue.main.async { self.shelf.isVisible = true }
    }

    func hide(then completion: (() -> Void)? = nil) {
        guard panel.isVisible else { completion?(); return }
        removeKeyMonitor()
        preview.close()
        shelf.isVisible = false
        // Hand focus back immediately; the fade finishes on its own.
        panel.resignKey()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.shelf.didDismiss()
        }
        hideWorkItem = work
        completion.map { c in DispatchQueue.main.async { c() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// The display the user is looking at: the one under the pointer.
    static func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func frame(on screen: NSScreen) -> NSRect {
        // visibleFrame already excludes the Dock (any edge) and the menu bar.
        let visible = screen.visibleFrame
        let card = app.settings.density.cardSize
        let contentHeight: CGFloat = app.settings.useListLayout
            ? 380
            : Radius.shelfInset * 2 + 34 + Space.m + card.height + 12 + (needsBanner ? 44 : 0)
        let sideMargin: CGFloat = 16
        let bottomMargin: CGFloat = 14
        let width = visible.width - sideMargin * 2
        return NSRect(
            x: visible.minX + sideMargin - shadowMargin,
            y: visible.minY + bottomMargin - shadowMargin,
            width: width + shadowMargin * 2,
            height: min(contentHeight, visible.height * 0.6) + shadowMargin * 2
        )
    }

    private var needsBanner: Bool {
        app.settings.privacy.isCapturePaused || app.pasteboardAccess == .denied || app.startupIssue != nil
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // A popover, template sheet, or menu of ours taking focus should not dismiss the shelf.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shelf.isVisible else { return }
            if let key = NSApp.keyWindow, key !== self.panel { return }
            if self.panel.isKeyWindow { return }
            self.hide()
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors are delivered on the main thread.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        shelf.isCommandHeld = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel || event.window == nil else { return event }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if event.type == .flagsChanged {
            shelf.isCommandHeld = flags == .command
            return event
        }
        let list = app.settings.useListLayout
        switch Int(event.keyCode) {
        case kVK_Escape:
            if preview.isOpen { preview.close() }
            else if !shelf.query.isEmpty { shelf.query = "" }
            else if !shelf.multiSelection.isEmpty { shelf.multiSelection = [] }
            else { hide() }
            return nil
        case kVK_LeftArrow where !list, kVK_UpArrow where list:
            shelf.move(-1, extend: flags.contains(.shift)); preview.refresh(); return nil
        case kVK_RightArrow where !list, kVK_DownArrow where list:
            shelf.move(1, extend: flags.contains(.shift)); preview.refresh(); return nil
        case kVK_UpArrow, kVK_DownArrow:
            return nil // no caret jumps in the search field while navigating cards
        case kVK_Home, kVK_PageUp:
            shelf.moveToEdge(start: true); return nil
        case kVK_End, kVK_PageDown:
            shelf.moveToEdge(start: false); return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            activateSelection(plain: flags.contains(.shift), paste: flags.contains(.option) ? false : nil)
            return nil
        case kVK_Space where shelf.query.isEmpty || flags.contains(.command):
            togglePreview(); return nil
        case kVK_Tab:
            shelf.cycleScope(flags.contains(.shift) ? -1 : 1); return nil
        case kVK_Delete, kVK_ForwardDelete:
            if flags.contains(.command) {
                let ids = shelf.actionClips.map(\.id)
                if !ids.isEmpty { app.delete(ids) }
                return nil
            }
            return event
        default:
            break
        }

        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        if let n = Int(key), (1...9).contains(n) {
            if let clip = shelf.clip(atShortcut: n) { app.activate(clip, plainText: flags.contains(.shift) ? true : nil) }
            return nil
        }
        switch key {
        case "c" where !flags.contains(.shift):
            let clips = shelf.actionClips
            if clips.count > 1 { app.copyTogether(clips) } else if let c = clips.first { app.activate(c, paste: false) }
            return nil
        case "d":
            let clips = shelf.actionClips
            if !clips.isEmpty { app.toggleFavorite(clips) }
            return nil
        case "a" where shelf.query.isEmpty:
            shelf.selectAll(); return nil
        case "y":
            togglePreview(); return nil
        case "k":
            let ids = shelf.actionClips.map(\.id)
            if !ids.isEmpty { app.enqueue(ids) }
            return nil
        case "l", "o":
            hide { self.app.openLibrary(self.shelf.selectedID.map { .clip($0) }) }
            return nil
        case "e":
            if let id = shelf.selectedID { hide { self.app.openLibrary(.clip(id)) } }
            return nil
        case "m":
            let ids = shelf.actionClips.map(\.id)
            if ids.count > 1 { app.composeSelection = ids; hide { self.app.openCompose() } }
            return nil
        case ",":
            hide { self.app.openSettings() }
            return nil
        case "f":
            return event
        case "w":
            hide(); return nil
        case "p" where flags.contains(.shift):
            app.togglePause(); return nil
        default:
            return event
        }
    }

    private func activateSelection(plain: Bool, paste: Bool?) {
        let clips = shelf.actionClips
        if clips.count > 1 {
            app.copyTogether(clips, paste: paste ?? (app.settings.pasteBehavior == .pasteDirectly))
        } else if let clip = clips.first {
            app.activate(clip, plainText: plain ? true : nil, paste: paste)
        }
    }

    #if DEBUG
    func debugTogglePreview() { togglePreview() }
    #endif

    private func togglePreview() {
        if preview.isOpen { preview.close() } else { preview.open(anchor: panel.frame, shadowMargin: shadowMargin) }
    }
}

/// The larger preview that opens above the shelf with Space.
@MainActor
final class PreviewController {
    let app: AppModel
    let shelf: ShelfModel
    private var panel: FloatingPanel?
    private var anchor: NSRect = .zero
    private var shadowMargin: CGFloat = 0

    init(app: AppModel, shelf: ShelfModel) {
        self.app = app
        self.shelf = shelf
    }

    var isOpen: Bool { panel?.isVisible == true }

    func open(anchor: NSRect, shadowMargin: CGFloat) {
        guard shelf.selectedClip != nil else { return }
        self.anchor = anchor
        self.shadowMargin = shadowMargin
        let panel = self.panel ?? makePanel()
        self.panel = panel
        shelf.isPreviewing = true
        position(panel)
        panel.orderFront(nil)
    }

    func refresh() {
        guard let panel, isOpen else { return }
        position(panel)
    }

    func close() {
        shelf.isPreviewing = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: .zero)
        panel.allowsKey = false
        panel.contentView = NSHostingView(rootView: PreviewView(shelf: shelf).padding(24).environment(app))
        return panel
    }

    private func position(_ panel: FloatingPanel) {
        let size = NSSize(width: 640 + 48, height: 460 + 48)
        let card = app.settings.density.cardSize
        let stride = card.width + app.settings.density.spacing
        let index = CGFloat(shelf.selectedIndex ?? 0) - CGFloat(shelf.firstVisibleIndex)
        let cardMidX = anchor.minX + shadowMargin + Radius.shelfInset + 6 + index * stride + card.width / 2
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? anchor
        var x = cardMidX - size.width / 2
        x = min(max(x, bounds.minX), bounds.maxX - size.width)
        let y = min(anchor.maxY - shadowMargin + 10 - 24, bounds.maxY - size.height)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

private struct PreviewView: View {
    @Environment(AppModel.self) private var app
    @Bindable var shelf: ShelfModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let clip = shelf.selectedClip {
                VStack(spacing: 0) {
                    HStack(spacing: Space.s) {
                        SourceIcon(bundleID: clip.sourceBundleID, kind: clip.kind, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ClipFormatting.typeLabel(for: clip)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                            Text(metadata(clip)).font(.cardMeta).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                        }
                        Spacer()
                        KeyHint(keys: ["↩"], label: "Paste")
                        KeyHint(keys: ["Space"], label: "Close")
                    }
                    .padding(.horizontal, Space.l)
                    .frame(height: 48)
                    Divider().opacity(0.5)
                    ClipContentView(clip: clip, mode: .preview)
                        .id(clip.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let ocr = clip.ocrText, clip.kind == .image {
                        Divider().opacity(0.5)
                        ScrollView {
                            Text(ocr).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(Space.m)
                        }
                        .frame(maxHeight: 80)
                    }
                }
                .contentSurface(radius: 20)
                .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: shelf.isPreviewing)
    }

    private func metadata(_ clip: Clip) -> String {
        var parts: [String] = []
        if let app = clip.sourceAppName { parts.append(app) }
        parts.append(clip.capturedAt.formatted(date: .abbreviated, time: .shortened))
        parts.append(ClipFormatting.detail(for: clip))
        if clip.useCount > 0 { parts.append("Used \(clip.useCount)×") }
        return parts.joined(separator: " · ")
    }
}
