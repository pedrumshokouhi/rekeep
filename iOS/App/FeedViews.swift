import UniformTypeIdentifiers
import Observation
import RekeepKit
import SwiftUI
import UIKit

/// Query state shared by the iPhone feed and the iPad grid.
@Observable
@MainActor
final class FeedState {
    var scope: MobileScope = .history { didSet { if scope != oldValue { reload() } } }
    var query = "" { didSet { if query != oldValue { scheduleReload() } } }
    var kind: ClipKind? { didSet { if kind != oldValue { reload() } } }
    private(set) var clips: [Clip] = []
    private(set) var hasMore = false
    var selection: Set<UUID> = []
    private var task: Task<Void, Never>?
    weak var model: MobileModel?

    var selectedClips: [Clip] { clips.filter { selection.contains($0.id) } }

    func title(_ model: MobileModel) -> String {
        switch scope {
        case .history: "Rekeep"
        case .favorites: "Favorites"
        case .snippets: "Snippets"
        case .collection(let id): model.collections.first { $0.id == id }?.name ?? "Collection"
        }
    }

    func scheduleReload() {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    func reload(append: Bool = false) {
        guard let store = model?.store else { return }
        var q = ClipQuery(text: query, limit: 150)
        q.offset = append ? clips.count : 0
        if let kind { q.kinds = [kind] }
        if !query.isEmpty { q.sort = .relevance }
        switch scope {
        case .history: break
        case .favorites: q.favoritesOnly = true
        case .snippets: q.snippetsOnly = true
        case .collection(let id): q.collectionID = id
        }
        let query = q
        Task {
            let result = await Task.detached(priority: .userInitiated) { (try? store.fetch(query)) ?? [] }.value
            if append {
                let existing = Set(clips.map(\.id))
                clips += result.filter { !existing.contains($0.id) }
            } else {
                withAnimation(Motion.reflow) { clips = result }
            }
            hasMore = result.count == 150
            selection.formIntersection(Set(clips.map(\.id)))
        }
    }
}

// MARK: - iPhone

struct PhoneRootView: View {
    @Environment(MobileModel.self) private var model
    @State private var feed = FeedState()
    @State private var editMode: EditMode = .inactive
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List(selection: $feed.selection) {
                ForEach(feed.clips) { clip in
                    NavigationLink(value: clip.id) {
                        MobileClipCard(clip: clip)
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { model.copy(clip) } label: { Label("Copy", systemImage: "doc.on.doc") }.tint(Palette.jade)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.delete([clip.id]) } label: { Label("Delete", systemImage: "trash") }
                        Button { model.toggleFavorite([clip]) } label: { Label(clip.isFavorite ? "Unfavorite" : "Favorite", systemImage: clip.isFavorite ? "star.slash" : "star") }.tint(Palette.favorite)
                    }
                    .contextMenu { MobileClipMenu(clips: [clip]) } preview: {
                        MobileClipCard(clip: clip).frame(width: 340).environment(model)
                    }
                    .onAppear { if clip.id == feed.clips.last?.id, feed.hasMore { feed.reload(append: true) } }
                }
                if feed.clips.isEmpty { MobileEmptyState(feed: feed).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.shelfSolid.opacity(0.5).ignoresSafeArea())
            .environment(\.editMode, $editMode)
            .navigationTitle(feed.title(model))
            .navigationDestination(for: UUID.self) { id in ClipDetailView(clipID: id) }
            .searchable(text: $feed.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search clips")
            .safeAreaInset(edge: .top, spacing: 0) { ScopeBar(scope: $feed.scope).background(.bar) }
            .safeAreaInset(edge: .bottom, spacing: 0) { ClipboardBanner().animation(Motion.panel, value: model.clipboardHasNewContent) }
            .refreshable { feed.reload(); model.checkClipboard() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editMode.isEditing {
                        Button("Done") { editMode = .inactive; feed.selection = [] }
                    } else {
                        Menu {
                            Button { editMode = .active } label: { Label("Select", systemImage: "checkmark.circle") }
                            Picker("Type", selection: $feed.kind) {
                                Text("All Types").tag(ClipKind?.none)
                                ForEach(ClipKind.filterable) { Label($0.label, systemImage: $0.symbol).tag(ClipKind?.some($0)) }
                            }
                            Divider()
                            Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                        } label: {
                            Image(systemName: feed.kind == nil ? "ellipsis.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityLabel("More")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PasteButton(supportedContentTypes: [.plainText, .url, .image, .png, .jpeg]) { providers in
                        Task { @MainActor in model.importProviders(providers, fromClipboard: true) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    AddMenu()
                }
                if editMode.isEditing {
                    ToolbarItemGroup(placement: .bottomBar) {
                        let selected = feed.selectedClips
                        Button("Copy") { model.copyTogether(selected) }.disabled(selected.isEmpty)
                        Spacer()
                        Button("Compose") { model.startCompose(selected.map(\.id)); editMode = .inactive }.disabled(selected.count < 2)
                        Spacer()
                        Menu("Add To") {
                            ForEach(model.collections) { c in Button(c.name) { model.add(selected.map(\.id), to: c) } }
                        }
                        .disabled(selected.isEmpty || model.collections.isEmpty)
                        Spacer()
                        Button(role: .destructive) { model.delete(selected.map(\.id)) } label: { Image(systemName: "trash") }
                            .disabled(selected.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { MobileSettingsView() }
        }
        .onAppear { feed.model = model; feed.reload() }
        .onChange(of: model.revision) { _, _ in feed.reload() }
    }
}

struct MobileEmptyState: View {
    @Environment(MobileModel.self) private var model
    var feed: FeedState

    var body: some View {
        VStack(spacing: 10) {
            if !feed.query.isEmpty {
                Image(systemName: "magnifyingglass").font(.largeTitle.weight(.light)).foregroundStyle(Palette.inkTertiary)
                Text("No matches for “\(feed.query)”").font(.headline)
            } else if feed.scope == .history {
                BrandMarkTwoTone(size: 44).padding(.bottom, 4)
                Text("Nothing saved yet").font(.headline)
                Text("Tap the Paste button to save what’s on your clipboard, or share anything to Rekeep from another app.")
                    .font(.subheadline).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            } else {
                Image(systemName: "square.stack").font(.largeTitle.weight(.light)).foregroundStyle(Palette.inkTertiary)
                Text("Nothing here yet").font(.headline)
                Text("Long-press any clip to add it.").font(.subheadline).foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }
}

/// Long-press actions shared by iPhone and iPad.
struct MobileClipMenu: View {
    @Environment(MobileModel.self) private var model
    let clips: [Clip]

    var body: some View {
        if clips.count == 1, let clip = clips.first {
            Button { model.copy(clip) } label: { Label("Copy", systemImage: "doc.on.doc") }
            if clip.kind != .image, clip.kind != .file {
                Button { model.copy(clip, plainText: true) } label: { Label("Copy as Plain Text", systemImage: "textformat") }
            }
            ShareLink(items: model.shareItems(for: clip).compactMap { $0 as? String }) { Label("Share", systemImage: "square.and.arrow.up") }
        } else {
            Button { model.copyTogether(clips) } label: { Label("Copy \(clips.count) Together", systemImage: "doc.on.doc") }
            Button { model.startCompose(clips.map(\.id)) } label: { Label("Compose", systemImage: "square.and.pencil") }
        }
        Button { model.toggleFavorite(clips) } label: {
            Label(clips.allSatisfy(\.isFavorite) ? "Remove from Favorites" : "Add to Favorites", systemImage: clips.allSatisfy(\.isFavorite) ? "star.slash" : "star")
        }
        Menu {
            ForEach(model.collections) { c in
                Button { model.add(clips.map(\.id), to: c) } label: { Label(c.name, systemImage: c.symbol) }
            }
        } label: { Label("Add to Collection", systemImage: "square.stack") }
        .disabled(model.collections.isEmpty)
        Divider()
        Button(role: .destructive) { model.delete(clips.map(\.id)) } label: { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - iPad

struct PadRootView: View {
    @Environment(MobileModel.self) private var model
    @State private var feed = FeedState()
    @State private var showingSettings = false
    @State private var newCollection = false
    @State private var newName = ""
    @State private var detailID: UUID?
    @State private var showsInspector = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(feed.scope) }, set: { if let s = $0 { feed.scope = s } })) {
                Section {
                    Label("History", systemImage: "clock").tag(MobileScope.history)
                    Label("Favorites", systemImage: "star").tag(MobileScope.favorites)
                    Label("Snippets", systemImage: "text.quote").tag(MobileScope.snippets)
                }
                Section("Collections") {
                    ForEach(model.collections) { c in
                        Label { HStack { Text(c.name); Spacer(); Text("\(model.collectionCounts[c.id] ?? 0)").foregroundStyle(.tertiary) } } icon: {
                            Image(systemName: c.symbol).foregroundStyle(c.accent.color)
                        }
                        .tag(MobileScope.collection(c.id))
                        .dropDestination(for: String.self) { items, _ in
                            let ids = feed.selection.isEmpty ? [] : Array(feed.selection)
                            guard !ids.isEmpty else { return false }
                            model.add(ids, to: c)
                            return true
                        }
                        .contextMenu {
                            Button(role: .destructive) { try? model.store.deleteCollection(c.id) } label: { Label("Delete Collection", systemImage: "trash") }
                        }
                    }
                    Button { newCollection = true } label: { Label("New Collection", systemImage: "plus") }
                }
            }
            .navigationTitle("Rekeep")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
            }
        } detail: {
            HStack(spacing: 0) {
                grid
                if showsInspector {
                    Divider()
                    Group {
                        if let id = detailID, feed.clips.contains(where: { $0.id == id }) {
                            NavigationStack { ClipDetailView(clipID: id) }.id(id)
                        } else {
                            ContentUnavailableView("No Clip Selected", systemImage: "square.on.square", description: Text("Select a clip to see its details."))
                        }
                    }
                    .frame(width: 360)
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(Motion.panel, value: showsInspector)
            .navigationTitle(feed.title(model))
            .searchable(text: $feed.query, prompt: "Search clips")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Type", selection: $feed.kind) {
                            Text("All Types").tag(ClipKind?.none)
                            ForEach(ClipKind.filterable) { Label($0.label, systemImage: $0.symbol).tag(ClipKind?.some($0)) }
                        }
                    } label: { Image(systemName: feed.kind == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                    .accessibilityLabel("Filter")
                    PasteButton(supportedContentTypes: [.plainText, .url, .image, .png, .jpeg]) { providers in
                        Task { @MainActor in model.importProviders(providers, fromClipboard: true) }
                    }
                    .labelStyle(.iconOnly)
                    AddMenu()
                    Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.trailing") }.accessibilityLabel("Details")
                }
            }
            // Hardware keyboard
            .onKeyPress(.leftArrow) { move(-1); return .handled }
            .onKeyPress(.rightArrow) { move(1); return .handled }
            .onKeyPress(.return) { if let c = feed.selectedClips.first { model.copy(c) }; return .handled }
            .onKeyPress(.delete) { if !feed.selection.isEmpty { model.delete(Array(feed.selection)) }; return .handled }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { feed.model = model; feed.reload() }
        .onChange(of: model.revision) { _, _ in feed.reload() }
        .sheet(isPresented: $showingSettings) { MobileSettingsView() }
        .alert("New Collection", isPresented: $newCollection) {
            TextField("Name", text: $newName)
            Button("Create") { model.createCollection(name: newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private var grid: some View {
        ScrollView {
            if feed.clips.isEmpty { MobileEmptyState(feed: feed) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 16)], spacing: 16) {
                ForEach(feed.clips) { clip in
                    MobileClipCard(clip: clip, compact: true, isSelected: feed.selection.contains(clip.id))
                        .onTapGesture(count: 2) { model.copy(clip) }
                        .onTapGesture {
                            feed.selection = [clip.id]
                            detailID = clip.id
                            showsInspector = true
                        }
                        .contextMenu { MobileClipMenu(clips: feed.selection.contains(clip.id) && feed.selection.count > 1 ? feed.selectedClips : [clip]) }
                        .draggable(clip.plainText)
                        .hoverEffect(.lift)
                        .onAppear { if clip.id == feed.clips.last?.id, feed.hasMore { feed.reload(append: true) } }
                }
            }
            .padding(20)
        }
        .background(Palette.cardSunken.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { ClipboardBanner().frame(maxWidth: 560) }
    }

    private func move(_ delta: Int) {
        guard !feed.clips.isEmpty else { return }
        let i = feed.clips.firstIndex { feed.selection.contains($0.id) } ?? -1
        let next = min(max(i + delta, 0), feed.clips.count - 1)
        feed.selection = [feed.clips[next].id]
        detailID = feed.clips[next].id
    }
}
