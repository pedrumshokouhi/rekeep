import AppKit
import RekeepKit
import SwiftUI
import UniformTypeIdentifiers

/// Builds drag payloads that other apps understand.
enum ClipDrag {
    @MainActor static var draggingIDs: [UUID] = []

    @MainActor
    static func provider(for clip: Clip, store: ClipStore) -> NSItemProvider {
        draggingIDs = [clip.id]
        switch clip.kind {
        case .file:
            if let url = clip.files.first.flatMap(FileAccess.resolve), let provider = NSItemProvider(contentsOf: url) { return provider }
            return NSItemProvider(object: clip.title as NSString)
        case .image:
            let provider = NSItemProvider()
            let id = clip.id
            for type in [PasteboardType.png, PasteboardType.jpeg, PasteboardType.tiff, PasteboardType.heic] {
                provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                    Task.detached {
                        let data = store.representations(for: id).first { $0.type == type }?.data
                        completion(data, nil)
                    }
                    return nil
                }
            }
            return provider
        case .link:
            let provider = NSItemProvider(object: (clip.url ?? URL(string: clip.plainText)!) as NSURL)
            provider.registerObject(clip.plainText as NSString, visibility: .all)
            return provider
        default:
            return NSItemProvider(object: clip.plainText as NSString)
        }
    }
}

/// Context actions shared by shelf cards and library items.
struct ClipContextMenu: View {
    @Environment(AppModel.self) private var app
    let clips: [Clip]
    var shelf: ShelfModel?

    private var single: Clip? { clips.count == 1 ? clips[0] : nil }

    var body: some View {
        if let clip = single {
            Button("Paste") { app.activate(clip, paste: true) }
            Button("Paste as Plain Text") { app.activate(clip, plainText: true, paste: true) }
            Button("Copy") { app.activate(clip, paste: false) }
        } else {
            Button("Paste \(clips.count) Together") { app.copyTogether(clips, paste: true) }
            Button("Copy \(clips.count) Together") { app.copyTogether(clips, paste: false) }
        }
        Divider()
        Button(clips.allSatisfy(\.isFavorite) ? "Remove from Favorites" : "Add to Favorites") { app.toggleFavorite(clips) }
        Menu("Add to Collection") {
            ForEach(app.collections) { c in
                Button { app.add(clips.map(\.id), to: c) } label: { Label(c.name, systemImage: c.symbol) }
            }
            if !app.collections.isEmpty { Divider() }
            Button("New Collection…") { app.openLibrary(.history); app.pendingNewCollectionClipIDs = clips.map(\.id) }
        }
        if case .collection(let cid)? = shelf?.scope, let c = app.collections.first(where: { $0.id == cid }) {
            Button("Remove from \(c.name)") { try? app.store.remove(clips.map(\.id), from: cid) }
        }
        Button("Add to Paste Queue") { app.enqueue(clips.map(\.id)) }
        if clips.count > 1 {
            Button("Compose with \(clips.count) Clips…") {
                app.composeSelection = clips.map(\.id)
                app.hideShelf { app.openCompose() }
            }
        }
        Divider()
        if let clip = single {
            if clip.kind == .link, let url = clip.url {
                Button("Open Link") { NSWorkspace.shared.open(url) }
            }
            if clip.kind == .file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(clip.files.compactMap(FileAccess.resolve)) }
            }
            Button("Edit in Library…") { app.hideShelf { app.openLibrary(.clip(clip.id)) } }
            Button("Duplicate") { _ = try? app.store.duplicate(clip.id) }
            Divider()
        }
        Button(clips.count == 1 ? "Delete" : "Delete \(clips.count) Clips", role: .destructive) { app.delete(clips.map(\.id)) }
    }
}

// MARK: - Toast HUD

/// Shows toasts in a small floating panel near the bottom of the active screen.
@MainActor
final class ToastController {
    private let app: AppModel
    private let panel: FloatingPanel

    init(app: AppModel) {
        self.app = app
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 120), level: .popUpMenu)
        panel.allowsKey = false
        panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(rootView: ToastView().environment(app).frame(width: 520, height: 120, alignment: .bottom))
        observe()
    }

    private func observe() {
        withObservationTracking { _ = app.toast } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if app.toast != nil {
            let screen = ShelfController.targetScreen()
            let visible = screen.visibleFrame
            let lift: CGFloat = app.isShelfVisible ? 360 : 40
            panel.setFrameOrigin(NSPoint(x: visible.midX - 260, y: visible.minY + lift))
            panel.orderFrontRegardless()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.app.toast == nil { self?.panel.orderOut(nil) }
            }
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let toast = app.toast {
                HStack(spacing: Space.s) {
                    Image(systemName: symbol(toast.style))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(toast.style == .failure ? Palette.danger : (toast.style == .success ? Palette.jadeInk : Palette.inkSecondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        if let detail = toast.detail {
                            Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.inkSecondary).lineLimit(2)
                        }
                    }
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(title) { action(); app.toast = nil }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.jadeInk)
                            .padding(.leading, Space.xs)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s + 2)
                .controlSurface(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.bottom, 12)
        .animation(Motion.panel, value: app.toast)
    }

    private func symbol(_ style: Toast.Style) -> String {
        switch style {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        case .failure: "exclamationmark.triangle.fill"
        }
    }
}
