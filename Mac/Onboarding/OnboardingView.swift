import AppKit
import Combine
import RekeepKit
import SwiftUI

/// Five short steps. Real clip, honest permissions, then out of the way.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    var finish: () -> Void
    @State private var step = 0
    @State private var demoCopied = false
    @State private var demoSaved = false
    @State private var axTrusted = PasteboardWriter.canPasteDirectly
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let demoText = "Rekeep keeps what you copy, so you can paste it again later."

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: privacy
                case 2: shortcut
                case 3: pasting
                default: done
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 64)
            .padding(.top, 40)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<5) { i in
                        Capsule().fill(i == step ? Palette.ink : Palette.inkTertiary.opacity(0.4))
                            .frame(width: i == step ? 16 : 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(step + 1) of 5")
                Spacer()
                if step > 0 && step < 4 {
                    Button("Back") { withAnimation(Motion.view) { step -= 1 } }
                        .buttonStyle(.borderless)
                }
                Button(step == 4 ? "Start Using Rekeep" : "Continue") {
                    if step == 4 { finish() } else { withAnimation(Motion.view) { step += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.jade)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.xxxl)
            .padding(.vertical, Space.xl)
        }
        .frame(width: 720, height: 560)
        .background(Palette.card)
        .onReceive(poll) { _ in
            axTrusted = PasteboardWriter.canPasteDirectly
            app.refreshPasteboardAccess()
            if demoCopied, !demoSaved {
                demoSaved = (try? app.store.fetch(ClipQuery(text: "keeps what you copy", limit: 1)).isEmpty == false) ?? false
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: Space.l) {
            AppIconView(size: 104)
            Text("Copy once. Keep moving.").font(.system(size: 30, weight: .semibold))
            Text("Rekeep remembers everything you copy — text, links, images, files — and brings it back with one shortcut.")
                .font(.title3).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: 500)
            VStack(spacing: Space.s) {
                Text(demoText)
                    .font(.system(size: 14))
                    .padding(Space.m)
                    .frame(maxWidth: 460)
                    .contentSurface(radius: 12)
                    .textSelection(.enabled)
                HStack(spacing: Space.s) {
                    Button(demoCopied ? "Copied" : "Try it: copy this line") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(demoText, forType: .string)
                        demoCopied = true
                    }
                    .disabled(demoCopied)
                    if demoSaved {
                        Label("Saved to your history", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.jadeInk)
                    } else if demoCopied {
                        Text("If macOS asks, choose Allow.").foregroundStyle(Palette.inkSecondary)
                    }
                }
                .font(.callout)
            }
            .padding(.top, Space.s)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            stepHeader("lock", "Private by design")
            bullet("internaldrive", "Saved on this Mac", "Your history lives in Rekeep’s private storage. No account, no servers, no analytics.")
            bullet("hand.raised", "Skips what it should", "Passwords from password managers, apps you exclude, and things that look like keys or card numbers aren’t saved.")
            bullet("pause.circle", "You’re in control", "Pause capture from the menu bar at any time. Delete a clip, or everything, whenever you like.")
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Image(systemName: accessSymbol).foregroundStyle(accessColor)
                    Text("macOS paste access: \(accessText)").font(.callout.weight(.semibold))
                }
                Text("macOS asks before any app reads what you copy. For Rekeep to work in the background, choose Always Allow in Privacy & Security › Paste from Other Apps.")
                    .font(.callout).foregroundStyle(Palette.inkSecondary)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") { NSWorkspace.shared.open(url) }
                }
            }
            .padding(Space.l)
            .background(Palette.cardSunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var shortcut: some View {
        @Bindable var settings = app.settings
        return VStack(spacing: Space.l) {
            stepHeader("keyboard", "One shortcut away")
            Text("Press it from any app. The shelf rises, you pick a clip, and it’s pasted where you were.")
                .font(.title3).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: Space.s) {
                ForEach(app.settings.shortcut.keycaps, id: \.self) { cap in
                    Text(cap).font(.system(size: 28, weight: .medium, design: .rounded))
                        .frame(minWidth: 64, minHeight: 64)
                        .padding(.horizontal, cap.count > 1 ? Space.m : 0)
                        .background(Palette.cardSunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
                }
            }
            .padding(.vertical, Space.s)
            HStack {
                Text("Change it:").foregroundStyle(Palette.inkSecondary)
                ShortcutRecorder(shortcut: Binding(get: { settings.shortcut }, set: { if let s = $0 { settings.shortcut = s } }), allowsClear: false)
            }
            Button("Try It Now") { app.presentShelf() }
        }
    }

    private var pasting: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            stepHeader("arrow.down.doc", "Paste for you (optional)")
            Text("Rekeep can paste the clip you choose straight into the app you were using. To do that, macOS requires Accessibility permission — Rekeep uses it only to send ⌘V.")
                .font(.title3).foregroundStyle(Palette.inkSecondary)
            HStack(spacing: Space.m) {
                if axTrusted {
                    Label("Allowed — Rekeep will paste for you.", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.jadeInk)
                } else {
                    Button("Allow Accessibility…") { PasteboardWriter.requestAccessibility(); PasteboardWriter.openAccessibilitySettings() }
                    Text("Without it, Rekeep copies and you press ⌘V.").foregroundStyle(Palette.inkSecondary)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var done: some View {
        VStack(spacing: Space.l) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.cardSunken)
                    .frame(width: 420, height: 40)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 14) {
                            Image(systemName: "wifi").foregroundStyle(Palette.inkTertiary)
                            BrandMark(size: 18).foregroundStyle(Palette.ink)
                                .padding(5)
                                .background(Palette.jade.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Image(systemName: "battery.75percent").foregroundStyle(Palette.inkTertiary)
                            Text("9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.inkSecondary)
                        }
                        .padding(.trailing, Space.l)
                    }
            }
            Text("Rekeep lives in your menu bar").font(.system(size: 26, weight: .semibold))
            Text("Pause capture, open the Library, or change settings from there. Close this window — Rekeep keeps working quietly.")
                .font(.title3).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            Toggle("Open Rekeep at login", isOn: Binding(get: { app.settings.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .padding(.top, Space.s)
        }
    }

    // MARK: Pieces

    private func stepHeader(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(Palette.jadeInk)
            Text(title).font(.system(size: 28, weight: .semibold))
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.inkSecondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private var accessText: String {
        switch app.pasteboardAccess {
        case .allowed: "Always Allow"
        case .ask: "Ask each time"
        case .denied: "Blocked"
        case .notYetAsked: "Not set yet"
        }
    }
    private var accessSymbol: String { app.pasteboardAccess == .allowed ? "checkmark.circle.fill" : (app.pasteboardAccess == .denied ? "xmark.octagon" : "questionmark.circle") }
    private var accessColor: Color { app.pasteboardAccess == .allowed ? Palette.jadeInk : (app.pasteboardAccess == .denied ? Palette.danger : Palette.inkSecondary) }
}
