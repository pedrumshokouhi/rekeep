import SwiftUI

extension EnvironmentValues {
    /// Lowercased search terms currently in effect, so cards can highlight matches.
    @Entry var searchTerms: [String] = []
}

enum SearchHighlight {
    /// Splits a query the same way the store does: whitespace-separated, quoted phrases kept together.
    static func terms(_ query: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for ch in query {
            if ch == "\"" { quoted.toggle(); continue }
            if ch.isWhitespace && !quoted {
                if !current.isEmpty { result.append(current.lowercased()); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current.lowercased()) }
        return result
    }

    /// The text with every case-insensitive match marked by a soft jade wash and medium weight.
    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        var out = AttributedString(text)
        guard !terms.isEmpty else { return out }
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                if let r = Range(range, in: out) {
                    out[r].backgroundColor = Palette.jade.opacity(0.18)
                    out[r].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = range.upperBound
            }
        }
        return out
    }
}
