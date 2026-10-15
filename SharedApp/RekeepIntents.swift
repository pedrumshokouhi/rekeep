import AppIntents
import Foundation
import RekeepKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The store the running app already has open, so Shortcuts changes show up immediately.
@MainActor
enum IntentEnvironment {
    static var store: ClipStore?
    static var openShelf: (() -> Void)?

    static func resolvedStore() throws -> ClipStore {
        if let store { return store }
        let opened = try SharedStorage.openStore(deviceName: nil)
        store = opened
        return opened
    }

    static func copyToClipboard(_ text: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarkers.rekeepOrigin))
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Entity

struct ClipEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Clip"
    static let defaultQuery = ClipEntityQuery()

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Text") var text: String
    @Property(title: "Kind") var kind: String
    @Property(title: "Copied") var date: Date

    init(_ clip: Clip) {
        id = clip.id
        title = clip.title
        text = clip.plainText
        kind = ClipFormatting.typeLabel(for: clip)
        date = clip.capturedAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind)")
    }
}

struct ClipEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ClipEntity] {
        try IntentEnvironment.resolvedStore().clips(identifiers).map(ClipEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ClipEntity] {
        try IntentEnvironment.resolvedStore().fetch(ClipQuery(text: string, limit: 25)).map(ClipEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ClipEntity] {
        try IntentEnvironment.resolvedStore().fetch(ClipQuery(limit: 15)).map(ClipEntity.init)
    }
}

enum ClipKindChoice: String, AppEnum {
    case any, text, link, image, code, color, file
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Clip Type"
    static let caseDisplayRepresentations: [ClipKindChoice: DisplayRepresentation] = [
        .any: "Any", .text: "Text", .link: "Link", .image: "Image", .code: "Code", .color: "Color", .file: "File",
    ]
    var kind: ClipKind? { self == .any ? nil : ClipKind(rawValue: rawValue) }
}

// MARK: - Intents

struct SaveTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Text to Rekeep"
    static let description = IntentDescription("Saves text to your Rekeep history, optionally as a snippet that’s never removed.")

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Save as Snippet", default: false) var asSnippet: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try IntentEnvironment.resolvedStore()
        let content = CapturedContent(representations: [Representation(type: PasteboardType.plainText, data: Data(text.utf8))], plainText: text, sourceAppName: "Shortcuts")
        switch CapturePipeline.ingest(content, into: store, privacy: SharedStorage.privacy, asSnippet: asSnippet) {
        case .inserted, .refreshedDuplicate: return .result(dialog: "Saved to Rekeep.")
        case .ignored(.sensitive): return .result(dialog: "Not saved — that looks like a password or key.")
        case .ignored: return .result(dialog: "Rekeep couldn’t save that.")
        }
    }
}

struct CopyLatestClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest Clip"
    static let description = IntentDescription("Puts your most recent Rekeep clip (optionally of one type) back on the clipboard.")

    @Parameter(title: "Type", default: .any) var type: ClipKindChoice

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        var q = ClipQuery(limit: 1)
        if let kind = type.kind { q.kinds = [kind] }
        guard let clip = try IntentEnvironment.resolvedStore().fetch(q).first else {
            return .result(value: "", dialog: "Nothing in Rekeep yet.")
        }
        IntentEnvironment.copyToClipboard(clip.plainText)
        return .result(value: clip.plainText, dialog: "Copied “\(clip.title)”.")
    }
}

struct CopyClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Clip"
    static let description = IntentDescription("Copies a clip you choose from Rekeep.")

    @Parameter(title: "Clip") var clip: ClipEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        IntentEnvironment.copyToClipboard(clip.text)
        try? IntentEnvironment.resolvedStore().markUsed(clip.id, bringToFront: false)
        return .result(value: clip.text)
    }
}

struct SearchClipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Rekeep"
    static let description = IntentDescription("Finds clips matching your words and returns them.")

    @Parameter(title: "Search For") var query: String
    @Parameter(title: "Type", default: .any) var type: ClipKindChoice
    @Parameter(title: "Limit", default: 10, inclusiveRange: (1, 100)) var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ClipEntity]> {
        var q = ClipQuery(text: query, limit: limit)
        q.sort = .relevance
        if let kind = type.kind { q.kinds = [kind] }
        return .result(value: try IntentEnvironment.resolvedStore().fetch(q).map(ClipEntity.init))
    }
}

struct RecentClipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Clips"
    static let description = IntentDescription("Returns your most recent clips, newest first.")

    @Parameter(title: "Count", default: 5, inclusiveRange: (1, 100)) var count: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ClipEntity]> {
        .result(value: try IntentEnvironment.resolvedStore().fetch(ClipQuery(limit: count)).map(ClipEntity.init))
    }
}

#if os(macOS)
struct OpenShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Rekeep Shelf"
    static let description = IntentDescription("Shows the Rekeep shelf.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentEnvironment.openShelf?()
        return .result()
    }
}
#endif

struct RekeepShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CopyLatestClipIntent(), phrases: ["Copy my latest \(.applicationName) clip", "Copy last clip from \(.applicationName)"], shortTitle: "Copy Latest Clip", systemImageName: "doc.on.doc")
        AppShortcut(intent: SearchClipsIntent(), phrases: ["Search \(.applicationName)"], shortTitle: "Search Clips", systemImageName: "magnifyingglass")
        AppShortcut(intent: SaveTextIntent(), phrases: ["Save text to \(.applicationName)"], shortTitle: "Save Text", systemImageName: "square.and.arrow.down")
        #if os(macOS)
        AppShortcut(intent: OpenShelfIntent(), phrases: ["Open \(.applicationName) shelf"], shortTitle: "Open Shelf", systemImageName: "rectangle.bottomhalf.inset.filled")
        #endif
    }
}
