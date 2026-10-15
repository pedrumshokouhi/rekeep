import UniformTypeIdentifiers
import RekeepKit
import SwiftUI
import UIKit

struct ClipDetailView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let clipID: UUID
    @State private var clip: Clip?
    @State private var text = ""
    @State private var note = ""
    @State private var tags = ""
    @State private var isEditing = false
    @State private var memberships: Set<UUID> = []

    var body: some View {
        Group {
            if let clip {
                Form {
                    Section {
                        if isEditing {
                            TextEditor(text: $text)
                                .font(clip.kind == .code ? .system(.body, design: .monospaced) : .body)
                                .frame(minHeight: 200)
                        } else {
                            MobileClipContent(clip: clip, mode: .detail)
                                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                        }
                    }
                    Section {
                        Button { model.copy(clip) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if clip.kind != .image && clip.kind != .file {
                            Button { model.copy(clip, plainText: true) } label: { Label("Copy as Plain Text", systemImage: "textformat") }
                        }
                        Button { share(clip) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                    }
                    Section("Note") {
                        TextField("Add a note", text: $note, axis: .vertical).onSubmit(commit)
                    }
                    Section("Tags") {
                        TextField("Comma-separated", text: $tags).onSubmit(commit)
                    }
                    if !model.collections.isEmpty {
                        Section("Collections") {
                            ForEach(model.collections) { c in
                                Toggle(isOn: Binding(get: { memberships.contains(c.id) }, set: { on in
                                    if on { try? model.store.add([clip.id], to: c.id); memberships.insert(c.id) }
                                    else { try? model.store.remove([clip.id], from: c.id); memberships.remove(c.id) }
                                })) { Label(c.name, systemImage: c.symbol) }
                            }
                        }
                    }
                    Section {
                        Toggle("Favorite", isOn: Binding(get: { clip.isFavorite }, set: { try? model.store.setFavorite([clip.id], $0); reload() }))
                        Toggle("Snippet (never removed)", isOn: Binding(get: { clip.isSnippet }, set: { v in try? model.store.update(clip.id) { $0.isSnippet = v }; reload() }))
                    }
                    Section("Details") {
                        LabeledContent("Type", value: ClipFormatting.typeLabel(for: clip))
                        if let app = clip.sourceAppName { LabeledContent("Copied in", value: app) }
                        LabeledContent("Saved", value: clip.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if clip.useCount > 0 { LabeledContent("Reused", value: "\(clip.useCount)×") }
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: clip.byteSize, countStyle: .file))
                        if let device = clip.deviceName { LabeledContent("Device", value: device) }
                        LabeledContent("Stored", value: "On this device")
                    }
                    Section {
                        Button(role: .destructive) { model.delete([clip.id]); dismiss() } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .navigationTitle(ClipFormatting.typeLabel(for: clip))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if clip.isTextEditable && (clip.kind == .text || clip.kind == .code) {
                        ToolbarItem(placement: .primaryAction) {
                            Button(isEditing ? "Save" : "Edit") {
                                if isEditing, text != clip.text {
                                    let newText = text
                                    try? model.store.update(clip.id) { $0.text = newText }
                                    reload()
                                }
                                isEditing.toggle()
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Clip Deleted", systemImage: "trash")
            }
        }
        .onAppear(perform: reload)
        .onDisappear(perform: commit)
    }

    private func reload() {
        clip = model.store.clip(clipID)
        text = clip?.text ?? ""
        note = clip?.note ?? ""
        tags = clip?.tags.joined(separator: ", ") ?? ""
        memberships = model.store.collectionIDs(for: clipID)
    }

    private func commit() {
        guard let clip else { return }
        let newTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let newNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newTags != clip.tags || (newNote.isEmpty ? nil : newNote) != clip.note else { return }
        try? model.store.update(clip.id) { $0.tags = newTags; $0.note = newNote.isEmpty ? nil : newNote }
    }

    private func share(_ clip: Clip) {
        let controller = UIActivityViewController(activityItems: model.shareItems(for: clip), applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(controller, animated: true)
    }
}

/// Compose on iPhone/iPad: a focused full-screen workflow.
struct MobileComposeView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ComposeItem] = []
    @State private var options = ComposeOptions()
    @State private var showingOutput = false

    private var output: String { Composer.render(items, options: options) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $options.title)
                    Picker("Format", selection: $options.format) {
                        ForEach(ComposeFormat.allCases) { Text($0.title).tag($0) }
                    }
                    if options.format == .plainText || options.format == .markdown {
                        Picker("Separator", selection: $options.separator) {
                            ForEach(ComposeSeparator.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Toggle("Source links", isOn: $options.includeSourceLinks)
                    Toggle("Capture dates", isOn: $options.includeDates)
                    Toggle("Remove duplicates", isOn: $options.removeDuplicates)
                }
                Section {
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                Button { item.isIncluded.toggle() } label: {
                                    Image(systemName: item.isIncluded ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.isIncluded ? Palette.jade : Palette.inkTertiary)
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.isIncluded ? "Included" : "Excluded")
                                Text(item.snapshot).font(.subheadline).lineLimit(3)
                                    .foregroundStyle(item.isIncluded ? Palette.ink : Palette.inkTertiary)
                            }
                            TextField("Heading (optional)", text: $item.heading).font(.footnote)
                            TextField("Note (optional)", text: $item.note).font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { items.remove(atOffsets: $0) }
                } header: {
                    Text("Sources — drag to reorder")
                }
                Section("Output") {
                    Text(output).font(.system(.footnote, design: options.format == .plainText ? .default : .monospaced)).textSelection(.enabled)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    ShareLink(item: output) { Image(systemName: "square.and.arrow.up") }
                    Button("Copy") { model.copy(text: output) }.bold()
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Save Composition") {
                        try? model.store.save(Composition(items: items, options: options))
                        model.show(MobileToast(title: "Composition saved"))
                    }
                    .disabled(items.isEmpty)
                }
            }
        }
        .onAppear {
            items = model.store.clips(model.composeIDs).map { ComposeItem(clip: $0) }
        }
    }
}
