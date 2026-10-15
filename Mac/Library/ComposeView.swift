import AppKit
import RekeepKit
import SwiftUI
import UniformTypeIdentifiers

/// Combine selected clips into one useful output. Deterministic; source clips stay intact.
struct ComposeView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [ComposeItem] = []
    @State private var options = ComposeOptions()
    @State private var compositionID = UUID()
    @State private var loadedSelection: [UUID] = []
    @State private var adding = false

    private var output: String { Composer.render(items, options: options) }

    var body: some View {
        HSplitView {
            sources
                .frame(minWidth: 320, idealWidth: 400)
            outputPane
                .frame(minWidth: 360)
        }
        .navigationTitle("Compose")
        .navigationSubtitle(items.isEmpty ? "" : "\(Composer.prepared(items, options: options).count) of \(items.count) included")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    let saved = app.store.compositions()
                    if saved.isEmpty { Text("No saved compositions") }
                    ForEach(saved) { c in
                        Button(c.options.title.isEmpty ? "Untitled — \(c.modifiedAt.formatted(date: .abbreviated, time: .shortened))" : c.options.title) { open(c) }
                    }
                } label: { Label("Saved", systemImage: "tray.full") }
                .help("Open a saved composition")
                Button { newComposition() } label: { Label("New", systemImage: "plus") }
                    .help("Start a new composition")
            }
        }
        .onAppear(perform: syncSelection)
        .onChange(of: app.composeSelection) { _, _ in syncSelection() }
        .sheet(isPresented: $adding) { ClipPicker { picked in append(picked) } }
    }

    // MARK: Sources

    private var sources: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                VStack(spacing: Space.s) {
                    Image(systemName: "square.and.pencil").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.inkTertiary)
                    Text("Combine clips into one piece").font(.headline)
                    Text("Select several clips in the shelf or library and choose Compose, or add them here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add Clips…") { adding = true }.buttonStyle(.borderedProminent).tint(Palette.jade).padding(.top, Space.s)
                }
                .padding(Space.xxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($items) { $item in
                        SourceTile(item: $item, duplicate: isDuplicate(item)) {
                            items.removeAll { $0.id == item.id }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                HStack {
                    Button { adding = true } label: { Label("Add Clips", systemImage: "plus") }
                    Spacer()
                    Text("Drag to reorder").font(.caption).foregroundStyle(Palette.inkTertiary)
                }
                .padding(Space.m)
            }
        }
        .background(Palette.cardSunken.opacity(0.5))
    }

    private func isDuplicate(_ item: ComposeItem) -> Bool {
        guard options.removeDuplicates, item.isIncluded else { return false }
        let key = item.snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = items.first(where: { $0.isIncluded && $0.snapshot.trimmingCharacters(in: .whitespacesAndNewlines) == key }) else { return false }
        return first.id != item.id
    }

    // MARK: Output

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Title", text: $options.title)
                Picker("Format", selection: $options.format) {
                    ForEach(ComposeFormat.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                if options.format == .plainText || options.format == .markdown {
                    Picker("Separator", selection: $options.separator) {
                        ForEach(ComposeSeparator.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Include source links (only those actually captured)", isOn: $options.includeSourceLinks)
                Toggle("Include capture dates", isOn: $options.includeDates)
                Toggle("Remove exact duplicates", isOn: $options.removeDuplicates)
            }
            .formStyle(.grouped)
            .frame(height: options.format == .plainText || options.format == .markdown ? 270 : 232)
            .scrollDisabled(true)

            HStack {
                Text("Output").font(.caption.weight(.semibold)).foregroundStyle(Palette.inkTertiary).textCase(.uppercase)
                Spacer()
                Text("\(output.count.formatted()) characters").font(.caption).foregroundStyle(Palette.inkTertiary).monospacedDigit()
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.xs)
            ScrollView {
                Text(output.isEmpty ? " " : output)
                    .font(.system(size: 12.5, design: options.format == .plainText || options.format == .emailOutline ? .default : .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Space.l)
            }
            .contentSurface(radius: 12)
            .padding(.horizontal, Space.l)
            HStack {
                Button("Save Composition") { save() }.disabled(items.isEmpty)
                Spacer()
                Button("Export…") { export() }.disabled(items.isEmpty)
                Button("Copy") { app.deliver(text: output, paste: false) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.jade)
                    .disabled(items.isEmpty)
            }
            .padding(Space.l)
        }
    }

    // MARK: Actions

    private func syncSelection() {
        guard app.composeSelection != loadedSelection, !app.composeSelection.isEmpty else { return }
        loadedSelection = app.composeSelection
        let clips = app.store.clips(app.composeSelection)
        let existing = Set(items.map(\.clipID))
        items.append(contentsOf: clips.filter { !existing.contains($0.id) }.map { ComposeItem(clip: $0) })
    }

    private func append(_ clips: [Clip]) {
        let existing = Set(items.map(\.clipID))
        items.append(contentsOf: clips.filter { !existing.contains($0.id) }.map { ComposeItem(clip: $0) })
    }

    private func newComposition() {
        items = []
        options = ComposeOptions()
        compositionID = UUID()
        app.composeSelection = []
        loadedSelection = []
    }

    private func open(_ c: Composition) {
        items = c.items
        options = c.options
        compositionID = c.id
    }

    private func save() {
        try? app.store.save(Composition(id: compositionID, items: items, options: options))
        app.show(Toast(style: .success, title: "Composition saved"))
    }

    private func export() {
        let panel = NSSavePanel()
        let isMarkdown = options.format != .plainText && options.format != .emailOutline
        panel.allowedContentTypes = [isMarkdown ? UTType(filenameExtension: "md") ?? .plainText : .plainText]
        panel.nameFieldStringValue = (options.title.isEmpty ? "Composition" : options.title) + (isMarkdown ? ".md" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            app.show(Toast(style: .success, title: "Exported", detail: url.lastPathComponent))
        } catch {
            app.show(Toast(style: .failure, title: "Couldn’t export", detail: error.localizedDescription))
        }
    }
}

private struct SourceTile: View {
    @Binding var item: ComposeItem
    var duplicate: Bool
    var onRemove: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: "line.3.horizontal").foregroundStyle(Palette.inkTertiary).font(.system(size: 11)).padding(.top, 3)
                    .accessibilityHidden(true)
                Toggle("", isOn: $item.isIncluded).toggleStyle(.checkbox).labelsHidden()
                    .help(item.isIncluded ? "Exclude from output" : "Include in output")
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.snapshot.prefix(400))
                        .font(item.kindRaw == ClipKind.code.rawValue ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                        .foregroundStyle(item.isIncluded ? Palette.ink : Palette.inkTertiary)
                        .lineLimit(expanded ? 20 : 3)
                    HStack(spacing: Space.xs) {
                        if let url = item.sourceURL { Text(url.host() ?? url.absoluteString).lineLimit(1) }
                        if let app = item.sourceAppName { Text(app) }
                        if duplicate { Text("Duplicate — skipped").foregroundStyle(Palette.favorite) }
                    }
                    .font(.cardMeta)
                    .foregroundStyle(Palette.inkTertiary)
                }
                Spacer(minLength: 0)
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless).help(expanded ? "Collapse" : "Add heading or note")
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove from composition")
            }
            if expanded {
                TextField("Heading", text: $item.heading).textFieldStyle(.roundedBorder)
                TextField("Note", text: $item.note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            }
        }
        .padding(Space.m)
        .contentSurface(radius: 12)
        .opacity(duplicate ? 0.6 : 1)
    }
}

/// A searchable picker for adding clips to a composition.
struct ClipPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var onPick: ([Clip]) -> Void
    @State private var query = ""
    @State private var results: [Clip] = []
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search clips", text: $query).textFieldStyle(.roundedBorder).padding(Space.m)
            List(results, selection: $selection) { clip in
                ClipRow(clip: clip, isSelected: false).tag(clip.id)
            }
            .listStyle(.plain)
            HStack {
                Text("\(selection.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { onPick(results.filter { selection.contains($0.id) }); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(selection.isEmpty)
            }
            .padding(Space.m)
        }
        .frame(width: 560, height: 460)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(80))
            let store = app.store, q = ClipQuery(text: query, limit: 200)
            results = await Task.detached { (try? store.fetch(q)) ?? [] }.value
        }
    }
}

/// The sequential paste queue.
struct QueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if app.queue.isEmpty {
                VStack(spacing: Space.s) {
                    Image(systemName: "list.number").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.inkTertiary)
                    Text("Paste several things, in order").font(.headline)
                    Text("Add clips to the queue (⌘K in the shelf), then press \(app.settings.queueShortcut?.display ?? "the queue shortcut") anywhere to paste the next one.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let clips = app.store.clips(app.queue.clipIDs)
                List {
                    ForEach(Array(app.queue.clipIDs.enumerated()), id: \.offset) { index, id in
                        HStack(spacing: Space.m) {
                            Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(index == app.queue.cursor ? Palette.jadeInk : Palette.inkTertiary)
                                .frame(width: 22)
                            if let clip = clips.first(where: { $0.id == id }) {
                                ClipRow(clip: clip, isSelected: index == app.queue.cursor)
                                    .opacity(index < app.queue.cursor ? 0.45 : 1)
                            }
                        }
                    }
                    .onMove { app.queue.move(from: $0, to: $1) }
                    .onDelete { app.queue.remove(at: $0) }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Paste Queue")
        .navigationSubtitle(app.queue.isEmpty ? "" : (app.queue.isFinished ? "Finished" : "\(app.queue.remaining) waiting\(app.queue.isPaused ? " · Paused" : "")"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.pasteNextFromQueue() } label: { Label("Copy Next", systemImage: "arrow.right.circle") }
                    .disabled(app.queue.upNext == nil || app.queue.isPaused)
                    .help("Copy the next item")
                Button { app.queue.isPaused.toggle() } label: { Label(app.queue.isPaused ? "Resume" : "Pause", systemImage: app.queue.isPaused ? "play" : "pause") }
                    .disabled(app.queue.isEmpty)
                Button { app.queue.reverse() } label: { Label("Reverse", systemImage: "arrow.up.arrow.down") }
                    .disabled(app.queue.isEmpty).help("Reverse order")
                Button { app.queue.restart() } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                    .disabled(app.queue.isEmpty).help("Start again from the first item")
                Button { app.queue.clear() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(app.queue.isEmpty).help("Clear the queue")
            }
        }
    }
}
