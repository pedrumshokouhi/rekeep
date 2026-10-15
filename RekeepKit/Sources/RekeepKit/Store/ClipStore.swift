import Foundation

public extension Notification.Name {
    /// Posted (on an arbitrary thread) after any change to the store.
    static let rekeepStoreDidChange = Notification.Name("RekeepStoreDidChange")
}

/// Filters and ordering for a clip listing or search.
public struct ClipQuery: Equatable, Sendable {
    public enum Sort: String, Sendable, CaseIterable, Identifiable {
        case recent, relevance, mostUsed, oldest
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .recent: "Most Recent"
            case .relevance: "Best Match"
            case .mostUsed: "Most Used"
            case .oldest: "Oldest"
            }
        }
    }

    public var text: String = ""
    public var kinds: Set<ClipKind> = []
    public var collectionID: UUID?
    public var favoritesOnly = false
    public var snippetsOnly = false
    public var sourceBundleID: String?
    public var since: Date?
    public var until: Date?
    public var sort: Sort = .recent
    public var limit = 200
    public var offset = 0

    public init(text: String = "", kinds: Set<ClipKind> = [], collectionID: UUID? = nil, favoritesOnly: Bool = false, sort: Sort = .recent, limit: Int = 200) {
        self.text = text
        self.kinds = kinds
        self.collectionID = collectionID
        self.favoritesOnly = favoritesOnly
        self.sort = sort
        self.limit = limit
    }

    /// Search terms, lowercased; quoted phrases are kept together.
    public var terms: [String] {
        var result: [String] = []
        var current = ""
        var inQuote = false
        for ch in text {
            if ch == "\"" { inQuote.toggle(); if !inQuote, !current.isEmpty { result.append(current); current = "" }; continue }
            if ch.isWhitespace && !inQuote {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.lowercased() }
    }
}

/// The result of an ingest attempt.
public enum IngestResult: Equatable, Sendable {
    case inserted(UUID)
    case refreshedDuplicate(UUID)
    case ignored(IgnoreReason)
}

public struct StoreStatistics: Sendable, Equatable {
    public var clipCount: Int
    public var totalBytes: Int64
    public var oldest: Date?
    public init(clipCount: Int, totalBytes: Int64, oldest: Date?) {
        self.clipCount = clipCount
        self.totalBytes = totalBytes
        self.oldest = oldest
    }
}

/// Persistent clip storage: SQLite (WAL) for metadata, full-text search, and small payloads;
/// a content-addressed file store for large payloads.
public final class ClipStore: @unchecked Sendable {
    public let db: SQLiteDatabase
    public let blobs: BlobStore
    public let deviceID: String
    public var deviceName: String?

    /// Payloads at or above this size go to the blob store instead of SQLite.
    static let inlineLimit = 256 * 1024
    public static let schemaVersion = 1

    public init(directory: URL, deviceName: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: directory.appendingPathComponent("Library.sqlite").path)
        blobs = try BlobStore(directory: directory.appendingPathComponent("Payloads", isDirectory: true))
        self.deviceName = deviceName
        try Self.migrate(db)
        deviceID = try Self.loadDeviceID(db)
    }

    /// In-memory store for tests and previews.
    public init(inMemoryWithBlobDirectory blobDirectory: URL) throws {
        db = try SQLiteDatabase.inMemory()
        blobs = try BlobStore(directory: blobDirectory)
        try Self.migrate(db)
        deviceID = try Self.loadDeviceID(db)
    }

    // MARK: - Schema

    static func migrate(_ db: SQLiteDatabase) throws {
        let version = db.userVersion
        if version > schemaVersion {
            throw SQLiteError(code: -1, message: "Library was created by a newer version of Rekeep (schema \(version)).")
        }
        if version < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE IF NOT EXISTS clip (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT,
                    url TEXT,
                    link_title TEXT,
                    color TEXT,
                    language TEXT,
                    files TEXT,
                    image_w INTEGER, image_h INTEGER,
                    created_at REAL NOT NULL,
                    captured_at REAL NOT NULL,
                    modified_at REAL NOT NULL,
                    last_used_at REAL,
                    use_count INTEGER NOT NULL DEFAULT 0,
                    source_bundle TEXT, source_name TEXT, source_url TEXT,
                    device_id TEXT NOT NULL, device_name TEXT,
                    favorite INTEGER NOT NULL DEFAULT 0,
                    local_only INTEGER NOT NULL DEFAULT 0,
                    snippet INTEGER NOT NULL DEFAULT 0,
                    expires_at REAL,
                    note TEXT,
                    tags TEXT,
                    byte_size INTEGER NOT NULL DEFAULT 0,
                    fingerprint TEXT NOT NULL,
                    ocr_text TEXT,
                    sync_state INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS clip_captured ON clip(captured_at DESC);
                CREATE INDEX IF NOT EXISTS clip_fingerprint ON clip(fingerprint);
                CREATE INDEX IF NOT EXISTS clip_kind ON clip(kind, captured_at DESC);
                CREATE INDEX IF NOT EXISTS clip_expiry ON clip(expires_at) WHERE expires_at IS NOT NULL;
                CREATE TABLE IF NOT EXISTS rep (
                    clip_id TEXT NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
                    type TEXT NOT NULL,
                    ord INTEGER NOT NULL,
                    data BLOB,
                    blob_ref TEXT,
                    size INTEGER NOT NULL,
                    PRIMARY KEY (clip_id, type)
                );
                CREATE INDEX IF NOT EXISTS rep_blob ON rep(blob_ref) WHERE blob_ref IS NOT NULL;
                CREATE TABLE IF NOT EXISTS preview (
                    clip_id TEXT PRIMARY KEY REFERENCES clip(id) ON DELETE CASCADE,
                    data BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS collection (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    symbol TEXT NOT NULL,
                    accent TEXT NOT NULL,
                    sort REAL NOT NULL,
                    created_at REAL NOT NULL,
                    modified_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS clip_collection (
                    clip_id TEXT NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
                    collection_id TEXT NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
                    added_at REAL NOT NULL,
                    PRIMARY KEY (clip_id, collection_id)
                );
                CREATE INDEX IF NOT EXISTS cc_collection ON clip_collection(collection_id, added_at DESC);
                CREATE TABLE IF NOT EXISTS composition (
                    id TEXT PRIMARY KEY,
                    payload BLOB NOT NULL,
                    modified_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS tombstone (
                    id TEXT PRIMARY KEY,
                    entity TEXT NOT NULL,
                    deleted_at REAL NOT NULL
                );
                CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(
                    id UNINDEXED, title, body, extra, tokenize = 'trigram'
                );
                """)
            }
            db.userVersion = 1
        }
        // Future migrations: `if db.userVersion < 2 { ... ; db.userVersion = 2 }`
    }

    private static func loadDeviceID(_ db: SQLiteDatabase) throws -> String {
        if let existing = try db.query("SELECT value FROM meta WHERE key = 'device_id'").first?.string("value") {
            return existing
        }
        let id = UUID().uuidString
        try db.execute("INSERT INTO meta (key, value) VALUES ('device_id', ?)", [.text(id)])
        return id
    }

    // MARK: - Ingest

    /// Inserts a new clip, or refreshes an existing clip with the same content.
    @discardableResult
    public func ingest(_ clip: Clip, representations: [Representation], preview: Data? = nil, refreshDuplicates: Bool = true) throws -> IngestResult {
        let result: IngestResult = try db.transaction {
            if let existing = try db.query("SELECT id FROM clip WHERE fingerprint = ? LIMIT 1", [.text(clip.fingerprint)]).first?.string("id"),
               let existingID = UUID(uuidString: existing) {
                guard refreshDuplicates else { return .refreshedDuplicate(existingID) }
                try db.execute("""
                UPDATE clip SET captured_at = ?, source_bundle = COALESCE(?, source_bundle), source_name = COALESCE(?, source_name),
                    source_url = COALESCE(?, source_url), expires_at = CASE WHEN favorite = 1 OR snippet = 1 THEN NULL ELSE ? END
                WHERE id = ?
                """, [SQLValue(clip.capturedAt), SQLValue(clip.sourceBundleID), SQLValue(clip.sourceAppName), SQLValue(clip.sourceURL?.absoluteString), SQLValue(clip.expiresAt), .text(existing)])
                return .refreshedDuplicate(existingID)
            }
            try insertRow(clip)
            try writeRepresentations(representations, for: clip.id)
            if let preview { try db.execute("INSERT OR REPLACE INTO preview (clip_id, data) VALUES (?, ?)", [.text(clip.id.uuidString), .blob(preview)]) }
            try index(clip, replacing: false)
            return .inserted(clip.id)
        }
        notify()
        return result
    }

    private func insertRow(_ c: Clip) throws {
        let filesJSON = c.files.isEmpty ? nil : String(data: try JSONEncoder().encode(c.files), encoding: .utf8)
        try db.execute("""
        INSERT INTO clip (id, kind, title, body, url, link_title, color, language, files, image_w, image_h,
            created_at, captured_at, modified_at, last_used_at, use_count, source_bundle, source_name, source_url,
            device_id, device_name, favorite, local_only, snippet, expires_at, note, tags, byte_size, fingerprint, ocr_text, sync_state)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(c.id.uuidString), .text(c.kind.rawValue), .text(c.title), SQLValue(c.text), SQLValue(c.url?.absoluteString),
            SQLValue(c.linkTitle), SQLValue(c.colorValue), SQLValue(c.codeLanguage), SQLValue(filesJSON),
            SQLValue(c.imageWidth), SQLValue(c.imageHeight),
            SQLValue(c.createdAt), SQLValue(c.capturedAt), SQLValue(c.modifiedAt), SQLValue(c.lastUsedAt), .int(Int64(c.useCount)),
            SQLValue(c.sourceBundleID), SQLValue(c.sourceAppName), SQLValue(c.sourceURL?.absoluteString),
            .text(c.deviceID), SQLValue(c.deviceName), SQLValue(c.isFavorite), SQLValue(c.isLocalOnly), SQLValue(c.isSnippet),
            SQLValue(c.expiresAt), SQLValue(c.note), SQLValue(c.tags.isEmpty ? nil : c.tags.joined(separator: "\n")),
            .int(c.byteSize), .text(c.fingerprint), SQLValue(c.ocrText), .int(Int64(c.syncState.rawValue)),
        ])
    }

    private func writeRepresentations(_ reps: [Representation], for id: UUID) throws {
        for (index, rep) in reps.enumerated() {
            if rep.data.count >= Self.inlineLimit {
                let ref = try blobs.write(rep.data)
                try db.execute("INSERT OR REPLACE INTO rep (clip_id, type, ord, data, blob_ref, size) VALUES (?, ?, ?, NULL, ?, ?)",
                               [.text(id.uuidString), .text(rep.type), .int(Int64(index)), .text(ref), .int(Int64(rep.data.count))])
            } else {
                try db.execute("INSERT OR REPLACE INTO rep (clip_id, type, ord, data, blob_ref, size) VALUES (?, ?, ?, ?, NULL, ?)",
                               [.text(id.uuidString), .text(rep.type), .int(Int64(index)), .blob(rep.data), .int(Int64(rep.data.count))])
            }
        }
    }

    /// Rebuilds the full-text row for one clip from its current metadata and collections.
    private func reindex(_ id: UUID) throws {
        guard let row = try db.query("SELECT * FROM clip WHERE id = ?", [.text(id.uuidString)]).first else { return }
        try index(Self.decode(row), replacing: true)
    }

    private func index(_ clip: Clip, replacing: Bool) throws {
        let id = clip.id
        if replacing { try db.execute("DELETE FROM clip_fts WHERE id = ?", [.text(id.uuidString)]) }
        var extra: [String] = []
        if let url = clip.url { extra.append(url.absoluteString) }
        if let t = clip.linkTitle { extra.append(t) }
        if let n = clip.note { extra.append(n) }
        extra.append(contentsOf: clip.tags.map { "#" + $0 })
        if let s = clip.sourceAppName { extra.append(s) }
        if let s = clip.sourceURL { extra.append(s.absoluteString) }
        if let o = clip.ocrText { extra.append(o) }
        if let lang = clip.codeLanguage { extra.append(lang) }
        if let color = clip.colorValue, let parsed = ColorParser.parse(color) { extra.append(parsed.hex); extra.append(parsed.rgbString) }
        extra.append(contentsOf: clip.files.map(\.name))
        let body = clip.text.map { $0.count > 100_000 ? String($0.prefix(100_000)) : $0 } ?? ""
        try db.execute("INSERT INTO clip_fts (id, title, body, extra) VALUES (?, ?, ?, ?)",
                       [.text(id.uuidString), .text(clip.title), .text(body), .text(extra.joined(separator: "\n"))])
    }

    // MARK: - Reading

    public func clip(_ id: UUID) -> Clip? {
        (try? db.query("SELECT * FROM clip WHERE id = ?", [.text(id.uuidString)]).first).flatMap { $0.map(Self.decode) }
    }

    public func clips(_ ids: [UUID]) -> [Clip] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = (try? db.query("SELECT * FROM clip WHERE id IN (\(placeholders))", ids.map { .text($0.uuidString) })) ?? []
        let byID = Dictionary(rows.map(Self.decode).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    public func fetch(_ q: ClipQuery) throws -> [Clip] {
        var conditions: [String] = []
        var bindings: [SQLValue] = []
        var join = ""
        var order = "c.captured_at DESC"

        let terms = q.terms
        let ftsTerms = terms.filter { $0.count >= 3 }
        let shortTerms = terms.filter { $0.count < 3 }
        if !ftsTerms.isEmpty {
            let match = ftsTerms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            if q.sort == .relevance {
                join = "JOIN (SELECT id, bm25(clip_fts, 0, 6.0, 1.0, 2.0) AS score FROM clip_fts WHERE clip_fts MATCH ?) f ON f.id = c.id"
                bindings.append(.text(match))
                order = "f.score, c.captured_at DESC"
            } else {
                // Ranking is unused here, so skip computing it.
                conditions.append("c.id IN (SELECT id FROM clip_fts WHERE clip_fts MATCH ?)")
                bindings.append(.text(match))
            }
        }
        for term in shortTerms {
            let pattern = "%" + term.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            conditions.append("c.id IN (SELECT id FROM clip_fts WHERE title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR extra LIKE ? ESCAPE '\\')")
            bindings.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern)])
        }
        if !q.kinds.isEmpty {
            var kinds = q.kinds
            if kinds.contains(.text) { kinds.insert(.richText) }
            conditions.append("c.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))")
            bindings.append(contentsOf: kinds.map { .text($0.rawValue) })
        }
        if let collection = q.collectionID {
            conditions.append("c.id IN (SELECT clip_id FROM clip_collection WHERE collection_id = ?)")
            bindings.append(.text(collection.uuidString))
        }
        if q.favoritesOnly { conditions.append("c.favorite = 1") }
        if q.snippetsOnly { conditions.append("c.snippet = 1") }
        if let source = q.sourceBundleID { conditions.append("c.source_bundle = ?"); bindings.append(.text(source)) }
        if let since = q.since { conditions.append("c.captured_at >= ?"); bindings.append(SQLValue(since)) }
        if let until = q.until { conditions.append("c.captured_at < ?"); bindings.append(SQLValue(until)) }
        conditions.append("(c.expires_at IS NULL OR c.expires_at > ?)")
        bindings.append(SQLValue(Date.now))

        switch q.sort {
        case .recent, .relevance: break
        case .mostUsed: order = "c.use_count DESC, c.last_used_at DESC, c.captured_at DESC"
        case .oldest: order = "c.captured_at ASC"
        }
        if q.collectionID != nil, q.sort == .recent, ftsTerms.isEmpty {
            order = "c.captured_at DESC"
        }

        let sql = "SELECT c.* FROM clip c \(join) WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(order) LIMIT ? OFFSET ?"
        bindings.append(.int(Int64(q.limit)))
        bindings.append(.int(Int64(q.offset)))
        return try db.query(sql, bindings).map(Self.decode)
    }

    public func count(_ q: ClipQuery = ClipQuery()) -> Int {
        var query = q
        query.limit = Int.max / 2
        query.offset = 0
        // Cheap path for the unfiltered case.
        if q.text.isEmpty, q.kinds.isEmpty, q.collectionID == nil, !q.favoritesOnly, !q.snippetsOnly {
            let row = try? db.query("SELECT COUNT(*) AS n FROM clip").first
            return Int(row?.int("n") ?? 0)
        }
        return (try? fetch(query).count) ?? 0
    }

    public func representations(for id: UUID) -> [Representation] {
        let rows = (try? db.query("SELECT type, data, blob_ref FROM rep WHERE clip_id = ? ORDER BY ord", [.text(id.uuidString)])) ?? []
        return rows.compactMap { row in
            guard let type = row.string("type") else { return nil }
            if let ref = row.string("blob_ref") {
                guard let data = blobs.read(ref) else { return nil }
                return Representation(type: type, data: data)
            }
            return Representation(type: type, data: row.data("data") ?? Data())
        }
    }

    public func preview(for id: UUID) -> Data? {
        (try? db.query("SELECT data FROM preview WHERE clip_id = ?", [.text(id.uuidString)]).first)?.flatMap { $0.data("data") }
    }

    public func setPreview(_ data: Data, for id: UUID) {
        try? db.execute("INSERT OR REPLACE INTO preview (clip_id, data) VALUES (?, ?)", [.text(id.uuidString), .blob(data)])
        notify()
    }

    public func statistics() -> StoreStatistics {
        let row = try? db.query("SELECT COUNT(*) AS n, COALESCE(SUM(byte_size), 0) AS bytes, MIN(created_at) AS oldest FROM clip").first
        return StoreStatistics(clipCount: Int(row?.int("n") ?? 0), totalBytes: row?.int("bytes") ?? 0, oldest: row?.date("oldest"))
    }

    /// Distinct source apps, most frequent first, for the source filter.
    public func sourceApps(limit: Int = 30) -> [(bundleID: String, name: String, count: Int)] {
        let rows = (try? db.query("""
            SELECT source_bundle, MAX(source_name) AS name, COUNT(*) AS n FROM clip
            WHERE source_bundle IS NOT NULL GROUP BY source_bundle ORDER BY n DESC LIMIT ?
            """, [.int(Int64(limit))])) ?? []
        return rows.compactMap { r in
            guard let id = r.string("source_bundle") else { return nil }
            return (id, r.string("name") ?? id, Int(r.int("n") ?? 0))
        }
    }

    // MARK: - Updating

    public func update(_ id: UUID, _ mutate: (inout Clip) -> Void) throws {
        try db.transaction {
            guard let row = try db.query("SELECT * FROM clip WHERE id = ?", [.text(id.uuidString)]).first else { return }
            var clip = Self.decode(row)
            let before = clip
            mutate(&clip)
            clip.modifiedAt = .now
            if clip.text != before.text, let text = clip.text {
                clip.title = before.title == ClipFactory.title(for: before.text ?? "") ? ClipFactory.title(for: text) : clip.title
                clip.fingerprint = ClipFactory.fingerprint("text", text)
                if clip.kind == .text || clip.kind == .code {
                    // Keep plain text in step with the edited body; drop now-stale rich formatting.
                    try db.execute("DELETE FROM rep WHERE clip_id = ? AND type != ?", [.text(id.uuidString), .text(PasteboardType.plainText)])
                }
                try writeRepresentations([Representation(type: PasteboardType.plainText, data: Data(text.utf8))], for: id)
            }
            try db.execute("""
            UPDATE clip SET title = ?, body = ?, note = ?, tags = ?, favorite = ?, local_only = ?, snippet = ?, expires_at = ?,
                modified_at = ?, ocr_text = ?, fingerprint = ?, link_title = ?, language = ?, sync_state = ?
            WHERE id = ?
            """, [
                .text(clip.title), SQLValue(clip.text), SQLValue(clip.note), SQLValue(clip.tags.isEmpty ? nil : clip.tags.joined(separator: "\n")),
                SQLValue(clip.isFavorite), SQLValue(clip.isLocalOnly), SQLValue(clip.isSnippet), SQLValue(clip.expiresAt),
                SQLValue(clip.modifiedAt), SQLValue(clip.ocrText), .text(clip.fingerprint), SQLValue(clip.linkTitle), SQLValue(clip.codeLanguage),
                .int(Int64(clip.syncState.rawValue)), .text(id.uuidString),
            ])
            try reindex(id)
        }
        notify()
    }

    public func setFavorite(_ ids: [UUID], _ value: Bool) throws {
        try db.transaction {
            for id in ids {
                try db.execute("UPDATE clip SET favorite = ?, expires_at = CASE WHEN ? = 1 THEN NULL ELSE expires_at END, modified_at = ? WHERE id = ?",
                               [SQLValue(value), SQLValue(value), SQLValue(Date.now), .text(id.uuidString)])
            }
        }
        notify()
    }

    /// Records a reuse. `bringToFront` moves the clip to the top of history, as a fresh copy would.
    public func markUsed(_ id: UUID, bringToFront: Bool = true) {
        let now = SQLValue(Date.now)
        if bringToFront {
            try? db.execute("UPDATE clip SET use_count = use_count + 1, last_used_at = ?, captured_at = ? WHERE id = ?", [now, now, .text(id.uuidString)])
        } else {
            try? db.execute("UPDATE clip SET use_count = use_count + 1, last_used_at = ? WHERE id = ?", [now, .text(id.uuidString)])
        }
        notify()
    }

    /// Everything needed to put a deleted clip back exactly as it was.
    public struct Snapshot: Sendable {
        public var clip: Clip
        public var representations: [Representation]
        public var preview: Data?
        public var collectionIDs: Set<UUID>
    }

    public func snapshot(_ id: UUID) -> Snapshot? {
        guard let clip = clip(id) else { return nil }
        return Snapshot(clip: clip, representations: representations(for: id), preview: preview(for: id), collectionIDs: collectionIDs(for: id))
    }

    /// Restores clips captured with `snapshot(_:)` (undo of delete).
    public func restore(_ snapshots: [Snapshot]) throws {
        try db.transaction {
            for s in snapshots {
                let key = SQLValue.text(s.clip.id.uuidString)
                guard try db.query("SELECT 1 FROM clip WHERE id = ?", [key]).isEmpty else { continue }
                try insertRow(s.clip)
                try writeRepresentations(s.representations, for: s.clip.id)
                if let p = s.preview { try db.execute("INSERT OR REPLACE INTO preview (clip_id, data) VALUES (?, ?)", [key, .blob(p)]) }
                let existing = Set(collections().map(\.id))
                for c in s.collectionIDs where existing.contains(c) {
                    try db.execute("INSERT OR IGNORE INTO clip_collection (clip_id, collection_id, added_at) VALUES (?, ?, ?)", [key, .text(c.uuidString), SQLValue(Date.now)])
                }
                try db.execute("DELETE FROM tombstone WHERE id = ?", [key])
                try index(s.clip, replacing: true)
            }
        }
        notify()
    }

    public func setOCRText(_ text: String, for id: UUID) {
        try? db.transaction {
            try db.execute("UPDATE clip SET ocr_text = ? WHERE id = ?", [.text(text), .text(id.uuidString)])
            try reindex(id)
        }
        notify()
    }

    /// Creates a copy of a clip (new identity, same payload). The copy is a snippet so it is never pruned.
    @discardableResult
    public func duplicate(_ id: UUID) throws -> UUID? {
        guard var copy = clip(id) else { return nil }
        let reps = representations(for: id)
        copy.id = UUID()
        copy.createdAt = .now
        copy.capturedAt = .now
        copy.modifiedAt = .now
        copy.title = copy.title + " copy"
        copy.fingerprint = ClipFactory.fingerprint("dup-\(copy.id.uuidString)", copy.fingerprint)
        copy.isSnippet = true
        copy.useCount = 0
        try db.transaction {
            try insertRow(copy)
            try writeRepresentations(reps, for: copy.id)
            if let p = preview(for: id) { try db.execute("INSERT INTO preview (clip_id, data) VALUES (?, ?)", [.text(copy.id.uuidString), .blob(p)]) }
            try reindex(copy.id)
        }
        notify()
        return copy.id
    }

    // MARK: - Deleting

    /// Permanently deletes clips and their payloads, leaving tombstones so synced copies are removed too.
    public func delete(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        var refs: Set<String> = []
        try db.transaction {
            for id in ids {
                let key = SQLValue.text(id.uuidString)
                for row in try db.query("SELECT blob_ref FROM rep WHERE clip_id = ? AND blob_ref IS NOT NULL", [key]) {
                    if let ref = row.string("blob_ref") { refs.insert(ref) }
                }
                try db.execute("DELETE FROM clip_fts WHERE id = ?", [key])
                try db.execute("DELETE FROM clip WHERE id = ?", [key])
                try db.execute("INSERT OR REPLACE INTO tombstone (id, entity, deleted_at) VALUES (?, 'clip', ?)", [key, SQLValue(Date.now)])
            }
        }
        collectGarbage(refs)
        notify()
    }

    /// Deletes every clip except, optionally, favourites, snippets, and clips kept in collections.
    public func clearHistory(keepOrganized: Bool) throws {
        let condition = keepOrganized ? "WHERE favorite = 0 AND snippet = 0 AND id NOT IN (SELECT clip_id FROM clip_collection)" : ""
        let ids = try db.query("SELECT id FROM clip \(condition)").compactMap { $0.string("id").flatMap(UUID.init) }
        try delete(ids)
        if !keepOrganized { try? db.execute("VACUUM") }
    }

    /// Applies retention: removes expired clips and history beyond the limits.
    /// Favourites, snippets, and clips in collections are never pruned.
    @discardableResult
    public func applyRetention(maxAge: TimeInterval?, maxCount: Int?, maxBytes: Int64?, now: Date = .now) throws -> Int {
        var doomed: [UUID] = []
        doomed += try db.query("SELECT id FROM clip WHERE expires_at IS NOT NULL AND expires_at <= ?", [SQLValue(now)]).compactMap { $0.string("id").flatMap(UUID.init) }
        let prunable = "favorite = 0 AND snippet = 0 AND id NOT IN (SELECT clip_id FROM clip_collection)"
        if let maxAge {
            doomed += try db.query("SELECT id FROM clip WHERE \(prunable) AND captured_at < ?", [SQLValue(now.addingTimeInterval(-maxAge))]).compactMap { $0.string("id").flatMap(UUID.init) }
        }
        if let maxCount {
            doomed += try db.query("SELECT id FROM clip WHERE \(prunable) ORDER BY captured_at DESC LIMIT -1 OFFSET ?", [.int(Int64(maxCount))]).compactMap { $0.string("id").flatMap(UUID.init) }
        }
        if let maxBytes {
            var running: Int64 = 0
            for row in try db.query("SELECT id, byte_size, favorite, snippet, (id IN (SELECT clip_id FROM clip_collection)) AS kept FROM clip ORDER BY captured_at DESC") {
                running += row.int("byte_size") ?? 0
                let protected = row.bool("favorite") || row.bool("snippet") || row.bool("kept")
                if running > maxBytes, !protected, let id = row.string("id").flatMap(UUID.init) { doomed.append(id) }
            }
        }
        let unique = Array(Set(doomed))
        try delete(unique)
        return unique.count
    }

    private func collectGarbage(_ refs: Set<String>) {
        for ref in refs {
            let stillUsed = (try? db.query("SELECT 1 FROM rep WHERE blob_ref = ? LIMIT 1", [.text(ref)]).isEmpty == false) ?? true
            if !stillUsed { blobs.remove(ref) }
        }
    }

    // MARK: - Collections

    public func collections() -> [ClipCollection] {
        let rows = (try? db.query("SELECT * FROM collection ORDER BY sort, created_at")) ?? []
        return rows.compactMap { r in
            guard let id = r.string("id").flatMap(UUID.init) else { return nil }
            return ClipCollection(id: id, name: r.string("name") ?? "", symbol: r.string("symbol") ?? "square.stack",
                                  accent: CollectionAccent(rawValue: r.string("accent") ?? "") ?? .graphite,
                                  sortIndex: r.double("sort") ?? 0, createdAt: r.date("created_at") ?? .now, modifiedAt: r.date("modified_at") ?? .now)
        }
    }

    public func collectionCounts() -> [UUID: Int] {
        let rows = (try? db.query("SELECT collection_id, COUNT(*) AS n FROM clip_collection GROUP BY collection_id")) ?? []
        return Dictionary(rows.compactMap { r in r.string("collection_id").flatMap(UUID.init).map { ($0, Int(r.int("n") ?? 0)) } }, uniquingKeysWith: { a, _ in a })
    }

    @discardableResult
    public func saveCollection(_ collection: ClipCollection) throws -> ClipCollection {
        var c = collection
        if c.sortIndex == 0, (try? db.query("SELECT 1 FROM collection WHERE id = ?", [.text(c.id.uuidString)]).isEmpty) ?? true {
            let maxSort = (try? db.query("SELECT COALESCE(MAX(sort), 0) AS m FROM collection").first?.double("m")) ?? nil
            c.sortIndex = (maxSort ?? 0) + 1
        }
        c.modifiedAt = .now
        try db.execute("""
        INSERT INTO collection (id, name, symbol, accent, sort, created_at, modified_at) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, symbol = excluded.symbol, accent = excluded.accent, sort = excluded.sort, modified_at = excluded.modified_at
        """, [.text(c.id.uuidString), .text(c.name), .text(c.symbol), .text(c.accent.rawValue), .double(c.sortIndex), SQLValue(c.createdAt), SQLValue(c.modifiedAt)])
        notify()
        return c
    }

    public func reorderCollections(_ ordered: [UUID]) throws {
        try db.transaction {
            for (i, id) in ordered.enumerated() {
                try db.execute("UPDATE collection SET sort = ?, modified_at = ? WHERE id = ?", [.double(Double(i + 1)), SQLValue(Date.now), .text(id.uuidString)])
            }
        }
        notify()
    }

    /// Deletes a collection. Its clips stay in history unless `deleteClips` is explicitly true.
    public func deleteCollection(_ id: UUID, deleteClips: Bool = false) throws {
        var clipIDs: [UUID] = []
        if deleteClips {
            clipIDs = try db.query("SELECT clip_id FROM clip_collection WHERE collection_id = ?", [.text(id.uuidString)]).compactMap { $0.string("clip_id").flatMap(UUID.init) }
        }
        try db.transaction {
            try db.execute("DELETE FROM collection WHERE id = ?", [.text(id.uuidString)])
            try db.execute("INSERT OR REPLACE INTO tombstone (id, entity, deleted_at) VALUES (?, 'collection', ?)", [.text(id.uuidString), SQLValue(Date.now)])
        }
        if deleteClips { try delete(clipIDs) }
        notify()
    }

    public func add(_ clipIDs: [UUID], to collectionID: UUID) throws {
        try db.transaction {
            for id in clipIDs {
                try db.execute("INSERT OR IGNORE INTO clip_collection (clip_id, collection_id, added_at) VALUES (?, ?, ?)",
                               [.text(id.uuidString), .text(collectionID.uuidString), SQLValue(Date.now)])
                try db.execute("UPDATE clip SET expires_at = NULL WHERE id = ?", [.text(id.uuidString)])
            }
        }
        notify()
    }

    public func remove(_ clipIDs: [UUID], from collectionID: UUID) throws {
        try db.transaction {
            for id in clipIDs {
                try db.execute("DELETE FROM clip_collection WHERE clip_id = ? AND collection_id = ?", [.text(id.uuidString), .text(collectionID.uuidString)])
            }
        }
        notify()
    }

    public func collectionIDs(for clipID: UUID) -> Set<UUID> {
        let rows = (try? db.query("SELECT collection_id FROM clip_collection WHERE clip_id = ?", [.text(clipID.uuidString)])) ?? []
        return Set(rows.compactMap { $0.string("collection_id").flatMap(UUID.init) })
    }

    // MARK: - Compositions

    public func compositions() -> [Composition] {
        let rows = (try? db.query("SELECT payload FROM composition ORDER BY modified_at DESC")) ?? []
        return rows.compactMap { $0.data("payload").flatMap { try? JSONDecoder().decode(Composition.self, from: $0) } }
    }

    public func save(_ composition: Composition) throws {
        var c = composition
        c.modifiedAt = .now
        try db.execute("INSERT OR REPLACE INTO composition (id, payload, modified_at) VALUES (?, ?, ?)",
                       [.text(c.id.uuidString), .blob(try JSONEncoder().encode(c)), SQLValue(c.modifiedAt)])
        notify()
    }

    public func deleteComposition(_ id: UUID) throws {
        try db.execute("DELETE FROM composition WHERE id = ?", [.text(id.uuidString)])
        notify()
    }

    // MARK: - Decoding

    static func decode(_ r: SQLRow) -> Clip {
        let files: [FileReference] = r.string("files").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([FileReference].self, from: $0) } ?? []
        return Clip(
            id: r.string("id").flatMap(UUID.init) ?? UUID(),
            kind: ClipKind(rawValue: r.string("kind") ?? "") ?? .text,
            title: r.string("title") ?? "",
            text: r.string("body"),
            url: r.string("url").flatMap(URL.init(string:)),
            linkTitle: r.string("link_title"),
            colorValue: r.string("color"),
            codeLanguage: r.string("language"),
            files: files,
            imageWidth: r.int("image_w").map(Int.init),
            imageHeight: r.int("image_h").map(Int.init),
            createdAt: r.date("created_at") ?? .now,
            capturedAt: r.date("captured_at"),
            modifiedAt: r.date("modified_at"),
            lastUsedAt: r.date("last_used_at"),
            useCount: Int(r.int("use_count") ?? 0),
            sourceBundleID: r.string("source_bundle"),
            sourceAppName: r.string("source_name"),
            sourceURL: r.string("source_url").flatMap(URL.init(string:)),
            deviceID: r.string("device_id") ?? "",
            deviceName: r.string("device_name"),
            isFavorite: r.bool("favorite"),
            isLocalOnly: r.bool("local_only"),
            isSnippet: r.bool("snippet"),
            expiresAt: r.date("expires_at"),
            note: r.string("note"),
            tags: r.string("tags")?.split(separator: "\n").map(String.init) ?? [],
            byteSize: r.int("byte_size") ?? 0,
            fingerprint: r.string("fingerprint") ?? "",
            ocrText: r.string("ocr_text"),
            syncState: SyncState(rawValue: Int(r.int("sync_state") ?? 0)) ?? .localOnly
        )
    }

    private func notify() {
        NotificationCenter.default.post(name: .rekeepStoreDidChange, object: self)
    }
}

/// Content-addressed file storage for large payloads.
public final class BlobStore: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for ref: String) -> URL {
        directory.appendingPathComponent(String(ref.prefix(2)), isDirectory: true).appendingPathComponent(ref)
    }

    public func write(_ data: Data) throws -> String {
        let ref = ClipFactory.sha256(data)
        let target = url(for: ref)
        if FileManager.default.fileExists(atPath: target.path) { return ref }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: target, options: .atomic)
        #endif
        return ref
    }

    public func read(_ ref: String) -> Data? { try? Data(contentsOf: url(for: ref), options: .mappedIfSafe) }

    public func remove(_ ref: String) { try? FileManager.default.removeItem(at: url(for: ref)) }

    public func totalSize() -> Int64 {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
