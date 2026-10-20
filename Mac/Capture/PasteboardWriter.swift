import AppKit
import RekeepKit

/// Puts clips back on the pasteboard. Rekeep never types into other apps: you press ⌘V.
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
}
