import UniformTypeIdentifiers
import RekeepKit
import SwiftUI

struct MobileSettingsView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @State private var keyboardAutoSave = ClipboardSaver.keyboardAutoSave

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Save what you copy", isOn: $keyboardAutoSave)
                        .onChange(of: keyboardAutoSave) { _, on in ClipboardSaver.keyboardAutoSave = on }
                    NavigationLink("Set Up the Rekeep Keyboard") { KeyboardSetupView() }
                } header: {
                    Text("Rekeep Keyboard")
                } footer: {
                    Text("Whenever you switch to the Rekeep keyboard, whatever you last copied is saved and shown first — no need to open the app. iOS doesn’t let any app save the clipboard in the background, so this is the moment Rekeep can.")
                }
                Section {
                    Toggle("Offer to save new clipboard content", isOn: $model.showsClipboardBanner)
                    NavigationLink("Save with Back Tap") { BackTapSetupView() }
                } header: {
                    Text("In the App")
                } footer: {
                    Text("When something new is on the clipboard while Rekeep is open, it offers a Paste button. Back Tap saves your clipboard from anywhere with two taps on the back of your iPhone.")
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
                    body: "Add the Rekeep keyboard and anything you copy is saved the moment you switch to it — then tap it to type it anywhere. You can also tap Paste in Rekeep, or share to Rekeep from any app."
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

/// Step-by-step setup for the Rekeep keyboard, with a button straight to Settings.
struct KeyboardSetupView: View {
    var body: some View {
        SetupSteps(
            intro: "The Rekeep keyboard shows your clips wherever you type, and saves what you copy the moment you switch to it.",
            steps: [
                "Tap Open Settings below, then Keyboards.",
                "Turn on Rekeep, then turn on Allow Full Access. Rekeep needs it only to read and save clips on this device — it never records what you type and never uses the internet.",
                "In any app, touch and hold the globe key and choose Rekeep.",
                "If iOS asks to allow pasting, choose Allow. To stop being asked, go to Settings › Apps › Rekeep › Paste from Other Apps › Allow.",
            ],
            action: ("Open Settings", { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } })
        )
        .navigationTitle("Rekeep Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Back Tap runs a shortcut that hands the clipboard to Rekeep’s “Save Text” action, from anywhere.
struct BackTapSetupView: View {
    var body: some View {
        SetupSteps(
            intro: "Save whatever you just copied by double-tapping the back of your iPhone. It runs quietly, without opening Rekeep.",
            steps: [
                "Open the Shortcuts app and create a new shortcut.",
                "Add Get Clipboard, then add Rekeep’s Save Text to Rekeep. Name it Save to Rekeep.",
                "Open Settings › Accessibility › Touch › Back Tap › Double Tap, and choose Save to Rekeep.",
                "On iPhone 15 Pro and later you can also put it on the Action button.",
            ],
            action: ("Open Shortcuts", { if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) } })
        )
        .navigationTitle("Save with Back Tap")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SetupSteps: View {
    let intro: String
    let steps: [String]
    let action: (String, () -> Void)

    var body: some View {
        List {
            Section { Text(intro).foregroundStyle(Palette.inkSecondary) }
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Palette.jadeInk)
                            .frame(width: 18)
                        Text(step)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Button(action.0, action: action.1).foregroundStyle(Palette.jadeInk)
            }
        }
    }
}
