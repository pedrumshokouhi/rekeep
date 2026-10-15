import AppKit
import RekeepKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        } detail: {
            detail
        }
        .onAppear { model.reload() }
        .onChange(of: app.revision) { _, _ in model.reload() }
        .sheet(item: $model.editingSnippet) { draft in
            SnippetEditor(draft: draft) { model.editingSnippet = nil }
        }
        .onChange(of: app.pendingNewCollectionClipIDs) { _, ids in
            guard !ids.isEmpty else { return }
            NewCollectionPrompt.run(app: app, adding: ids) { c in if let c { model.section = .collection(c.id) } }
            app.pendingNewCollectionClipIDs = []
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .compose:
            ComposeView()
        case .queue:
            QueueView()
        default:
            ClipBrowser(model: model)
                .inspector(isPresented: $model.showsInspector) {
                    InspectorPane(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel
    @State private var renaming: ClipCollection?

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            Section {
                row("History", "clock", .history, count: nil)
                row("Favorites", "star", .favorites, count: nil)
                row("Snippets", "text.quote", .snippets, count: nil)
            }
            Section("Collections") {
                ForEach(app.collections) { c in
                    Label {
                        HStack {
                            Text(c.name)
                            Spacer()
                            Text("\(app.collectionCounts[c.id] ?? 0)").foregroundStyle(.tertiary).monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: c.symbol).foregroundStyle(c.accent.color)
                    }
                    .tag(LibrarySection.collection(c.id))
                    .contextMenu { CollectionMenu(collection: c, onRename: { renaming = c }) }
                    .dropDestination(for: String.self) { _, _ in
                        let ids = ClipDrag.draggingIDs.isEmpty ? Array(model.selection) : ClipDrag.draggingIDs
                        guard !ids.isEmpty else { return false }
                        app.add(ids, to: c)
                        ClipDrag.draggingIDs = []
                        return true
                    }
                }
                .onMove { from, to in
                    var ids = app.collections.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    try? app.store.reorderCollections(ids)
                }
                Button {
                    NewCollectionPrompt.run(app: app, adding: []) { c in if let c { model.section = .collection(c.id) } }
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Section("Workflows") {
                row("Paste Queue", "list.number", .queue, count: app.queue.isEmpty ? nil : app.queue.remaining)
                row("Compose", "square.and.pencil", .compose, count: app.composeSelection.isEmpty ? nil : app.composeSelection.count)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { StorageFooter() }
        .sheet(item: $renaming) { c in CollectionEditor(collection: c) { renaming = nil } }
    }

    private func row(_ title: String, _ symbol: String, _ section: LibrarySection, count: Int?) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(.tertiary).monospacedDigit() }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(section)
    }
}

private struct StorageFooter: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: app.settings.privacy.isCapturePaused ? "pause.circle" : "internaldrive")
                .foregroundStyle(Palette.inkTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.settings.privacy.isCapturePaused ? "Capture paused" : "Saved on this Mac")
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                Text("\(app.statistics.clipCount.formatted()) clips · \(ByteCountFormatter.string(fromByteCount: app.statistics.totalBytes, countStyle: .file))")
                    .font(.caption2).foregroundStyle(Palette.inkTertiary).monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }
}

private struct CollectionMenu: View {
    @Environment(AppModel.self) private var app
    let collection: ClipCollection
    var onRename: () -> Void

    var body: some View {
        Button("Edit Collection…", action: onRename)
        Button("Open in Shelf") {
            app.presentShelf()
        }
        Divider()
        Button("Delete Collection…", role: .destructive) {
            let alert = NSAlert()
            alert.messageText = "Delete “\(collection.name)”?"
            alert.informativeText = "The clips in it stay in your history. Only the collection is removed."
            alert.addButton(withTitle: "Delete Collection")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            if alert.runModal() == .alertFirstButtonReturn {
                try? app.store.deleteCollection(collection.id)
                app.settings.collectionShortcuts[collection.id.uuidString] = nil
            }
        }
    }
}

// MARK: - Browser

private struct ClipBrowser: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel
    @FocusState private var focused: Bool

    private var cardSize: CGSize {
        let base = app.settings.density.cardSize
        return CGSize(width: base.width * model.gridScale, height: base.height * model.gridScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(model: model)
            Divider().opacity(0.6)
            if model.clips.isEmpty {
                LibraryEmpty(model: model)
            } else if model.showsList {
                listBody
            } else {
                gridBody
            }
            if model.selection.count > 1 {
                BatchBar(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: model.selection.count > 1)
        .navigationTitle(model.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search text, links, notes, tags")
        .toolbar { toolbar }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let columns = model.showsList ? 1 : max(1, columnsEstimate)
            let shift = press.modifiers.contains(.shift)
            switch press.key {
            case .leftArrow: model.moveSelection(by: model.showsList ? -1 : -1, extend: shift)
            case .rightArrow: model.moveSelection(by: 1, extend: shift)
            case .upArrow: model.moveSelection(by: -columns, extend: shift)
            default: model.moveSelection(by: columns, extend: shift)
            }
            return .handled
        }
        .onKeyPress(.return) {
            copySelection(); return .handled
        }
        .onKeyPress(.delete) {
            if !model.selection.isEmpty { app.delete(Array(model.selection)) }
            return .handled
        }
        .onCopyCommand {
            copySelection()
            return []
        }
        .onAppear { focused = true }
    }

    @State private var width: CGFloat = 800
    private var columnsEstimate: Int { Int((width - 32 + 16) / (cardSize.width + 16)) }

    private var subtitle: String {
        let n = model.clips.count
        let more = model.hasMore ? "+" : ""
        return model.isFiltering ? "\(n)\(more) matching" : "\(n)\(more) clips"
    }

    private func copySelection() {
        let clips = model.selectedClips
        if clips.count == 1 { app.activate(clips[0], paste: false) }
        else if clips.count > 1 { app.copyTogether(clips) }
    }

    private var gridBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize.width, maximum: cardSize.width), spacing: 16)], spacing: 16) {
                    ForEach(model.clips) { clip in
                        LibraryCard(model: model, clip: clip, size: cardSize)
                            .id(clip.id)
                            .onAppear { if clip.id == model.clips.last?.id { model.loadMore() } }
                    }
                }
                .padding(Space.l)
                .animation(Motion.reflow, value: model.clips.map(\.id))
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .onChange(of: model.revealID) { _, id in
                guard let id else { return }
                withAnimation(Motion.view) { proxy.scrollTo(id, anchor: .center) }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
        }
    }

    private var listBody: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.clips) { clip in
                    ClipRow(clip: clip, isSelected: model.selection.contains(clip.id))
                        .id(clip.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowSeparator(.hidden)
                        .modifier(LibraryItemInteractions(model: model, clip: clip))
                        .onAppear { if clip.id == model.clips.last?.id { model.loadMore() } }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: model.revealID) { _, id in
                guard let id else { return }
                withAnimation(Motion.view) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.section == .snippets || model.section == .history || { if case .collection = model.section { return true }; return false }() {
                Button { model.editingSnippet = SnippetDraft() } label: { Label("New Snippet", systemImage: "square.and.pencil") }
                    .help("New Snippet")
            }
            Picker("Layout", selection: $model.showsList) {
                Label("Grid", systemImage: "square.grid.2x2").tag(false)
                Label("List", systemImage: "list.bullet").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Grid or List")
            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(ClipQuery.Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                if !model.showsList {
                    Divider()
                    Picker("Card Size", selection: $model.gridScale) {
                        Text("Small").tag(0.85)
                        Text("Medium").tag(1.0)
                        Text("Large").tag(1.25)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label("View Options", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort and card size")
            Button { model.showsInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector")
        }
    }
}

/// Type chips, date, and source app filters. Visible, one click each.
private struct FilterBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(ClipKind.filterable) { kind in
                    ScopeChip(title: kind.label, symbol: kind.symbol, accent: nil, isOn: model.kinds.contains(kind)) {
                        if model.kinds.contains(kind) { model.kinds.remove(kind) } else { model.kinds.insert(kind) }
                    }
                }
                Divider().frame(height: 16).padding(.horizontal, Space.xs)
                Menu {
                    Picker("Date", selection: $model.dateFilter) {
                        ForEach(DateFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    chipLabel(model.dateFilter == .any ? "Any Time" : model.dateFilter.title, "calendar", active: model.dateFilter != .any)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Menu {
                    Button("Any App") { model.sourceBundleID = nil }
                    Divider()
                    ForEach(app.store.sourceApps(), id: \.bundleID) { source in
                        Button("\(source.name) (\(source.count))") { model.sourceBundleID = source.bundleID }
                    }
                } label: {
                    chipLabel(sourceName ?? "Any App", "app.badge", active: model.sourceBundleID != nil)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                if model.isFiltering {
                    Button("Clear") {
                        model.query = ""; model.kinds = []; model.dateFilter = .any; model.sourceBundleID = nil
                    }
                    .buttonStyle(.link)
                    .padding(.leading, Space.xs)
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
        .scrollIndicators(.never)
    }

    private var sourceName: String? {
        guard let id = model.sourceBundleID else { return nil }
        return app.store.sourceApps().first { $0.bundleID == id }?.name ?? id
    }

    private func chipLabel(_ title: String, _ symbol: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title).font(.chip)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.inkTertiary)
        }
        .foregroundStyle(active ? Palette.ink : Palette.inkSecondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(active ? Palette.chipFillSelected : .clear, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}

private struct LibraryCard: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel
    let clip: Clip
    let size: CGSize

    var body: some View {
        ClipCard(
            clip: clip,
            size: size,
            isSelected: model.selection.contains(clip.id) && model.selection.count == 1,
            isMultiSelected: model.selection.contains(clip.id) && model.selection.count > 1,
            collectionAccents: [],
            onFavorite: { app.toggleFavorite([clip]) }
        )
        .modifier(LibraryItemInteractions(model: model, clip: clip))
    }
}

/// Click, ⌘/⇧-click, double-click, drag, and context menu for library items.
private struct LibraryItemInteractions: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel
    let clip: Clip

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { app.activate(clip, paste: false) }
            .simultaneousGesture(TapGesture().onEnded {
                let flags = NSEvent.modifierFlags
                model.click(clip, command: flags.contains(.command), shift: flags.contains(.shift))
            })
            .onDrag {
                let provider = ClipDrag.provider(for: clip, store: app.store)
                ClipDrag.draggingIDs = model.selection.contains(clip.id) ? Array(model.selection) : [clip.id]
                return provider
            }
            .contextMenu {
                ClipContextMenu(clips: model.selection.contains(clip.id) && model.selection.count > 1 ? model.selectedClips : [clip])
                if case .collection(let id) = model.section {
                    Button("Remove from Collection") { try? app.store.remove(model.selection.contains(clip.id) ? Array(model.selection) : [clip.id], from: id) }
                }
            }
    }
}

private struct BatchBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel

    var body: some View {
        HStack(spacing: Space.m) {
            Text("\(model.selection.count) selected").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Spacer()
            Button("Copy Together") { app.copyTogether(model.selectedClips) }
            Button("Compose…") {
                app.composeSelection = model.selectedClips.map(\.id)
                model.section = .compose
            }
            Button("Queue") { app.enqueue(model.selectedClips.map(\.id)) }
            Button(model.selectedClips.allSatisfy(\.isFavorite) ? "Unfavorite" : "Favorite") { app.toggleFavorite(model.selectedClips) }
            Menu("Add to Collection") {
                ForEach(app.collections) { c in Button(c.name) { app.add(Array(model.selection), to: c) } }
                Divider()
                Button("New Collection…") {
                    NewCollectionPrompt.run(app: app, adding: Array(model.selection)) { _ in }
                }
            }
            .fixedSize()
            Button("Delete", role: .destructive) { app.delete(Array(model.selection)) }
            Button { model.selection = [] } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Deselect")
        }
        .controlSize(.regular)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s + 2)
        .controlSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(Space.m)
    }
}

private struct LibraryEmpty: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel

    var body: some View {
        VStack(spacing: Space.s) {
            if model.isFiltering {
                Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.inkTertiary)
                Text("No matching clips").font(.title3.weight(.semibold))
                Button("Clear Filters") { model.query = ""; model.kinds = []; model.dateFilter = .any; model.sourceBundleID = nil }
            } else {
                switch model.section {
                case .favorites:
                    Image(systemName: "star").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.inkTertiary)
                    Text("No favorites yet").font(.title3.weight(.semibold))
                    Text("Favorites stay forever — history limits never remove them.").foregroundStyle(.secondary)
                case .snippets:
                    Image(systemName: "text.quote").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.inkTertiary)
                    Text("Reusable text, written once").font(.title3.weight(.semibold))
                    Text("Add {{placeholders}} such as {{first_name}} or {{date}} to make a template.").foregroundStyle(.secondary)
                    Button("New Snippet") { model.editingSnippet = SnippetDraft() }.buttonStyle(.borderedProminent).tint(Palette.jade).padding(.top, Space.s)
                case .collection:
                    Image(systemName: "square.stack").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.inkTertiary)
                    Text("This collection is empty").font(.title3.weight(.semibold))
                    Text("Drag clips onto it in the sidebar, or right-click any clip.").foregroundStyle(.secondary)
                default:
                    BrandMark(size: 40).foregroundStyle(Palette.inkTertiary)
                    Text("Nothing copied yet").font(.title3.weight(.semibold))
                    Text("Copy text, a link, an image, or a file anywhere on your Mac. It appears here.").foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxxl)
    }
}

// MARK: - Collections

@MainActor
enum NewCollectionPrompt {
    static func run(app: AppModel, adding ids: [UUID], completion: (ClipCollection?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Collection"
        alert.informativeText = ids.isEmpty ? "Name your collection." : "\(ids.count) clip\(ids.count == 1 ? "" : "s") will be added."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { completion(nil); return }
        completion(app.createCollection(name: field.stringValue, adding: ids))
    }
}

private struct CollectionEditor: View {
    @Environment(AppModel.self) private var app
    @State var collection: ClipCollection
    var done: () -> Void
    @State private var shortcut: KeyShortcut?

    private let symbols = ["square.stack", "folder", "star", "bookmark", "tag", "paintpalette", "chevron.left.forwardslash.chevron.right", "envelope", "person.2", "link", "photo", "doc.text", "lightbulb", "briefcase", "graduationcap", "cart", "airplane", "house", "heart", "flag"]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Edit Collection").font(.headline)
            TextField("Name", text: $collection.name).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Icon").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 10), spacing: 6) {
                    ForEach(symbols, id: \.self) { s in
                        Button { collection.symbol = s } label: {
                            Image(systemName: s).frame(width: 30, height: 30)
                                .background(collection.symbol == s ? Palette.chipFillSelected : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Accent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: Space.s) {
                    ForEach(CollectionAccent.allCases) { a in
                        Button { collection.accent = a } label: {
                            Circle().fill(a.color).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Palette.ink, lineWidth: collection.accent == a ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(a.name)
                    }
                }
            }
            HStack {
                Text("Shortcut").font(.callout)
                Spacer()
                ShortcutRecorder(shortcut: $shortcut, allowsClear: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    _ = try? app.store.saveCollection(collection)
                    app.settings.collectionShortcuts[collection.id.uuidString] = shortcut
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(collection.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 420)
        .onAppear { shortcut = app.settings.collectionShortcuts[collection.id.uuidString] }
    }
}

// MARK: - Snippets

private struct SnippetEditor: View {
    @Environment(AppModel.self) private var app
    @State var draft: SnippetDraft
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(draft.clipID == nil ? "New Snippet" : "Edit Snippet").font(.headline)
            TextField("Title (optional)", text: $draft.title).textFieldStyle(.roundedBorder)
            TextEditor(text: $draft.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(Space.s)
                .background(Palette.cardSunken, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .frame(minHeight: 180)
            let placeholders = TemplateEngine.placeholders(in: draft.text)
            Text(placeholders.isEmpty ? "Tip: add {{first_name}}, {{company}}, {{date}}, or any {{custom_name}} to make a template. You’ll fill them in before pasting." : "Template with \(placeholders.map(\.displayName).joined(separator: ", "))")
                .font(.caption).foregroundStyle(Palette.inkTertiary)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.newSnippet(text: draft.text, title: draft.title.isEmpty ? nil : draft.title)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
    }
}
