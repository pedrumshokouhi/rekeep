import PhotosUI
import RekeepKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RekeepMobileApp: App {
    @State private var model = MobileModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Palette.jade)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.becameActive() }
                }
        }
    }
}

struct RootView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass == .regular { PadRootView() } else { PhoneRootView() }
        }
        .overlay(alignment: .bottom) { MobileToastView() }
        .overlay {
            // Hide clip contents in the app switcher.
            if scenePhase != .active { PrivacyCover() }
        }
        .sheet(item: $model.templateClip) { clip in TemplateSheet(clip: clip) }
        .fullScreenCover(isPresented: $model.isComposing) { MobileComposeView() }
        #if DEBUG
        .overlay(alignment: .bottom) {
            // QA: render the keyboard extension's UI inside the app for screenshots.
            if ProcessInfo.processInfo.arguments.contains("-qa.keyboard") { QAKeyboardPreview() }
        }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-qa.compose") {
                model.composeIDs = (try? model.store.fetch(ClipQuery(kinds: [.text, .link], limit: 3)).map(\.id)) ?? []
                model.isComposing = !model.composeIDs.isEmpty
            }
        }
        #endif
        .fullScreenCover(isPresented: Binding(get: { !model.hasCompletedOnboarding }, set: { if !$0 { model.hasCompletedOnboarding = true } })) {
            MobileOnboarding()
        }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Palette.shelfSolid.ignoresSafeArea()
            BrandMarkTwoTone(size: 64)
        }
    }
}

// MARK: - Shared pieces

/// Horizontal scope chips: History, Favorites, Snippets, then collections.
struct ScopeBar: View {
    @Environment(MobileModel.self) private var model
    @Binding var scope: MobileScope

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("History", "clock", nil, .history)
                chip("Favorites", "star", nil, .favorites)
                chip("Snippets", "text.quote", nil, .snippets)
                ForEach(model.collections) { c in chip(c.name, c.symbol, c.accent, .collection(c.id)) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ title: String, _ symbol: String, _ accent: CollectionAccent?, _ value: MobileScope) -> some View {
        let on = scope == value
        return Button {
            withAnimation(Motion.micro) { scope = value }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(accent?.color ?? (on ? Palette.ink : Palette.inkSecondary))
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(on ? Palette.ink : Palette.inkSecondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(on ? Palette.chipFillSelected : Palette.chipFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Banner offered when the clipboard changed. Uses the system Paste button, so iOS never shows a prompt.
struct ClipboardBanner: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        if model.clipboardHasNewContent {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(Palette.inkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New on your clipboard").font(.subheadline.weight(.semibold))
                    Text("Save it to Rekeep?").font(.caption).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                PasteButton(supportedContentTypes: [.plainText, .url, .image, .png, .jpeg]) { providers in
                    Task { @MainActor in model.importProviders(providers, fromClipboard: true) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleOnly)
                .tint(Palette.jade)
                Button { model.dismissClipboardBanner() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Palette.inkTertiary)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct MobileToastView: View {
    @Environment(MobileModel.self) private var model
    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.symbol).foregroundStyle(Palette.jadeInk)
                Text(toast.title).font(.subheadline.weight(.semibold))
                if let title = toast.actionTitle, let action = toast.action {
                    Button(title) { action(); model.toast = nil }.font(.subheadline.weight(.semibold)).tint(Palette.jadeInk)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.bottom, 90)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The "+" menu: snippet, photo, file. Paste lives in its own system button.
struct AddMenu: View {
    @Environment(MobileModel.self) private var model
    @State private var editingSnippet = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingFiles = false

    var body: some View {
        Menu {
            Button { editingSnippet = true } label: { Label("New Snippet", systemImage: "square.and.pencil") }
            Button { showingPhotos = true } label: { Label("Import Photo", systemImage: "photo") }
            Button { showingFiles = true } label: { Label("Import File", systemImage: "folder") }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add")
        .sheet(isPresented: $editingSnippet) { SnippetEditorSheet() }
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { model.importImageData(data) }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
    }
}

struct SnippetEditorSheet: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title (optional)", text: $title)
                Section {
                    TextEditor(text: $text).frame(minHeight: 200)
                } footer: {
                    Text("Add {{first_name}}, {{company}}, {{date}}, or any {{custom_name}} to make a template. You’ll fill them in each time you copy.")
                }
            }
            .navigationTitle("New Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.newSnippet(text: text, title: title.isEmpty ? nil : title); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct TemplateSheet: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let clip: Clip
    @State private var values: [String: String] = [:]

    private var placeholders: [TemplateEngine.Placeholder] { TemplateEngine.placeholders(in: clip.text ?? "") }
    private var rendered: String { TemplateEngine.render(clip.text ?? "", values: values) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(placeholders) { p in
                        TextField(p.displayName, text: Binding(get: { values[p.name.lowercased()] ?? "" }, set: { values[p.name.lowercased()] = $0 }))
                    }
                }
                Section("Preview") {
                    Text(rendered).font(.callout).textSelection(.enabled)
                }
            }
            .navigationTitle(clip.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        model.copy(text: rendered)
                        model.store.markUsed(clip.id)
                        dismiss()
                    }
                }
            }
            .onAppear {
                for p in placeholders where p.isBuiltIn { values[p.name.lowercased()] = TemplateEngine.defaultValue(for: p) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#if DEBUG
/// The keyboard extension's view, hosted in the app for visual QA.
private struct QAKeyboardPreview: View {
    @State private var state = KeyboardState()
    var body: some View {
        VStack(spacing: 0) {
            Text("Hello Ana, here’s the link: ").font(.body).padding().frame(maxWidth: .infinity, alignment: .leading).background(Palette.card)
            KeyboardView(state: state)
                .frame(height: 268)
                .background(Color(uiColor: .systemGray5))
        }
        .onAppear { state.hasFullAccess = true; state.needsGlobe = true; state.load() }
    }
}
#endif
