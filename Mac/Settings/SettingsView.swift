import AppKit
import Combine
import RekeepKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = Tab.general

    enum Tab: String, CaseIterable, Identifiable {
        case general, privacy, storage, shortcuts, about
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .privacy: "hand.raised"
            case .storage: "internaldrive"
            case .shortcuts: "keyboard"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.system(size: 17, weight: .regular)).frame(height: 22)
                            Text(t.title).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(tab == t ? Palette.jadeInk : Palette.inkSecondary)
                        .frame(width: 76, height: 52)
                        .background(tab == t ? Palette.chipFill : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
            .padding(.top, 34)
            .padding(.bottom, Space.s)
            Divider()
            Group {
                switch tab {
                case .general: GeneralSettings()
                case .privacy: PrivacySettingsPane()
                case .storage: StorageSettings()
                case .shortcuts: ShortcutSettings()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 640, height: 560)
        .ignoresSafeArea(edges: .top)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var axTrusted = PasteboardWriter.canPasteDirectly
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("When you choose a clip", selection: $settings.pasteBehavior) {
                    ForEach(PasteBehavior.allCases) { Text($0.title).tag($0) }
                }
                if settings.pasteBehavior == .pasteDirectly {
                    LabeledContent("Accessibility") {
                        if axTrusted {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.jadeInk)
                        } else {
                            HStack {
                                Text("Needed to paste for you").foregroundStyle(.secondary)
                                Button("Allow…") { PasteboardWriter.requestAccessibility(); PasteboardWriter.openAccessibilitySettings() }
                            }
                        }
                    }
                    Text("Rekeep sends ⌘V to the app you were using. Without this permission it copies, and you press ⌘V yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Paste as plain text by default", isOn: $settings.pastePlainTextByDefault)
                Picker("Join multiple clips with", selection: $settings.multiSeparator) {
                    ForEach(MultiCopySeparator.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Shelf") {
                Picker("Card size", selection: $settings.density) {
                    ForEach(ShelfDensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show clips as a compact list", isOn: $settings.useListLayout)
                Toggle("Show keyboard hints", isOn: $settings.showKeyboardHints)
                Toggle("Show brief confirmations", isOn: $settings.playFeedbackHUD)
            }
            Section {
                LabeledContent("Rekeep Pro") {
                    if PurchaseManager.shared.isPro {
                        Label("Unlocked", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.jadeInk)
                    } else {
                        Button("Learn More…") { PurchaseManager.shared.paywallReason = .history }
                    }
                }
            }
            Section {
                Toggle("Open Rekeep at login", isOn: Binding(get: { settings.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in axTrusted = PasteboardWriter.canPasteDirectly }
    }
}

private struct PrivacySettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var selectedExclusion: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Pause capture", isOn: $settings.privacy.isCapturePaused)
                LabeledContent("macOS paste access") {
                    HStack {
                        Text(accessText).foregroundStyle(app.pasteboardAccess == .denied ? Palette.danger : .secondary)
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Text("For Rekeep to save what you copy, set it to Always Allow in Privacy & Security › Paste from Other Apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Passwords, keys, and card numbers", selection: $settings.privacy.sensitiveHandling) {
                    ForEach(SensitiveContentHandling.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Respect “don’t save” markers from other apps", isOn: $settings.privacy.honorConcealedMarkers)
                Text("Password managers mark copied passwords as confidential; Rekeep skips them. Rekeep also recognises common key and token formats, but no detection is perfect — pause capture before copying anything you never want stored.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Sensitive content") }
            Section {
                List(selection: $selectedExclusion) {
                    ForEach(settings.privacy.excludedBundleIDs.sorted(), id: \.self) { id in
                        HStack(spacing: Space.s) {
                            SourceIcon(bundleID: id, kind: .text, size: 18)
                            Text(appName(id))
                            Spacer()
                            Text(id).font(.caption).foregroundStyle(.tertiary)
                        }
                        .tag(id)
                    }
                }
                .frame(height: 150)
                HStack {
                    Button("Add App…") { addApp() }
                    Button("Remove") {
                        if let s = selectedExclusion { settings.privacy.excludedBundleIDs.remove(s) }
                    }
                    .disabled(selectedExclusion == nil)
                    Spacer()
                    Button("Restore Defaults") { settings.privacy.excludedBundleIDs = PrivacySettings.defaultExclusions }
                }
            } header: {
                Text("Never save from these apps")
            } footer: {
                Text("Content copied while one of these apps is in front is never read, stored, indexed, or synced.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { app.refreshPasteboardAccess() }
    }

    private var accessText: String {
        switch app.pasteboardAccess {
        case .allowed: "Always allowed"
        case .ask: "Asks each time"
        case .denied: "Blocked"
        case .notYetAsked: "Not yet asked"
        }
    }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { app.settings.privacy.excludedBundleIDs.insert(id) }
        }
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Keep history for", selection: $settings.retention) {
                    ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                }
                Picker("Limit library size", selection: $settings.maxLibraryBytes) {
                    Text("No limit").tag(Int64?.none)
                    Text("500 MB").tag(Int64?.some(500 * 1_048_576))
                    Text("1 GB").tag(Int64?.some(1_073_741_824))
                    Text("5 GB").tag(Int64?.some(5 * 1_073_741_824))
                    Text("20 GB").tag(Int64?.some(20 * 1_073_741_824))
                }
                Picker("Skip single items larger than", selection: $settings.privacy.maxItemBytes) {
                    Text("10 MB").tag(Int64(10 * 1_048_576))
                    Text("50 MB").tag(Int64(50 * 1_048_576))
                    Text("200 MB").tag(Int64(200 * 1_048_576))
                }
                Text("Favorites, snippets, and clips in collections are never removed by these limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("This Mac") {
                LabeledContent("Clips", value: app.statistics.clipCount.formatted())
                LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: app.statistics.totalBytes, countStyle: .file))
                if let oldest = app.statistics.oldest {
                    LabeledContent("Oldest clip", value: oldest.formatted(date: .abbreviated, time: .omitted))
                }
                LabeledContent("Location") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.libraryDirectory]) }
                }
                Text("Your library is stored in Rekeep’s private container on this Mac and protected by your macOS account and FileVault. It is not encrypted separately by Rekeep, and it is not synced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup") {
                HStack {
                    Button("Export Library…") { export() }
                    Button("Import…") { importArchive() }
                }
                Text("Exports are a plain folder of your clips and a manifest. Clips kept on this Mac only are not exported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Clear History…") { clear(keepOrganized: true) }
                    Button("Erase Everything…", role: .destructive) { clear(keepOrganized: false) }
                }
            } footer: {
                Text("Clear History keeps favorites, snippets, and collections. Erase Everything permanently deletes all clips.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func clear(keepOrganized: Bool) {
        let alert = NSAlert()
        alert.messageText = keepOrganized ? "Clear history?" : "Erase every clip?"
        alert.informativeText = keepOrganized
            ? "This permanently deletes clips that aren’t favorites, snippets, or in a collection. This can’t be undone."
            : "This permanently deletes every clip, including favorites, snippets, and collection contents. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: keepOrganized ? "Clear History" : "Erase Everything")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try app.store.clearHistory(keepOrganized: keepOrganized)
            app.show(Toast(style: .success, title: keepOrganized ? "History cleared" : "Library erased"))
        } catch {
            app.show(Toast(style: .failure, title: "Couldn’t clear", detail: error.localizedDescription))
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Rekeep Export \(Date.now.formatted(.iso8601.year().month().day()))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = app.store
        Task {
            do {
                let summary = try await Task.detached { try LibraryArchive.export(store, to: url) }.value
                app.show(Toast(style: .success, title: "Exported \(summary.clips.formatted()) clips", detail: url.lastPathComponent))
            } catch {
                app.show(Toast(style: .failure, title: "Export failed", detail: error.localizedDescription))
            }
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a Rekeep export folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = app.store
        Task {
            do {
                let summary = try await Task.detached { try LibraryArchive.import(from: url, into: store) }.value
                app.show(Toast(style: .success, title: "Imported \(summary.clips.formatted()) clips", detail: summary.skippedDuplicates > 0 ? "\(summary.skippedDuplicates) were already in your library." : nil))
            } catch {
                app.show(Toast(style: .failure, title: "Import failed", detail: "That folder isn’t a readable Rekeep export."))
            }
        }
    }
}

private struct ShortcutSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                LabeledContent("Open the shelf") {
                    ShortcutRecorder(shortcut: Binding(get: { settings.shortcut }, set: { if let s = $0 { settings.shortcut = s } }), allowsClear: false)
                }
                LabeledContent("Paste next from Queue") {
                    ShortcutRecorder(shortcut: $settings.queueShortcut, allowsClear: true)
                }
            }
            if !app.collections.isEmpty {
                Section("Open a collection directly") {
                    ForEach(app.collections) { c in
                        LabeledContent {
                            ShortcutRecorder(shortcut: Binding(get: { settings.collectionShortcuts[c.id.uuidString] }, set: { settings.collectionShortcuts[c.id.uuidString] = $0 }), allowsClear: true)
                        } label: {
                            Label(c.name, systemImage: c.symbol)
                        }
                    }
                }
            }
            Section("In the shelf") {
                Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: 7) {
                    row(["←", "→"], "Move between clips (⇧ to select several)")
                    row(["↩"], "Paste the selected clip")
                    row(["⇧", "↩"], "Paste as plain text")
                    row(["⌥", "↩"], "Copy without pasting")
                    row(["Space"], "Preview")
                    row(["⌘", "1–9"], "Paste one of the first nine visible clips")
                    row(["⇥"], "Next collection")
                    row(["⌘", "D"], "Favorite")
                    row(["⌘", "K"], "Add to Paste Queue")
                    row(["⌘", "M"], "Compose selected clips")
                    row(["⌘", "⌫"], "Delete (undo available)")
                    row(["⌘", "L"], "Open the Library")
                    row(["esc"], "Clear search, or close")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ keys: [String], _ label: String) -> some View {
        GridRow {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(text: $0) } }
            Text(label).font(.callout)
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: Space.m) {
            Spacer()
            AppIconView(size: 96)
            Text("Rekeep").font(.system(size: 26, weight: .semibold))
            Text(Brand.tagline).foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                .font(.caption).foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("Everything you copy stays on this Mac.")
                Text("No account. No analytics. No servers.")
            }
            .font(.callout).foregroundStyle(.secondary).padding(.top, Space.s)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The app icon artwork drawn live (matches the asset catalog renders).
struct AppIconView: View {
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: scheme == .dark ? [Color(nsColor: NSColor(hex: 0x2A2E36)), Color(nsColor: Palette.charcoal)] : [Color(nsColor: NSColor(hex: 0xFBFBF9)), Color(nsColor: NSColor(hex: 0xE9EAE6))], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: max(0.5, size / 256))
            ZStack {
                BrandMarkFold().fill(scheme == .dark ? Color(nsColor: Palette.porcelain) : Color(nsColor: Palette.graphite), style: FillStyle(eoFill: true))
                BrandMarkTab().fill(Color(nsColor: Palette.jadeBrand))
            }
            .frame(width: size * 0.62, height: size * 0.62)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: size * 0.04, y: size * 0.02)
    }
}

/// Click, then press a key combination. Esc cancels; ⌫ clears (when allowed).
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    var allowsClear: Bool
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack(spacing: Space.xs) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 3) {
                    if recording {
                        Text(message ?? "Type shortcut…").font(.callout).foregroundStyle(message == nil ? Palette.jadeInk : Palette.danger)
                    } else if let shortcut {
                        ForEach(shortcut.keycaps, id: \.self) { Keycap(text: $0) }
                    } else {
                        Text("Record Shortcut").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 120, minHeight: 24)
                .padding(.horizontal, Space.s)
                .background(recording ? Palette.jade.opacity(0.12) : Palette.chipFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(recording ? Palette.jade : Palette.hairline, lineWidth: recording ? 1.5 : 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shortcut.map { "Shortcut \($0.display). Click to change." } ?? "Record shortcut")
            if allowsClear, shortcut != nil, !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // esc
            let candidate = KeyShortcut(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
            guard candidate.isValidGlobal else {
                message = "Include ⌘, ⌥, or ⌃"
                return nil
            }
            shortcut = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
