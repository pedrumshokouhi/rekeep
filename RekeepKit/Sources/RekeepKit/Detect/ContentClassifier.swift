import Foundation

/// Decides what a piece of text "is": a link, a colour, code, or plain prose.
///
/// The rules are deliberately conservative. A wrong label is worse than no label,
/// so ambiguous input falls back to plain text.
public enum ContentClassifier {

    public enum TextClass: Equatable, Sendable {
        case link(URL)
        case color(ParsedColor)
        case code(language: String?)
        case text
    }

    public static func classify(_ raw: String) -> TextClass {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }
        if let color = ColorParser.parse(trimmed) { return .color(color) }
        if let url = link(in: trimmed) { return .link(url) }
        if let language = CodeDetector.detect(raw) { return .code(language: language.isEmpty ? nil : language) }
        return .text
    }

    /// A whole-string web/mail link. Text that merely contains a link stays text.
    public static func link(in trimmed: String) -> URL? {
        guard trimmed.count <= 4096,
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = trimmed.lowercased()
        var candidate = trimmed
        if lower.hasPrefix("www.") { candidate = "https://" + trimmed }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
            return url
        case "mailto", "tel", "ftp", "sftp", "ssh", "file":
            return url
        default:
            return nil
        }
    }
}

// MARK: - Colour

public struct ParsedColor: Equatable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    /// The text exactly as the user copied it.
    public var original: String

    public var hex: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        if alpha < 0.999 {
            return String(format: "#%02X%02X%02X%02X", r, g, b, Int((alpha * 255).rounded()))
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public var rgbString: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        if alpha < 0.999 { return "rgba(\(r), \(g), \(b), \(String(format: "%.2g", alpha)))" }
        return "rgb(\(r), \(g), \(b))"
    }

    /// Relative luminance per WCAG 2.x.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Whether dark text reads better than light text on this colour.
    public var prefersDarkLabel: Bool {
        let contrastWithBlack = (luminance + 0.05) / 0.05
        let contrastWithWhite = 1.05 / (luminance + 0.05)
        return contrastWithBlack >= contrastWithWhite
    }
}

public enum ColorParser {
    /// Parses #RGB, #RGBA, #RRGGBB, #RRGGBBAA, rgb()/rgba(), and hsl()/hsla().
    /// A bare "123456" is intentionally not a colour.
    public static func parse(_ input: String) -> ParsedColor? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 64 else { return nil }
        if s.hasPrefix("#") { return parseHex(String(s.dropFirst()), original: s) }
        let lower = s.lowercased()
        if lower.hasPrefix("rgb") { return parseFunctional(lower, original: s, hsl: false) }
        if lower.hasPrefix("hsl") { return parseFunctional(lower, original: s, hsl: true) }
        return nil
    }

    private static func parseHex(_ hex: String, original: String) -> ParsedColor? {
        guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        var expanded = hex
        if hex.count <= 4 { expanded = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        if expanded.count == 6 {
            return ParsedColor(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, alpha: 1, original: original)
        }
        return ParsedColor(red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255, blue: Double((value >> 8) & 0xFF) / 255, alpha: Double(value & 0xFF) / 255, original: original)
    }

    private static func parseFunctional(_ s: String, original: String, hsl: Bool) -> ParsedColor? {
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let name = s[..<open]
        guard ["rgb", "rgba", "hsl", "hsla"].contains(String(name)) else { return nil }
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let parts = inner
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }

        func number(_ token: String, percentScale: Double) -> Double? {
            if token.hasSuffix("%") { return Double(token.dropLast()).map { $0 / 100 * percentScale } }
            if token.hasSuffix("deg") { return Double(token.dropLast(3)) }
            return Double(token)
        }
        let alpha = parts.count == 4 ? number(parts[3], percentScale: 1) : 1
        guard let alpha, (0...1).contains(alpha) else { return nil }

        if hsl {
            guard let h = number(parts[0], percentScale: 360),
                  let sat = number(parts[1], percentScale: 1), let light = number(parts[2], percentScale: 1),
                  (0...1).contains(sat), (0...1).contains(light) else { return nil }
            let (r, g, b) = hslToRGB(h: h.truncatingRemainder(dividingBy: 360) / 360, s: sat, l: light)
            return ParsedColor(red: r, green: g, blue: b, alpha: alpha, original: original)
        }
        guard let r = number(parts[0], percentScale: 255), let g = number(parts[1], percentScale: 255), let b = number(parts[2], percentScale: 255),
              [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return nil }
        return ParsedColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha, original: original)
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
    }
}

// MARK: - Code

public enum CodeDetector {
    /// Returns nil for prose, "" for code of unknown language, or a language label.
    public static func detect(_ text: String) -> String? {
        guard text.count >= 12, text.count <= 400_000 else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let language = strongSignal(trimmed, lines: lines) { return language }

        // Generic scoring: punctuation density and structure typical of source code.
        var score = 0.0
        let symbols = text.filter { "{}();=<>[]:".contains($0) }.count
        let density = Double(symbols) / Double(max(text.count, 1))
        if density > 0.04 { score += 1 }
        if density > 0.08 { score += 1 }
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        if lines.count >= 3, Double(indented) / Double(lines.count) > 0.25 { score += 1 }
        let semicolonLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasSuffix(";") }.count
        if semicolonLines >= 2 { score += 1 }
        let braceLines = lines.filter { let t = $0.trimmingCharacters(in: .whitespaces); return t.hasSuffix("{") || t == "}" }.count
        if braceLines >= 2 { score += 1.5 }
        // Prose penalty: many sentences ending in full stops.
        let sentenceEnds = text.components(separatedBy: ". ").count - 1
        if sentenceEnds >= 3 { score -= 1.5 }
        if lines.count < 2 { score -= 1 }
        return score >= 3 ? "" : nil
    }

    private static func strongSignal(_ t: String, lines: [Substring]) -> String? {
        let first = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

        if (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]")), t.count > 2,
           let data = t.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            return "JSON"
        }
        if first.hasPrefix("#!/") {
            if first.contains("python") { return "Python" }
            if first.contains("node") { return "JavaScript" }
            return "Shell"
        }
        if t.hasPrefix("<!DOCTYPE html") || t.hasPrefix("<html") { return "HTML" }

        let multi = lines.count >= 2
        func has(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }

        if has(#"(?m)^\s*(import (SwiftUI|Foundation|UIKit|AppKit)|(public |private |@MainActor )?(struct|final class|enum|protocol) \w+(: [\w, ]+)? \{|func \w+\(.*\)( async)?( throws)?( -> [\w\[\]?<>]+)? \{|guard let |if let \w+ = )"#) { return "Swift" }
        if has(#"(?m)^\s*(def \w+\(.*\):|class \w+(\(.*\))?:|from [\w.]+ import |import \w+$|if __name__ == )"#) && multi { return "Python" }
        if has(#"(?m)^\s*(interface \w+ \{|type \w+ = |export (default )?(function|const|class|interface|type) |import .* from ['"])"#) {
            return has(#":\s*(string|number|boolean)\b|interface \w+ \{"#) ? "TypeScript" : "JavaScript"
        }
        if has(#"(?m)(\bconst \w+ = \(.*\) =>|\bfunction \w+\(.*\) \{|console\.log\(|document\.querySelector)"#) { return "JavaScript" }
        if has(#"(?m)^\s*(fn \w+\(.*\)( -> [\w<>&]+)? \{|let mut |impl(<.*>)? \w+|use std::)"#) { return "Rust" }
        if has(#"(?m)^\s*(package \w+$|func (\(\w+ \*?\w+\) )?\w+\(.*\).*\{|import \(\s*$)"#) && multi { return "Go" }
        if has(#"(?is)^\s*(select\s+.+\s+from\s+\w+|insert\s+into\s+\w+|update\s+\w+\s+set\s|create\s+(table|index|view)\s|delete\s+from\s+\w+)"#) { return "SQL" }
        if has(#"(?m)^\s*(public |private )?(class|interface) \w+.*\{|System\.out\.println|public static void main"#) { return "Java" }
        if has(#"(?m)^\s*#include\s*[<"]|int main\(.*\)\s*\{|std::"#) { return "C++" }
        if has(#"(?m)^\s*[.#]?[\w-]+(\s*[,>+~]\s*[.#]?[\w-]+)*\s*\{\s*$"#) && has(#"(?m)^\s*[\w-]+\s*:\s*[^;]+;\s*$"#) { return "CSS" }
        if has(#"(?m)^\s*<([a-z][a-z0-9]*)(\s[^>]*)?>.*</\1>"#) && multi { return "HTML" }
        if has(#"(?m)^\s*(\$ |sudo |brew |npm |git |cd |export \w+=|curl |echo )"#) && t.count < 4000 { return "Shell" }
        if has(#"(?m)^[\w-]+:\s*$"#) && has(#"(?m)^\s{2,}[\w-]+:\s"#) && !has(#"[{};]"#) { return "YAML" }
        return nil
    }
}
