import Foundation

/// The kind of thing a clip primarily is. Determines which card renderer draws it.
public enum ClipKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case text
    case richText
    case link
    case image
    case file
    case code
    case color

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .code: "Code"
        case .color: "Color"
        }
    }

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .color: "paintpalette"
        }
    }

    /// Kinds offered as filters. Rich text folds into Text for filtering purposes.
    public static let filterable: [ClipKind] = [.text, .link, .image, .code, .color, .file]
}

/// A file referenced by a clip.
public struct FileReference: Codable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var byteSize: Int64?
    public var contentType: String?
    /// True when Rekeep holds its own copy (explicit import). False for a reference to the original.
    public var isImportedCopy: Bool
    /// Security-scoped bookmark so a sandboxed app can reach the original after relaunch.
    public var bookmark: Data?

    public init(path: String, name: String, byteSize: Int64?, contentType: String?, isImportedCopy: Bool, bookmark: Data? = nil) {
        self.path = path
        self.name = name
        self.byteSize = byteSize
        self.contentType = contentType
        self.isImportedCopy = isImportedCopy
        self.bookmark = bookmark
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Where a clip stands with respect to synchronisation.
public enum SyncState: Int, Codable, Sendable {
    case localOnly = 0
    case pending = 1
    case synced = 2
    case needsAttention = 3
}

/// Something the user copied, imported, or wrote. Metadata only; payload bytes live in `Representation`s.
public struct Clip: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: ClipKind
    public var title: String
    /// Plain-text content, when the clip has any.
    public var text: String?
    public var url: URL?
    public var linkTitle: String?
    public var colorValue: String?
    public var codeLanguage: String?
    public var files: [FileReference]
    public var imageWidth: Int?
    public var imageHeight: Int?

    /// When the content was first seen.
    public var createdAt: Date
    /// When the content was most recently copied (duplicates refresh this).
    public var capturedAt: Date
    public var modifiedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public var sourceBundleID: String?
    public var sourceAppName: String?
    /// Only set when the source app actually supplied one on the pasteboard.
    public var sourceURL: URL?
    public var deviceID: String
    public var deviceName: String?

    public var isFavorite: Bool
    public var isLocalOnly: Bool
    public var isSnippet: Bool
    public var expiresAt: Date?
    public var note: String?
    public var tags: [String]

    public var byteSize: Int64
    public var fingerprint: String
    public var ocrText: String?
    public var syncState: SyncState

    public init(
        id: UUID = UUID(),
        kind: ClipKind,
        title: String,
        text: String? = nil,
        url: URL? = nil,
        linkTitle: String? = nil,
        colorValue: String? = nil,
        codeLanguage: String? = nil,
        files: [FileReference] = [],
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        createdAt: Date = .now,
        capturedAt: Date? = nil,
        modifiedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        sourceURL: URL? = nil,
        deviceID: String,
        deviceName: String? = nil,
        isFavorite: Bool = false,
        isLocalOnly: Bool = false,
        isSnippet: Bool = false,
        expiresAt: Date? = nil,
        note: String? = nil,
        tags: [String] = [],
        byteSize: Int64 = 0,
        fingerprint: String,
        ocrText: String? = nil,
        syncState: SyncState = .localOnly
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.url = url
        self.linkTitle = linkTitle
        self.colorValue = colorValue
        self.codeLanguage = codeLanguage
        self.files = files
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.createdAt = createdAt
        self.capturedAt = capturedAt ?? createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.sourceURL = sourceURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isFavorite = isFavorite
        self.isLocalOnly = isLocalOnly
        self.isSnippet = isSnippet
        self.expiresAt = expiresAt
        self.note = note
        self.tags = tags
        self.byteSize = byteSize
        self.fingerprint = fingerprint
        self.ocrText = ocrText
        self.syncState = syncState
    }

    /// True when the clip has a text body that can be edited in place.
    public var isTextEditable: Bool {
        switch kind {
        case .text, .code, .link, .color: true
        case .richText, .image, .file: false
        }
    }

    /// The best plain-text rendition for plain-text copy, compose, and templates.
    public var plainText: String {
        if let text, !text.isEmpty { return text }
        if let url { return url.absoluteString }
        if let colorValue { return colorValue }
        if !files.isEmpty { return files.map(\.path).joined(separator: "\n") }
        return title
    }

    public var isTemplate: Bool {
        guard let text else { return false }
        return TemplateEngine.placeholders(in: text).isEmpty == false
    }
}

/// One pasteboard flavour of a clip's payload, e.g. public.rtf or public.png.
public struct Representation: Hashable, Sendable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// A user-defined group of clips. Clips can belong to many collections.
public struct ClipCollection: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var accent: CollectionAccent
    public var sortIndex: Double
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, symbol: String = "square.stack", accent: CollectionAccent = .graphite, sortIndex: Double = 0, createdAt: Date = .now, modifiedAt: Date = .now) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.accent = accent
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// A small, deliberately restrained set of collection accents.
public enum CollectionAccent: String, Codable, Sendable, CaseIterable, Identifiable {
    case graphite, jade, slate, sand, clay, plum, moss, ocean
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}
