import Foundation
import RekeepKit

/// Security-scoped access to files referenced by clips.
///
/// Under the App Sandbox, Rekeep may read a file copied in Finder only for the current launch.
/// A bookmark created at capture time keeps that access across launches, without broad file entitlements.
nonisolated enum FileAccess {
    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Adds bookmarks to file references that don't have one yet.
    static func attachBookmarks(_ files: [FileReference]) -> [FileReference] {
        files.map { file in
            var f = file
            if f.bookmark == nil { f.bookmark = bookmark(for: f.url) }
            return f
        }
    }

    /// Resolves the current location of a referenced file (following moves when the bookmark allows).
    static func resolve(_ file: FileReference) -> URL? {
        if let data = file.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        let url = file.url
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Runs `body` with access to every resolvable file. Returns nil if any file is unavailable.
    static func withAccess<T>(to files: [FileReference], _ body: ([URL]) throws -> T) rethrows -> T? {
        let urls = files.compactMap(resolve)
        guard urls.count == files.count else { return nil }
        let started = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, didStart) in zip(urls, started) where didStart { url.stopAccessingSecurityScopedResource() } }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return try body(urls)
    }

    static func isAvailable(_ files: [FileReference]) -> Bool {
        withAccess(to: files) { _ in true } ?? false
    }
}
