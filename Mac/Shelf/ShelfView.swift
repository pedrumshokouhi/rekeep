import AppKit
import RekeepKit
import SwiftUI
import UniformTypeIdentifiers

/// The quick shelf: a glass control strip above a horizontal row of content cards.
struct ShelfView: View {
    @Environment(AppModel.self) private var app
    @Bindable var shelf: ShelfModel
    @FocusState private var searchFocused: Bool
    @State private var newCollectionName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var density: ShelfDensity { app.settings.density }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.shelf, style: .continuous) }

    var body: some View {
        VStack(spacing: Space.m) {
            NavStrip(shelf: shelf, searchFocused: $searchFocused, newCollectionName: $newCollectionName)
            content
        }
        .padding(Radius.shelfInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .controlSurface(shape)
        .opacity(shelf.isVisible ? 1 : 0)
        .offset(y: shelf.isVisible || reduceMotion ? 0 : 18)
        .animation(Motion.panel, value: shelf.isVisible)
        .onChange(of: shelf.presentationID) { _, _ in searchFocused = true }
        .onChange(of: app.revision) { _, _ in if shelf.isVisible { shelf.refreshIfNeeded() } }
        .onAppear { searchFocused = true }
        .environment(\.controlActiveState, .key)
        .environment(\.searchTerms, SearchHighlight.terms(shelf.query))
    }

    @ViewBuilder private var content: some View {
        if let banner = statusBanner {
            banner
        }
        if shelf.clips.isEmpty {
            EmptyShelf(shelf: shelf)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if app.settings.useListLayout {
            ShelfList(shelf: shelf)
        } else {
            cardRow
        }
    }

    private var cardRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: density.spacing) {
                    ForEach(Array(shelf.clips.enumerated()), id: \.element.id) { index, clip in
                        ShelfCard(shelf: shelf, clip: clip, index: index, shortcutNumber: shortcutNumber(for: index))
                            .id(clip.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .frame(height: density.cardSize.height + 12)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                // First card whose leading edge is on screen; ⌘1–⌘9 count from here.
                let stride = density.cardSize.width + density.spacing
                shelf.firstVisibleIndex = max(0, Int(((x - 6) / stride).rounded(.up)))
            }
            .onChange(of: shelf.selectedID) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : Motion.micro) { proxy.scrollTo(id) }
            }
            .onChange(of: shelf.presentationID) { _, _ in
                if let first = shelf.clips.first?.id { proxy.scrollTo(first, anchor: .leading) }
            }
        }
    }

    private func shortcutNumber(for index: Int) -> Int? {
        guard shelf.isCommandHeld else { return nil }
        let n = index - shelf.firstVisibleIndex + 1
        return (1...9).contains(n) ? n : nil
    }

    private var statusBanner: AnyView? {
        if app.settings.privacy.isCapturePaused {
            return AnyView(Banner(symbol: "pause.circle", text: "Capture is paused. New copies aren’t being saved.", action: ("Resume", { app.togglePause() })))
        }
        if app.pasteboardAccess == .denied {
            return AnyView(Banner(symbol: "hand.raised", text: "macOS is blocking Rekeep from seeing new copies.", action: ("Open Settings", {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") { NSWorkspace.shared.open(url) }
            })))
        }
        if let issue = app.startupIssue {
            return AnyView(Banner(symbol: "exclamationmark.triangle", text: issue, action: nil))
        }
        return nil
    }
}

/// A card wired to selection, activation, drag, and context actions.
private struct ShelfCard: View {
    @Environment(AppModel.self) private var app
    @Bindable var shelf: ShelfModel
    let clip: Clip
    let index: Int
    let shortcutNumber: Int?

    var body: some View {
        ClipCard(
            clip: clip,
            size: app.settings.density.cardSize,
            isSelected: shelf.selectedID == clip.id,
            isMultiSelected: shelf.multiSelection.contains(clip.id) && shelf.selectedID != clip.id,
            shortcutNumber: shortcutNumber,
            collectionAccents: [],
            onFavorite: { app.toggleFavorite([clip]) }
        )
        .onTapGesture(count: 2) { app.activate(clip) }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { shelf.select(clip, extend: false, toggle: true) })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded { shelf.select(clip, extend: true, toggle: false) })
        .onTapGesture { shelf.select(clip, extend: false, toggle: false) }
        .onDrag { ClipDrag.provider(for: clip, store: app.store) }
        .contextMenu { ClipContextMenu(clips: shelf.multiSelection.contains(clip.id) ? shelf.actionClips : [clip], shelf: shelf) }
        .onAppear { shelf.loadMoreIfNeeded(currentIndex: index) }
    }
}

// MARK: - Nav strip

private struct NavStrip: View {
    @Environment(AppModel.self) private var app
    @Bindable var shelf: ShelfModel
    var searchFocused: FocusState<Bool>.Binding
    @Binding var newCollectionName: String?

    var body: some View {
        HStack(spacing: Space.s) {
            SearchField(text: $shelf.query, focused: searchFocused)
            ScrollView(.horizontal) {
                HStack(spacing: Space.xs) {
                    ScopeChip(title: "History", symbol: "clock", accent: nil, isOn: shelf.scope == .history) { shelf.scope = .history }
                    ScopeChip(title: "Favorites", symbol: "star", accent: nil, isOn: shelf.scope == .favorites) { shelf.scope = .favorites }
                    ScopeChip(title: "Snippets", symbol: "text.quote", accent: nil, isOn: shelf.scope == .snippets) { shelf.scope = .snippets }
                    if !app.collections.isEmpty {
                        Divider().frame(height: 16).padding(.horizontal, 2)
                    }
                    ForEach(app.collections) { c in
                        ScopeChip(title: c.name, symbol: c.symbol, accent: c.accent, isOn: shelf.scope == .collection(c.id)) { shelf.scope = .collection(c.id) }
                            .onDrop(of: [.data], isTargeted: nil) { _ in
                                // Drags that start on a Rekeep card carry the clip identity in-process.
                                let ids = ClipDrag.draggingIDs
                                guard !ids.isEmpty else { return false }
                                app.add(ids, to: c)
                                ClipDrag.draggingIDs = []
                                return true
                            }
                    }
                    NewCollectionButton(shelf: shelf)
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)

            if app.settings.showKeyboardHints {
                HStack(spacing: Space.m) {
                    KeyHint(keys: ["↩"], label: "Copy")
                    KeyHint(keys: ["⇧", "↩"], label: "Plain")
                    KeyHint(keys: ["Space"], label: "Preview")
                }
                .fixedSize()
                .padding(.trailing, Space.xs)
                .accessibilityHidden(true)
            }
            if !app.queue.isEmpty {
                QueueBadge()
            }
            KindFilterMenu(selection: $shelf.kindFilter)
            IconButton(symbol: "rectangle.grid.2x2", help: "Open Library (⌘L)") { app.openLibrary(nil) }
        }
        .frame(height: 34)
    }
}

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkTertiary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                .accessibilityLabel("Search clips")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search (esc)")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: text.isEmpty ? 180 : 260, height: 30)
        .background(Palette.chipFill, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .animation(Motion.micro, value: text.isEmpty)
    }
}

struct ScopeChip: View {
    var title: String
    var symbol: String
    var accent: CollectionAccent?
    var isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent?.color ?? (isOn ? Palette.ink : Palette.inkSecondary))
                Text(title)
                    .font(.chip)
                    .foregroundStyle(isOn ? Palette.ink : Palette.inkSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(isOn ? Palette.chipFillSelected : (hovering ? Palette.chipFill : .clear), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct NewCollectionButton: View {
    @Environment(AppModel.self) private var app
    @Bindable var shelf: ShelfModel
    @State private var isNaming = false
    @State private var name = ""

    var body: some View {
        IconButton(symbol: "plus", help: "New Collection") { isNaming = true }
            .popover(isPresented: $isNaming, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("New Collection").font(.headline)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit(create)
                    HStack {
                        Spacer()
                        Button("Cancel") { isNaming = false }
                        Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(Space.l)
            }
    }

    private func create() {
        let ids = shelf.multiSelection.isEmpty ? [] : Array(shelf.multiSelection)
        if let c = app.createCollection(name: name, adding: ids) {
            shelf.scope = .collection(c.id)
        }
        name = ""
        isNaming = false
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 28, height: 28)
                .background(hovering ? Palette.chipFill : .clear, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct KindFilterMenu: View {
    @Binding var selection: ClipKind?
    var body: some View {
        Menu {
            Picker("Type", selection: $selection) {
                Text("All Types").tag(ClipKind?.none)
                Divider()
                ForEach(ClipKind.filterable) { kind in
                    Label(kind.label, systemImage: kind.symbol).tag(ClipKind?.some(kind))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selection?.symbol ?? "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .semibold))
                if let selection { Text(selection.label).font(.chip) }
            }
            .foregroundStyle(selection == nil ? Palette.inkSecondary : Palette.ink)
            .padding(.horizontal, selection == nil ? 0 : 8)
            .frame(minWidth: 28, minHeight: 28)
            .background(selection == nil ? .clear : Palette.chipFillSelected, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by type")
    }
}

private struct QueueBadge: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Button { app.openLibrary(.queue) } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.number").font(.system(size: 11, weight: .semibold))
                Text("\(app.queue.remaining)").font(.chip).monospacedDigit()
            }
            .foregroundStyle(Palette.jadeInk)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Palette.jade.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Paste Queue — \(app.queue.remaining) waiting")
    }
}

// MARK: - Empty states and banners

private struct EmptyShelf: View {
    @Environment(AppModel.self) private var app
    @Bindable var shelf: ShelfModel

    var body: some View {
        VStack(spacing: Space.s) {
            if shelf.isLoading && shelf.clips.isEmpty {
                ProgressView().controlSize(.small)
            } else if !shelf.query.isEmpty {
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.inkTertiary)
                Text("Nothing matches “\(shelf.query)”").font(.headline).foregroundStyle(Palette.ink)
                if shelf.scope != .history || shelf.kindFilter != nil {
                    Button("Search all history") { shelf.scope = .history; shelf.kindFilter = nil }
                        .buttonStyle(.link)
                } else {
                    Text("Search covers text, links, notes, tags, and text found in images.")
                        .font(.callout).foregroundStyle(Palette.inkSecondary)
                }
            } else if shelf.scope != .history {
                Image(systemName: emptySymbol).font(.system(size: 22, weight: .light)).foregroundStyle(Palette.inkTertiary)
                Text(emptyTitle).font(.headline).foregroundStyle(Palette.ink)
                Text(emptyDetail).font(.callout).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            } else {
                BrandMark(size: 30).foregroundStyle(Palette.inkTertiary)
                Text("Copy anything. It lands here.").font(.headline).foregroundStyle(Palette.ink)
                HStack(spacing: 4) {
                    Text("Open this shelf anytime with").font(.callout).foregroundStyle(Palette.inkSecondary)
                    ForEach(app.settings.shortcut.keycaps, id: \.self) { Keycap(text: $0) }
                }
            }
        }
        .padding(Space.xl)
    }

    private var emptySymbol: String {
        switch shelf.scope {
        case .favorites: "star"
        case .snippets: "text.quote"
        default: "square.stack"
        }
    }
    private var emptyTitle: String {
        switch shelf.scope {
        case .favorites: "No favorites yet"
        case .snippets: "No snippets yet"
        default: "This collection is empty"
        }
    }
    private var emptyDetail: String {
        switch shelf.scope {
        case .favorites: "Press ⌘D on any clip to keep it here. Favorites are never removed by history limits."
        case .snippets: "Write reusable text in the Library. Use {{placeholders}} to make templates."
        default: "Drag clips onto the collection, or right-click a clip and choose Add to Collection."
        }
    }
}

private struct Banner: View {
    var symbol: String
    var text: String
    var action: (String, () -> Void)?
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol).foregroundStyle(Palette.inkSecondary)
            Text(text).font(.callout).foregroundStyle(Palette.ink).lineLimit(2)
            Spacer()
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Palette.chipFill, in: RoundedRectangle(cornerRadius: Radius.chip + 2, style: .continuous))
    }
}

// MARK: - List presentation

private struct ShelfList: View {
    @Environment(AppModel.self) private var app
    @Bindable var shelf: ShelfModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(shelf.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipRow(clip: clip, isSelected: shelf.selectedID == clip.id, isMultiSelected: shelf.multiSelection.contains(clip.id))
                            .id(clip.id)
                            .onTapGesture(count: 2) { app.activate(clip) }
                            .onTapGesture { shelf.select(clip, extend: false, toggle: false) }
                            .onDrag { ClipDrag.provider(for: clip, store: app.store) }
                            .contextMenu { ClipContextMenu(clips: [clip], shelf: shelf) }
                            .onAppear { shelf.loadMoreIfNeeded(currentIndex: index) }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .onChange(of: shelf.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }
}

/// A compact single-line clip presentation used by the list layout and the library list.
struct ClipRow: View {
    let clip: Clip
    var isSelected: Bool
    var isMultiSelected: Bool = false

    var body: some View {
        HStack(spacing: Space.m) {
            SourceIcon(bundleID: clip.sourceBundleID, kind: clip.kind, size: 18)
            if clip.kind == .color, let c = clip.colorValue.flatMap(ColorParser.parse) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha))
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.cardStroke))
            }
            Text(clip.title.isEmpty ? ClipFormatting.typeLabel(for: clip) : clip.title)
                .font(clip.kind == .code ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Space.s)
            if clip.isFavorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Palette.favorite) }
            Text(ClipFormatting.typeLabel(for: clip)).font(.cardMeta).foregroundStyle(Palette.inkTertiary)
            Text(ClipFormatting.relative(clip.capturedAt)).font(.cardMeta).monospacedDigit().foregroundStyle(Palette.inkTertiary).frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, Space.m)
        .frame(height: 34)
        .background(isSelected ? Palette.jade.opacity(0.16) : (isMultiSelected ? Palette.jade.opacity(0.08) : .clear), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(isSelected ? Palette.jade : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
