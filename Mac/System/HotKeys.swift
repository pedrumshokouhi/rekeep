import AppKit
import Carbon.HIToolbox

/// A key + modifier combination, stored independently of any keyboard layout.
struct KeyShortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt // NSEvent.ModifierFlags raw value (device-independent subset)

    static let defaultShelf = KeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    static let defaultQueue = KeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// e.g. "⇧⌘V"
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Symbols shown as separate keycaps.
    var keycaps: [String] {
        var caps: [String] = []
        if flags.contains(.control) { caps.append("⌃") }
        if flags.contains(.option) { caps.append("⌥") }
        if flags.contains(.shift) { caps.append("⇧") }
        if flags.contains(.command) { caps.append("⌘") }
        caps.append(Self.keyName(keyCode))
        return caps
    }

    /// A shortcut must use at least one of ⌘ ⌥ ⌃ to avoid swallowing ordinary typing.
    var isValidGlobal: Bool { !flags.intersection([.command, .option, .control]).isEmpty }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        let fKeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let f = fKeys[Int(code)] { return f }
        // Resolve through the current keyboard layout so AZERTY etc. display correctly.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers system-wide hot keys via Carbon. Works inside the App Sandbox and needs no permissions.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var names: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Registers (or replaces) a named hot key. Returns false if the combination is taken.
    @discardableResult
    func register(_ name: String, _ shortcut: KeyShortcut?, action: @escaping () -> Void) -> Bool {
        unregister(name)
        guard let shortcut, shortcut.isValidGlobal else { return shortcut == nil }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x524B_5045), id: id) // 'RKPE'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = action
        names[name] = id
        return true
    }

    func unregister(_ name: String) {
        guard let id = names.removeValue(forKey: name) else { return }
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    func unregisterAll(prefix: String) {
        for name in names.keys where name.hasPrefix(prefix) { unregister(name) }
    }
}
