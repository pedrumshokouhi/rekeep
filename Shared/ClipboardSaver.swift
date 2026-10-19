#if os(iOS)
import RekeepKit
import UIKit

/// Saves what’s on the iPhone clipboard into the shared library, at most once per clipboard change.
///
/// iOS lets an app read the clipboard only while it’s in use, so this runs from the Rekeep
/// keyboard (whenever it’s showing) and from the app itself. The change count is shared through
/// the App Group, so whichever runs first saves the item and the other skips it.
nonisolated enum ClipboardSaver {
    static let lastChangeKey = "rekeep.lastChangeCount"
    static let keyboardAutoSaveKey = "rekeep.keyboardAutoSave"
    /// Large clipboard images are skipped in the keyboard, which has a tight memory budget.
    static let maxImageBytes = 12 * 1024 * 1024

    static var keyboardAutoSave: Bool {
        get { SharedStorage.defaults.object(forKey: keyboardAutoSaveKey) as? Bool ?? true }
        set { SharedStorage.defaults.set(newValue, forKey: keyboardAutoSaveKey) }
    }

    /// True when the clipboard changed since Rekeep last saved, read, or wrote it. Never prompts.
    static var hasNewItem: Bool {
        let pb = UIPasteboard.general
        return pb.changeCount != SharedStorage.defaults.integer(forKey: lastChangeKey) && (pb.hasStrings || pb.hasURLs || pb.hasImages)
    }

    /// Marks the current clipboard as handled (for Rekeep’s own writes and dismissed banners).
    static func markSeen() {
        SharedStorage.defaults.set(UIPasteboard.general.changeCount, forKey: lastChangeKey)
    }

    /// Reads the clipboard and saves it, unless it was already handled. Returns nil when there
    /// was nothing new to look at.
    @MainActor
    static func saveIfNew(into store: ClipStore, sourceAppName: String?) -> IngestResult? {
        guard hasNewItem else { return nil }
        let pb = UIPasteboard.general
        // Mark first: an item we decline (a password, say) shouldn’t be re-examined every second.
        markSeen()
        let privacy = SharedStorage.privacy
        if let reason = PrivacyPolicy(settings: privacy).preflight(sourceBundleID: nil, pasteboardTypes: Set(pb.types)) {
            return .ignored(reason)
        }
        let content: CapturedContent
        if pb.hasImages, let (type, data) = imageData(pb) {
            content = CapturedContent(representations: [Representation(type: type, data: data)], plainText: nil, sourceAppName: sourceAppName)
        } else if pb.hasURLs, let url = pb.url, !url.isFileURL {
            let text = url.absoluteString
            content = CapturedContent(representations: [Representation(type: PasteboardType.plainText, data: Data(text.utf8))], plainText: text, sourceAppName: sourceAppName)
        } else if pb.hasStrings, let text = pb.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = CapturedContent(representations: [Representation(type: PasteboardType.plainText, data: Data(text.utf8))], plainText: text, sourceAppName: sourceAppName)
        } else {
            return .ignored(.empty)
        }
        return CapturePipeline.ingest(content, into: store, privacy: privacy)
    }

    /// The encoded image as it sits on the clipboard; decoding a UIImage could exceed the keyboard’s memory limit.
    private static func imageData(_ pb: UIPasteboard) -> (String, Data)? {
        for type in [PasteboardType.png, PasteboardType.jpeg, PasteboardType.heic] where pb.types.contains(type) {
            if let data = pb.data(forPasteboardType: type), data.count <= maxImageBytes { return (type, data) }
        }
        return nil
    }
}
#endif
