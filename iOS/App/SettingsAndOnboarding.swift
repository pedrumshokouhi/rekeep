import UniformTypeIdentifiers
import RekeepKit
import SwiftUI

struct MobileSettingsView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Offer to save new clipboard content", isOn: $model.showsClipboardBanner)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("iOS doesn’t let apps watch the clipboard in the background. Rekeep notices when something new is on the clipboard while it’s open and offers a Paste button — iOS never shows a permission prompt for it. You can also share anything to Rekeep from other apps.")
                }
                Section {
                    Picker("Passwords, keys, card numbers", selection: $model.privacy.sensitiveHandling) {
                        ForEach(SensitiveContentHandling.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Rekeep recognises common credential formats, but detection is never perfect.")
                }
                Section("History") {
                    Picker("Keep history for", selection: $model.retention) {
                        ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Clips", value: model.statistics.clipCount.formatted())
                    LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: model.statistics.totalBytes, countStyle: .file))
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                }
                Section {
                    LabeledContent("Stored", value: "On this device")
                } footer: {
                    Text("Your library lives in Rekeep’s private storage on this device, protected by iOS data protection. No account, no analytics, no servers.")
                }
                Section {
                    if PurchaseManager.shared.isPro {
                        Label("Rekeep Pro unlocked", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.jadeInk)
                    } else {
                        Button("Rekeep Pro…") { dismiss(); PurchaseManager.shared.paywallReason = .history }
                    }
                    Button("Restore Purchase") { Task { await PurchaseManager.shared.restore() } }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { try? model.store.clearHistory(keepOrganized: true) }
                Button("Erase Everything", role: .destructive) { try? model.store.clearHistory(keepOrganized: false) }
            } message: {
                Text("Clear History keeps favorites, snippets, and collections. Both permanently delete clips.")
            }
        }
    }
}

struct MobileOnboarding: View {
    @Environment(MobileModel.self) private var model
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                pageView(
                    icon: AnyView(BrandMarkTwoTone(size: 72)),
                    title: "Copy once.\nKeep moving.",
                    body: "Rekeep keeps the things you copy — text, links, images, files — so you can find and reuse them in seconds."
                ).tag(0)
                pageView(
                    icon: AnyView(Image(systemName: "doc.on.clipboard").font(.system(size: 52, weight: .light)).foregroundStyle(Palette.jadeInk)),
                    title: "How saving works",
                    body: "When something new is on your clipboard, tap Paste in Rekeep to keep it. Or use the Share button in any app and choose Rekeep. iOS doesn’t allow clipboard apps to save in the background."
                ).tag(1)
                pageView(
                    icon: AnyView(Image(systemName: "lock").font(.system(size: 52, weight: .light)).foregroundStyle(Palette.jadeInk)),
                    title: "Private by design",
                    body: "Everything stays on this device. No account, no analytics, no servers. Things that look like passwords or keys aren’t saved."
                ).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 2 { withAnimation { page += 1 } } else { model.hasCompletedOnboarding = true }
            } label: {
                Text(page < 2 ? "Continue" : "Get Started").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.jade)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Palette.card.ignoresSafeArea())
    }

    private func pageView(icon: AnyView, title: String, body: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            icon
            Text(title).font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
            Text(body).font(.body).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}
