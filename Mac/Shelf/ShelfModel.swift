import AppKit
import Observation
import RekeepKit

/// What the shelf is showing.
enum ShelfScope: Hashable {
    case history
    case favorites
    case snippets
    case collection(UUID)
}

/// State for the quick shelf: query, scope, results, selection.
@Observable
@MainActor
final class ShelfModel {
    let app: AppModel

    var query = "" { didSet { if query != oldValue { scheduleReload(debounce: true) } } }
    var scope: ShelfScope = .history { didSet { if scope != oldValue { scheduleReload(debounce: false) } } }
    var kindFilter: ClipKind? { didSet { if kindFilter != oldValue { scheduleReload(debounce: false) } } }

    private(set) var clips: [Clip] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    var selectedID: UUID?
    /// Extra clips selected with ⇧/⌘ for multi-copy or Compose.
    var multiSelection: Set<UUID> = []
    var isPreviewing = false
    var isCommandHeld = false
    var isVisible = false
    /// Index of the first card visible in the row (for ⌘1–⌘9).
    var firstVisibleIndex = 0
    /// Incremented when the shelf opens, so views can reset scroll and focus.
    private(set) var presentationID = 0

    private var reloadTask: Task<Void, Never>?
    private var lastRevision = -1
    private let pageSize = 120

    init(app: AppModel) { self.app = app }

    var selectedClip: Clip? { selectedID.flatMap { id in clips.first { $0.id == id } } }
    var selectedIndex: Int? { selectedID.flatMap { id in clips.firstIndex { $0.id == id } } }

    /// Clips acted on by multi-item commands: the multi-selection in shelf order, or just the selection.
    var actionClips: [Clip] {
        if !multiSelection.isEmpty { return clips.filter { multiSelection.contains($0.id) } }
        return selectedClip.map { [$0] } ?? []
    }

    var isFiltered: Bool { !query.isEmpty || kindFilter != nil || scope != .history }

    // MARK: Presentation

    func willPresent() {
        presentationID += 1
        isPreviewing = false
        multiSelection = []
        isCommandHeld = false
        // Fresh open: back to recent history unless the user is mid-search in a collection.
        if query.isEmpty { selectedID = nil }
        reload(resetSelection: true)
    }

    func didDismiss() {
        isPreviewing = false
        query = ""
        kindFilter = nil
        scope = .history
    }

    // MARK: Loading

    func scheduleReload(debounce: Bool) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            self?.reload(resetSelection: true)
        }
    }

    /// Reload if the store changed while the shelf is visible.
    func refreshIfNeeded() {
        guard app.revision != lastRevision else { return }
        reload(resetSelection: false)
    }

    func reload(resetSelection: Bool) {
        lastRevision = app.revision
        let q = makeQuery(offset: 0)
        let store = app.store
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { (try? store.fetch(q)) ?? [] }.value
            guard q == self.makeQuery(offset: 0) else { return } // a newer query superseded this one
            self.apply(result, append: false, resetSelection: resetSelection)
        }
    }

    func loadMoreIfNeeded(currentIndex: Int) {
        guard hasMore, !isLoading, currentIndex >= clips.count - 20 else { return }
        let q = makeQuery(offset: clips.count)
        let store = app.store
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { (try? store.fetch(q)) ?? [] }.value
            self.apply(result, append: true, resetSelection: false)
        }
    }

    private func apply(_ result: [Clip], append: Bool, resetSelection: Bool) {
        isLoading = false
        hasMore = result.count == pageSize
        if append {
            let existing = Set(clips.map(\.id))
            clips.append(contentsOf: result.filter { !existing.contains($0.id) })
        } else {
            clips = result
        }
        let ids = Set(clips.map(\.id))
        multiSelection.formIntersection(ids)
        if resetSelection || selectedID.map({ !ids.contains($0) }) ?? true {
            selectedID = clips.first?.id
        }
    }

    private func makeQuery(offset: Int) -> ClipQuery {
        var q = ClipQuery(text: query, limit: pageSize)
        q.offset = offset
        if let kindFilter { q.kinds = [kindFilter] }
        switch scope {
        case .history: break
        case .favorites: q.favoritesOnly = true
        case .snippets: q.snippetsOnly = true
        case .collection(let id): q.collectionID = id
        }
        // While searching, rank by relevance but keep recent ties first.
        if !query.isEmpty { q.sort = .relevance }
        return q
    }

    // MARK: Navigation

    func move(_ delta: Int, extend: Bool = false) {
        guard !clips.isEmpty else { return }
        let current = selectedIndex ?? (delta > 0 ? -1 : clips.count)
        let next = min(max(current + delta, 0), clips.count - 1)
        if extend, let id = selectedID {
            multiSelection.insert(id)
            multiSelection.insert(clips[next].id)
        } else if !extend {
            multiSelection = []
        }
        selectedID = clips[next].id
        loadMoreIfNeeded(currentIndex: next)
    }

    func moveToEdge(start: Bool) {
        guard !clips.isEmpty else { return }
        selectedID = start ? clips.first?.id : clips.last?.id
        multiSelection = []
    }

    func select(_ clip: Clip, extend: Bool, toggle: Bool) {
        if toggle {
            if multiSelection.isEmpty, let current = selectedID { multiSelection.insert(current) }
            if multiSelection.contains(clip.id) { multiSelection.remove(clip.id) } else { multiSelection.insert(clip.id) }
        } else if extend, let anchor = selectedIndex, let target = clips.firstIndex(of: clip) {
            let range = min(anchor, target)...max(anchor, target)
            multiSelection = Set(clips[range].map(\.id))
        } else {
            multiSelection = []
        }
        selectedID = clip.id
    }

    func selectAll() { multiSelection = Set(clips.map(\.id)) }

    /// Scope list for Tab cycling, in strip order.
    var scopes: [ShelfScope] {
        [.history, .favorites, .snippets] + app.collections.map { .collection($0.id) }
    }

    func cycleScope(_ delta: Int) {
        let all = scopes
        guard let i = all.firstIndex(of: scope) else { scope = .history; return }
        scope = all[(i + delta + all.count) % all.count]
    }

    /// The clip at a 1-based visible position, for ⌘1–⌘9.
    func clip(atShortcut n: Int) -> Clip? {
        let index = firstVisibleIndex + n - 1
        return clips.indices.contains(index) ? clips[index] : nil
    }
}
