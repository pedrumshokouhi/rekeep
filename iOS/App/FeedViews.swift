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
    @State private var path: [UUID] = []
    @State private var searchPresented = false
    #if DEBUG
    @State private var demoKeyboard: DemoKeyboard?
    #endif

    var body: some View {
        NavigationStack(path: $path) {
          ScrollViewReader { proxy in
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
            .environment(\.searchTerms, SearchHighlight.terms(feed.query))
            .navigationTitle(feed.title(model))
            // Inline only: when a short scope reloads, an automatic title expands to a large title
            // that renders blurred under the scope bar and pushes the search field down.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in ClipDetailView(clipID: id) }
            .searchable(text: $feed.query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search clips")
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
            #if DEBUG
            .onAppear {
                // Unstructured and once: a view task is cancelled when a detail view is pushed.
                guard ProcessInfo.processInfo.arguments.contains("-qa.demo"), !DemoRun.started else { return }
                DemoRun.started = true
                Task { await runDemo(proxy) }
            }
            #endif
          }
        }
        #if DEBUG
        .overlay {
            if let demoKeyboard { DemoKeyboardScene(demo: demoKeyboard).transition(.move(edge: .bottom)) }
        }
        #endif
        .onAppear {
            feed.model = model
            #if DEBUG
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-qa.query"), i + 1 < ProcessInfo.processInfo.arguments.count {
                feed.query = ProcessInfo.processInfo.arguments[i + 1]
            }
            #endif
            feed.reload()
        }
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
                Text("No matches for “\(feed.query.trimmingCharacters(in: .whitespaces))”").font(.headline)
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
            .environment(\.searchTerms, SearchHighlight.terms(feed.query))
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
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-qa.select") else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if let first = feed.clips.dropFirst(1).first { feed.selection = [first.id]; detailID = first.id; showsInspector = true }
        }
        #endif
        .onAppear {
            feed.model = model
            #if DEBUG
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-qa.query"), i + 1 < ProcessInfo.processInfo.arguments.count {
                feed.query = ProcessInfo.processInfo.arguments[i + 1]
            }
            #endif
            feed.reload()
        }
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
            MasonryLayout(minColumnWidth: 250, spacing: 16) {
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

#if DEBUG
// MARK: - Scripted demo (-qa.demo), recorded for the product video

@MainActor enum DemoRun { static var started = false }

extension PhoneRootView {
    /// Drives the real feed on a fixed timeline so a screen recording needs no manual input.
    func runDemo(_ proxy: ScrollViewProxy) async {
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await wait(1.8)
        let ids = feed.clips.map(\.id)
        if ids.count > 6 {
            withAnimation(.smooth(duration: 1.2)) { proxy.scrollTo(ids[6], anchor: .top) }
            await wait(1.6)
            withAnimation(.smooth(duration: 1.2)) { proxy.scrollTo(ids[0], anchor: .top) }
            await wait(1.4)
        }
        for scope in [MobileScope.favorites, .snippets] {
            withAnimation(Motion.panel) { feed.scope = scope }
            await wait(1.5)
        }
        withAnimation(Motion.panel) { feed.scope = .history }
        await wait(1.0)
        searchPresented = true
        await wait(0.7)
        for character in "launch" {
            feed.query.append(character)
            await wait(0.14)
        }
        await wait(2.2)
        feed.query = ""
        searchPresented = false
        await wait(1.0)
        if let code = feed.clips.first(where: { $0.kind == .code }) {
            path.append(code.id)
            await wait(2.8)
            path.removeAll()
            await wait(1.0)
        }
        if let first = feed.clips.first {
            model.copy(first)
            await wait(1.8)
        }
        let keyboard = DemoKeyboard()
        withAnimation(.smooth(duration: 0.5)) { demoKeyboard = keyboard }
        await wait(1.6)
        if let link = keyboard.state.clips.first(where: { $0.kind == .link }) { keyboard.state.use(link) }
        await wait(2.6)
        withAnimation(Motion.panel) { keyboard.state.scope = .snippets }
        await wait(1.4)
        withAnimation(Motion.panel) { keyboard.state.scope = .recent }
        await wait(2.0)
    }
}

@Observable
@MainActor
final class DemoKeyboard {
    var message = "Here’s the doc I mentioned: "
    let state = KeyboardState()
    init() {
        state.hasFullAccess = true
        state.needsGlobe = true
        state.insert = { [weak self] text in self?.message += text }
        state.load()
    }
}

/// A plain message composer with the real Rekeep keyboard view under it.
struct DemoKeyboardScene: View {
    let demo: DemoKeyboard
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                bubble("Morning! Do you have that Liquid Glass doc?")
                bubble("The one from yesterday’s review")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 70)
            Spacer()
            HStack(alignment: .bottom, spacing: 10) {
                Text(demo.message)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Palette.card, in: .rect(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.cardStroke))
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(Palette.jade)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            KeyboardView(state: demo.state)
                .frame(height: 268)
                .background(Color(uiColor: .systemGray5))
        }
        .background(Palette.shelfSolid.ignoresSafeArea())
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.chipFillSelected, in: .rect(cornerRadius: 18))
            .frame(maxWidth: 280, alignment: .leading)
    }
}
#endif
