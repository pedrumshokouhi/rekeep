import AppKit
import Observation
import RekeepKit

enum LibrarySection: Hashable {
    case history, favorites, snippets, queue, compose
    case collection(UUID)
}

enum DateFilter: String, CaseIterable, Identifiable {
    case any, today, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: "Any Time"
        case .today: "Today"
        case .week: "Past 7 Days"
        case .month: "Past 30 Days"
        case .year: "Past Year"
        }
    }
    var since: Date? {
        let cal = Calendar.current
        switch self {
        case .any: return nil
        case .today: return cal.startOfDay(for: .now)
        case .week: return cal.date(byAdding: .day, value: -7, to: .now)
        case .month: return cal.date(byAdding: .day, value: -30, to: .now)
        case .year: return cal.date(byAdding: .year, value: -1, to: .now)
        }
    }
}

@Observable
@MainActor
final class LibraryModel {
    let app: AppModel

    var section: LibrarySection = .history { didSet { if section != oldValue { selection = []; reload() } } }
    var query = "" { didSet { if query != oldValue { scheduleReload() } } }
    var kinds: Set<ClipKind> = [] { didSet { reload() } }
    var dateFilter: DateFilter = .any { didSet { reload() } }
    var sourceBundleID: String? { didSet { reload() } }
    var sort: ClipQuery.Sort = .recent { didSet { reload() } }
    var showsList = false
    var gridScale: Double = 1.0
    var showsInspector = false

    private(set) var clips: [Clip] = []
    private(set) var hasMore = false
    var selection: Set<UUID> = []
    /// The clip to scroll to after "Show in History".
    var revealID: UUID?
    var editingSnippet: SnippetDraft?

    private var reloadTask: Task<Void, Never>?
    private let pageSize = 300

    init(app: AppModel) { self.app = app }

    var selectedClips: [Clip] { clips.filter { selection.contains($0.id) } }
    var primaryClip: Clip? {
        if selection.count == 1, let id = selection.first { return clips.first { $0.id == id } ?? app.store.clip(id) }
        return nil
    }
    var isFiltering: Bool { !query.isEmpty || !kinds.isEmpty || dateFilter != .any || sourceBundleID != nil }

    var title: String {
        switch section {
        case .history: "History"
        case .favorites: "Favorites"
        case .snippets: "Snippets"
        case .queue: "Paste Queue"
        case .compose: "Compose"
        case .collection(let id): app.collections.first { $0.id == id }?.name ?? "Collection"
        }
    }

    func go(to destination: LibraryDestination) {
        switch destination {
        case .history: section = .history
        case .favorites: section = .favorites
        case .snippets: section = .snippets
        case .compose: section = .compose
        case .queue: section = .queue
        case .collection(let id): section = .collection(id)
        case .clip(let id): showInHistory(id)
        }
    }

    /// Clears filters, switches to History, selects the clip, and scrolls to it.
    func showInHistory(_ id: UUID) {
        query = ""
        kinds = []
        dateFilter = .any
        sourceBundleID = nil
        sort = .recent
        section = .history
        selection = [id]
        revealID = id
        showsInspector = true
        // Make sure the clip is loaded even if it's deep in history.
        Task {
            reload()
            if !clips.contains(where: { $0.id == id }), let clip = app.store.clip(id) {
                let all = await Task.detached { [store = app.store] in
                    (try? store.fetch(ClipQuery(limit: 5000)))?.filter { $0.capturedAt >= clip.capturedAt } ?? []
                }.value
                clips = all
                hasMore = true
            }
            selection = [id]
            revealID = id
        }
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    func reload() {
        guard section != .queue, section != .compose else { return }
        let q = makeQuery(offset: 0)
        let store = app.store
        Task {
            let result = await Task.detached(priority: .userInitiated) { (try? store.fetch(q)) ?? [] }.value
            guard q == self.makeQuery(offset: 0) else { return }
            self.clips = result
            self.hasMore = result.count == self.pageSize
            self.selection.formIntersection(Set(result.map(\.id)))
        }
    }

    func loadMore() {
        guard hasMore else { return }
        let q = makeQuery(offset: clips.count)
        let store = app.store
        hasMore = false
        Task {
            let result = await Task.detached(priority: .userInitiated) { (try? store.fetch(q)) ?? [] }.value
            let existing = Set(clips.map(\.id))
            clips.append(contentsOf: result.filter { !existing.contains($0.id) })
            hasMore = result.count == pageSize
        }
    }

    private func makeQuery(offset: Int) -> ClipQuery {
        var q = ClipQuery(text: query, kinds: kinds, limit: pageSize)
        q.offset = offset
        q.sort = sort
        q.since = dateFilter.since
        q.sourceBundleID = sourceBundleID
        switch section {
        case .favorites: q.favoritesOnly = true
        case .snippets: q.snippetsOnly = true
        case .collection(let id): q.collectionID = id
        default: break
        }
        return q
    }

    // MARK: Selection & keyboard

    func click(_ clip: Clip, command: Bool, shift: Bool) {
        if command {
            if selection.contains(clip.id) { selection.remove(clip.id) } else { selection.insert(clip.id) }
        } else if shift, let anchor = clips.firstIndex(where: { selection.contains($0.id) }), let target = clips.firstIndex(of: clip) {
            selection = Set(clips[min(anchor, target)...max(anchor, target)].map(\.id))
        } else {
            selection = [clip.id]
        }
        if selection.count == 1 { showsInspector = true }
    }

    func moveSelection(by delta: Int, extend: Bool) {
        guard !clips.isEmpty else { return }
        let indices = clips.indices.filter { selection.contains(clips[$0].id) }
        let current = delta > 0 ? (indices.max() ?? -1) : (indices.min() ?? clips.count)
        let next = min(max(current + delta, 0), clips.count - 1)
        if extend { selection.insert(clips[next].id) } else { selection = [clips[next].id] }
        revealID = clips[next].id
        if next > clips.count - 30 { loadMore() }
    }
}

struct SnippetDraft: Identifiable {
    let id = UUID()
    var clipID: UUID?
    var title: String = ""
    var text: String = ""
}
