import AppKit
import ApplicationServices
import Carbon.HIToolbox
import RekeepKit

/// Puts clips back on the pasteboard and, when permitted, pastes into the frontmost app.
@MainActor
final class PasteboardWriter {
    enum WriteError: LocalizedError {
        case fileMissing(String)
        case empty
        var errorDescription: String? {
            switch self {
            case .fileMissing(let name): "“\(name)” is no longer at its original location."
            case .empty: "This clip has nothing to copy."
            }
        }
    }

    private let pasteboard: NSPasteboard
    weak var monitor: PasteboardMonitor?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    /// Writes one clip. `plainText` strips formatting and writes text only.
    func write(_ clip: Clip, representations: [Representation], plainText: Bool) throws {
        if clip.kind == .file {
            let written: Bool? = FileAccess.withAccess(to: clip.files) { urls in
                pasteboard.clearContents()
                return pasteboard.writeObjects(urls.map { $0 as NSURL })
            }
            guard written == true else {
                let missing = clip.files.first { FileAccess.resolve($0) == nil } ?? clip.files.first
                throw WriteError.fileMissing(missing?.name ?? clip.title)
            }
            markOrigin()
            return
        }
        let item = NSPasteboardItem()
        if plainText || representations.isEmpty {
            let text = clip.plainText
            guard !text.isEmpty else { throw WriteError.empty }
            item.setString(text, forType: .string)
        } else {
            for rep in representations {
                item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
            }
            // Links: also offer a proper URL flavour so browsers and Finder treat it as a link.
            if clip.kind == .link, let url = clip.url, !representations.contains(where: { $0.type == PasteboardType.url }) {
                item.setString(url.absoluteString, forType: .URL)
            }
        }
        item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarkers.rekeepOrigin))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        monitor?.noteOwnWrite(changeCount: pasteboard.changeCount)
    }

    /// Writes arbitrary text (multi-copy, compose output, filled templates).
    func write(text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarkers.rekeepOrigin))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        monitor?.noteOwnWrite(changeCount: pasteboard.changeCount)
    }

    private func markOrigin() {
        pasteboard.addTypes([NSPasteboard.PasteboardType(PasteboardMarkers.rekeepOrigin)], owner: nil)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarkers.rekeepOrigin))
        monitor?.noteOwnWrite(changeCount: pasteboard.changeCount)
    }

    // MARK: - Direct paste

    /// Whether Rekeep may send the paste keystroke. Never prompts.
    static var canPasteDirectly: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt. Only called when the user chooses direct paste.
    static func requestAccessibility() {
        // The documented value of kAXTrustedCheckOptionPrompt (the global itself isn't concurrency-safe to read).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sends ⌘V to the frontmost app. Returns false when not permitted.
    /// Rekeep cannot verify that the target app accepted the paste, so callers never claim it did.
    @discardableResult
    static func sendPasteKeystroke() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(keyCodeForCharacter("v") ?? UInt16(kVK_ANSI_V))
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }

    /// Finds the physical key that types `character` in the current layout (Dvorak, AZERTY…).
    static func keyCodeForCharacter(_ character: Character) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> UInt16? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in UInt16(0)..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1) == String(character) { return code }
            }
            return nil
        }
    }
}
