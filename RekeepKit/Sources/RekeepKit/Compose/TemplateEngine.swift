import Foundation

/// `{{placeholder}}` templates. Built-in variables are pre-filled but always editable.
public enum TemplateEngine {

    public struct Placeholder: Hashable, Sendable, Identifiable {
        public var name: String
        public var id: String { name }
        public var isBuiltIn: Bool { TemplateEngine.builtIns.contains(name.lowercased()) }

        /// "first_name" → "First name"
        public var displayName: String {
            let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    public static let builtIns: Set<String> = ["date", "time", "datetime", "weekday", "year"]

    private static let regex = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z][A-Za-z0-9_\- ]{0,40}?)\s*\}\}"#)

    /// Unique placeholders in order of first appearance.
    public static func placeholders(in text: String) -> [Placeholder] {
        let range = NSRange(text.startIndex..., in: text)
        var seen: Set<String> = []
        var result: [Placeholder] = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            if seen.insert(name.lowercased()).inserted { result.append(Placeholder(name: name)) }
        }
        return result
    }

    /// Default values for built-ins at a given moment.
    public static func defaultValue(for placeholder: Placeholder, now: Date = .now, locale: Locale = .current) -> String {
        switch placeholder.name.lowercased() {
        case "date": now.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(locale))
        case "time": now.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        case "datetime": now.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        case "weekday": now.formatted(Date.FormatStyle().weekday(.wide).locale(locale))
        case "year": now.formatted(Date.FormatStyle().year(.defaultDigits).locale(locale))
        default: ""
        }
    }

    /// Replaces every placeholder. Unknown names are left untouched so nothing is silently lost.
    public static func render(_ text: String, values: [String: String]) -> String {
        let lowered = Dictionary(values.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let range = NSRange(text.startIndex..., in: text)
        var output = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            output += text[cursor..<whole.lowerBound]
            let name = String(text[nameRange]).lowercased()
            output += lowered[name] ?? String(text[whole])
            cursor = whole.upperBound
        }
        output += text[cursor...]
        return output
    }
}
