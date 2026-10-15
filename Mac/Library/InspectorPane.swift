import AppKit
import RekeepKit
import SwiftUI

/// Details and editing for the selected clip.
struct InspectorPane: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel

    var body: some View {
        Group {
            if let clip = model.primaryClip {
                ClipInspector(clip: clip, model: model).id(clip.id)
            } else if model.selection.count > 1 {
                VStack(spacing: Space.s) {
                    Image(systemName: "square.on.square").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.inkTertiary)
                    Text("\(model.selection.count) clips selected").font(.headline)
                    Text("Use the bar below to copy, compose, queue, or organise them together.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a clip to see its details.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ClipInspector: View {
    @Environment(AppModel.self) private var app
    let clip: Clip
    @Bindable var model: LibraryModel

    @State private var title = ""
    @State private var text = ""
    @State private var note = ""
    @State private var tags = ""
    @State private var memberships: Set<UUID> = []
    @State private var previousText: String?

    private var textChanged: Bool { clip.isTextEditable && text != (clip.text ?? "") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if clip.kind != .text && clip.kind != .code {
                    ClipContentView(clip: clip, mode: .preview)
                        .frame(height: 260)
                        .contentSurface(radius: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if clip.isTextEditable && (clip.kind == .text || clip.kind == .code) {
                    section("Content") {
                        TextEditor(text: $text)
                            .font(clip.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(Space.s)
                            .frame(minHeight: 160, maxHeight: 320)
                            .background(Palette.cardSunken, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        if textChanged {
                            HStack {
                                Text("Unsaved edit").font(.caption).foregroundStyle(Palette.inkTertiary)
                                Spacer()
                                Button("Revert") { text = clip.text ?? "" }
                                Button("Save") { saveText() }.keyboardShortcut("s", modifiers: .command)
                            }
                            .controlSize(.small)
                        } else if previousText != nil {
                            HStack {
                                Text("Edited").font(.caption).foregroundStyle(Palette.inkTertiary)
                                Spacer()
                                Button("Undo Edit") { undoEdit() }.controlSize(.small)
                            }
                        }
                    }
                }

                section("Title") {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                        .onSubmit { commitMeta() }
                }
                section("Note") {
                    TextField("Add a note", text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                        .onSubmit { commitMeta() }
                }
                section("Tags") {
                    TextField("Comma-separated", text: $tags).textFieldStyle(.roundedBorder)
                        .onSubmit { commitMeta() }
                }
                section("Collections") {
                    if app.collections.isEmpty {
                        Text("No collections yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(app.collections) { c in
                        Toggle(isOn: Binding(get: { memberships.contains(c.id) }, set: { on in
                            if on { try? app.store.add([clip.id], to: c.id); memberships.insert(c.id) }
                            else { try? app.store.remove([clip.id], from: c.id); memberships.remove(c.id) }
                        })) {
                            Label(c.name, systemImage: c.symbol)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                section("Options") {
                    Toggle("Favorite", isOn: Binding(get: { clip.isFavorite }, set: { try? app.store.setFavorite([clip.id], $0) }))
                    Toggle("Use as snippet (never pruned)", isOn: Binding(get: { clip.isSnippet }, set: { v in try? app.store.update(clip.id) { $0.isSnippet = v } }))
                    Toggle("Keep on this Mac only", isOn: Binding(get: { clip.isLocalOnly }, set: { v in try? app.store.update(clip.id) { $0.isLocalOnly = v } }))
                }
                section("Details") {
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: 6) {
                        detail("Type", ClipFormatting.typeLabel(for: clip))
                        if let app = clip.sourceAppName { detail("Copied in", app) }
                        if let url = clip.sourceURL { detail("Source", url.absoluteString) }
                        detail("First copied", clip.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if clip.capturedAt != clip.createdAt { detail("Last copied", clip.capturedAt.formatted(date: .abbreviated, time: .shortened)) }
                        if clip.useCount > 0 { detail("Reused", "\(clip.useCount) time\(clip.useCount == 1 ? "" : "s")") }
                        detail("Size", ByteCountFormatter.string(fromByteCount: clip.byteSize, countStyle: .file))
                        if let device = clip.deviceName { detail("Device", device) }
                        if let expires = clip.expiresAt { detail("Expires", expires.formatted(date: .omitted, time: .shortened)) }
                        detail("Stored", clip.isLocalOnly ? "This Mac only" : "This Mac")
                    }
                    .font(.callout)
                }
                HStack {
                    Button("Copy") { app.activate(clip, paste: false) }
                    Button("Copy as Plain Text") { app.activate(clip, plainText: true, paste: false) }
                    Spacer()
                    Menu {
                        Button("Show in History") { model.showInHistory(clip.id) }
                        Button("Duplicate") { _ = try? app.store.duplicate(clip.id) }
                        Button("Add to Paste Queue") { app.enqueue([clip.id]) }
                        Divider()
                        Button("Delete", role: .destructive) { app.delete([clip.id]) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(Space.l)
        }
        .onAppear(perform: load)
        .onDisappear { commitMeta() }
    }

    private func load() {
        title = clip.title
        text = clip.text ?? ""
        note = clip.note ?? ""
        tags = clip.tags.joined(separator: ", ")
        memberships = app.store.collectionIDs(for: clip.id)
    }

    private func commitMeta() {
        let newTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let newNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newTags != clip.tags || (newNote.isEmpty ? nil : newNote) != clip.note || (!newTitle.isEmpty && newTitle != clip.title) else { return }
        try? app.store.update(clip.id) { c in
            c.tags = newTags
            c.note = newNote.isEmpty ? nil : newNote
            if !newTitle.isEmpty { c.title = newTitle }
        }
    }

    private func saveText() {
        previousText = clip.text
        let newText = text
        try? app.store.update(clip.id) { $0.text = newText }
        app.show(Toast(style: .success, title: "Saved", detail: "Copies of this clip will use the edited text."))
    }

    private func undoEdit() {
        guard let old = previousText else { return }
        try? app.store.update(clip.id) { $0.text = old }
        text = old
        previousText = nil
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.inkTertiary).textCase(.uppercase)
            content()
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Palette.inkTertiary)
            Text(value).foregroundStyle(Palette.ink).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}
