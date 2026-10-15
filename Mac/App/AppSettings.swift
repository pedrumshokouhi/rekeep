import Foundation
import Observation
import RekeepKit

/// How long ordinary history is kept.
enum HistoryRetention: String, CaseIterable, Identifiable, Codable {
    case day, week, month, year, forever
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "1 Day"
        case .week: "1 Week"
        case .month: "1 Month"
        case .year: "1 Year"
        case .forever: "Forever"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 31 * 86_400
        case .year: 366 * 86_400
        case .forever: nil
        }
    }
}

enum PasteBehavior: String, CaseIterable, Identifiable, Codable {
    /// Put the clip on the clipboard and paste it into the frontmost app (needs Accessibility).
    case pasteDirectly
    /// Only put the clip on the clipboard.
    case copyOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pasteDirectly: "Paste into the active app"
        case .copyOnly: "Copy to clipboard only"
        }
    }
}

enum MultiCopySeparator: String, CaseIterable, Identifiable, Codable {
    case newline, blankLine, space, comma, tab
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newline: "New Line"
        case .blankLine: "Blank Line"
        case .space: "Space"
        case .comma: "Comma"
        case .tab: "Tab"
        }
    }
    var string: String {
        switch self {
        case .newline: "\n"
        case .blankLine: "\n\n"
        case .space: " "
        case .comma: ", "
        case .tab: "\t"
        }
    }
}

/// User preferences, persisted in UserDefaults. Observable so views update live.
@Observable
final class AppSettings {
    private let defaults: UserDefaults
    private var isLoading = true

    var privacy = PrivacySettings() { didSet { save(privacy, "privacy") } }
    var density: ShelfDensity = .comfortable { didSet { save(density, "density") } }
    var useListLayout = false { didSet { save(useListLayout, "useListLayout") } }
    var retention: HistoryRetention = .month { didSet { save(retention, "retention") } }
    var pasteBehavior: PasteBehavior = .pasteDirectly { didSet { save(pasteBehavior, "pasteBehavior") } }
    var pastePlainTextByDefault = false { didSet { save(pastePlainTextByDefault, "pastePlainTextByDefault") } }
    var multiSeparator: MultiCopySeparator = .newline { didSet { save(multiSeparator, "multiSeparator") } }
    var shortcut: KeyShortcut = .defaultShelf { didSet { save(shortcut, "shortcut") } }
    var queueShortcut: KeyShortcut? = .defaultQueue { didSet { save(queueShortcut, "queueShortcut") } }
    var collectionShortcuts: [String: KeyShortcut] = [:] { didSet { save(collectionShortcuts, "collectionShortcuts") } }
    var showKeyboardHints = true { didSet { save(showKeyboardHints, "showKeyboardHints") } }
    var playFeedbackHUD = true { didSet { save(playFeedbackHUD, "playFeedbackHUD") } }
    var maxLibraryBytes: Int64? = nil { didSet { save(maxLibraryBytes, "maxLibraryBytes") } }
    var hasCompletedOnboarding = false { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }
    var launchAtLogin = false { didSet { save(launchAtLogin, "launchAtLogin") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        privacy = load("privacy") ?? PrivacySettings()
        density = load("density") ?? .comfortable
        useListLayout = load("useListLayout") ?? false
        retention = load("retention") ?? .month
        pasteBehavior = load("pasteBehavior") ?? .pasteDirectly
        pastePlainTextByDefault = load("pastePlainTextByDefault") ?? false
        multiSeparator = load("multiSeparator") ?? .newline
        shortcut = load("shortcut") ?? .defaultShelf
        queueShortcut = load("queueShortcut") ?? .defaultQueue
        collectionShortcuts = load("collectionShortcuts") ?? [:]
        showKeyboardHints = load("showKeyboardHints") ?? true
        playFeedbackHUD = load("playFeedbackHUD") ?? true
        maxLibraryBytes = load("maxLibraryBytes") ?? nil
        hasCompletedOnboarding = load("hasCompletedOnboarding") ?? false
        launchAtLogin = load("launchAtLogin") ?? false
        isLoading = false
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        guard !isLoading, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: "rekeep." + key)
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: "rekeep." + key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
