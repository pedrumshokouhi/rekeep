import Foundation

/// Export and import of the whole library as a plain folder:
/// `manifest.json` plus `payloads/<sha256>` files. Readable without Rekeep.
public enum LibraryArchive {
    public static let formatVersion = 1

    struct Manifest: Codable {
        var format: Int
        var exportedAt: Date
        var app: String
        var clips: [ClipRecord]
        var collections: [ClipCollection]
        var memberships: [Membership]
    }

    struct ClipRecord: Codable {
        var id: UUID
        var kind: String
        var title: String
        var text: String?
        var url: String?
        var linkTitle: String?
        var colorValue: String?
        var codeLanguage: String?
        var files: [FileReference]
        var imageWidth: Int?
        var imageHeight: Int?
        var createdAt: Date
        var capturedAt: Date
        var sourceBundleID: String?
        var sourceAppName: String?
        var sourceURL: String?
        var isFavorite: Bool
        var isSnippet: Bool
        var note: String?
        var tags: [String]
        var fingerprint: String
        var ocrText: String?
        var representations: [RepRecord]
    }

    struct RepRecord: Codable {
        var type: String
        var payload: String
        var size: Int
    }

    struct Membership: Codable {
        var clip: UUID
        var collection: UUID
    }

    public struct Summary: Sendable, Equatable {
        public var clips: Int
        public var collections: Int
        public var skippedDuplicates: Int
    }

    /// Writes the library to `directory` (created). Local-only and temporary clips are excluded
    /// unless `includeLocalOnly` is set, since exports are often moved to other machines.
    @discardableResult
    public static func export(_ store: ClipStore, to directory: URL, includeLocalOnly: Bool = false) throws -> Summary {
        let fm = FileManager.default
        let payloads = directory.appendingPathComponent("payloads", isDirectory: true)
        try fm.createDirectory(at: payloads, withIntermediateDirectories: true)
        var records: [ClipRecord] = []
        var memberships: [Membership] = []
        var offset = 0
        while true {
            var q = ClipQuery(limit: 500)
            q.offset = offset
            q.sort = .oldest
            let page = try store.fetch(q)
            if page.isEmpty { break }
            offset += page.count
            for clip in page {
                if clip.expiresAt != nil { continue }
                if clip.isLocalOnly && !includeLocalOnly { continue }
                var reps: [RepRecord] = []
                for rep in store.representations(for: clip.id) {
                    let name = ClipFactory.sha256(rep.data)
                    let target = payloads.appendingPathComponent(name)
                    if !fm.fileExists(atPath: target.path) { try rep.data.write(to: target) }
                    reps.append(RepRecord(type: rep.type, payload: name, size: rep.data.count))
                }
                records.append(ClipRecord(id: clip.id, kind: clip.kind.rawValue, title: clip.title, text: clip.text, url: clip.url?.absoluteString, linkTitle: clip.linkTitle, colorValue: clip.colorValue, codeLanguage: clip.codeLanguage, files: clip.files.map { var f = $0; f.bookmark = nil; return f }, imageWidth: clip.imageWidth, imageHeight: clip.imageHeight, createdAt: clip.createdAt, capturedAt: clip.capturedAt, sourceBundleID: clip.sourceBundleID, sourceAppName: clip.sourceAppName, sourceURL: clip.sourceURL?.absoluteString, isFavorite: clip.isFavorite, isSnippet: clip.isSnippet, note: clip.note, tags: clip.tags, fingerprint: clip.fingerprint, ocrText: clip.ocrText, representations: reps))
                for c in store.collectionIDs(for: clip.id) { memberships.append(Membership(clip: clip.id, collection: c)) }
            }
        }
        let collections = store.collections()
        let manifest = Manifest(format: formatVersion, exportedAt: .now, app: "Rekeep", clips: records, collections: collections, memberships: memberships)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return Summary(clips: records.count, collections: collections.count, skippedDuplicates: 0)
    }

    /// Imports an export folder. Existing clips (same content) are kept; collections merge by id.
    @discardableResult
    public static func `import`(from directory: URL, into store: ClipStore, makePreview: (Data) -> Data? = { ClipFactory.thumbnail(from: $0) }) throws -> Summary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.format <= formatVersion else {
            throw SQLiteError(code: -2, message: "This export was made by a newer version of Rekeep.")
        }
        let existingCollections = Set(store.collections().map(\.id))
        for c in manifest.collections where !existingCollections.contains(c.id) {
            try store.saveCollection(c)
        }
        var imported = 0
        var skipped = 0
        var idMap: [UUID: UUID] = [:]
        for r in manifest.clips {
            let reps: [Representation] = r.representations.compactMap { rec in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("payloads").appendingPathComponent(rec.payload)) else { return nil }
                return Representation(type: rec.type, data: data)
            }
            let clip = Clip(id: r.id, kind: ClipKind(rawValue: r.kind) ?? .text, title: r.title, text: r.text, url: r.url.flatMap(URL.init(string:)), linkTitle: r.linkTitle, colorValue: r.colorValue, codeLanguage: r.codeLanguage, files: r.files, imageWidth: r.imageWidth, imageHeight: r.imageHeight, createdAt: r.createdAt, capturedAt: r.capturedAt, sourceBundleID: r.sourceBundleID, sourceAppName: r.sourceAppName, sourceURL: r.sourceURL.flatMap(URL.init(string:)), deviceID: store.deviceID, deviceName: store.deviceName, isFavorite: r.isFavorite, isSnippet: r.isSnippet, note: r.note, tags: r.tags, byteSize: Int64(reps.reduce(0) { $0 + $1.data.count }), fingerprint: r.fingerprint, ocrText: r.ocrText)
            let preview = clip.kind == .image ? reps.first { PasteboardType.imageTypes.contains($0.type) }.flatMap { makePreview($0.data) } : nil
            switch try store.ingest(clip, representations: reps, preview: preview, refreshDuplicates: false) {
            case .inserted(let id): imported += 1; idMap[r.id] = id
            case .refreshedDuplicate(let id): skipped += 1; idMap[r.id] = id
            case .ignored: break
            }
        }
        let validCollections = Set(store.collections().map(\.id))
        for m in manifest.memberships {
            guard let clipID = idMap[m.clip], validCollections.contains(m.collection) else { continue }
            try store.add([clipID], to: m.collection)
        }
        return Summary(clips: imported, collections: manifest.collections.count, skippedDuplicates: skipped)
    }
}
