import Foundation
import SwiftUI

/// Restrained, regex-based highlighting: keywords, strings, comments, numbers. Only applied when
/// the language was detected; unknown code renders in a single ink colour.
enum SyntaxHighlighter {
    private static let keywords: [String: Set<String>] = [
        "Swift": ["import", "struct", "class", "enum", "protocol", "extension", "func", "var", "let", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "public", "private", "fileprivate", "internal", "static", "self", "Self", "true", "false", "nil", "try", "await", "async", "throws", "some", "any", "init", "final", "override", "where", "do", "catch", "defer", "break", "continue"],
        "Python": ["def", "class", "import", "from", "as", "return", "if", "elif", "else", "for", "in", "while", "with", "try", "except", "finally", "raise", "lambda", "yield", "None", "True", "False", "and", "or", "not", "is", "pass", "async", "await", "self"],
        "JavaScript": ["const", "let", "var", "function", "return", "if", "else", "for", "while", "import", "from", "export", "default", "class", "new", "this", "async", "await", "try", "catch", "true", "false", "null", "undefined", "of", "in", "typeof", "switch", "case", "break"],
        "TypeScript": ["const", "let", "var", "function", "return", "if", "else", "for", "while", "import", "from", "export", "default", "class", "new", "this", "async", "await", "try", "catch", "true", "false", "null", "undefined", "interface", "type", "implements", "extends", "readonly", "string", "number", "boolean", "of", "in"],
        "Rust": ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "match", "if", "else", "for", "in", "while", "loop", "return", "self", "Self", "true", "false", "Some", "None", "Ok", "Err", "async", "await", "where"],
        "Go": ["package", "import", "func", "var", "const", "type", "struct", "interface", "return", "if", "else", "for", "range", "go", "defer", "chan", "map", "nil", "true", "false", "switch", "case", "default"],
        "SQL": ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "view", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "limit", "as", "null", "is", "in", "distinct", "having", "union", "primary", "key", "desc", "asc"],
        "Java": ["public", "private", "protected", "class", "interface", "static", "void", "new", "return", "if", "else", "for", "while", "import", "package", "extends", "implements", "final", "this", "true", "false", "null", "try", "catch"],
        "C++": ["include", "int", "void", "return", "if", "else", "for", "while", "class", "struct", "public", "private", "const", "auto", "namespace", "using", "std", "true", "false", "nullptr", "template", "typename"],
        "Shell": ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "export", "echo", "sudo", "cd", "local", "return"],
    ]

    static func highlight(_ text: String, language: String?, dark: Bool, maxLines: Int) -> AttributedString {
        var lines = text.replacingOccurrences(of: "\t", with: "    ").split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) }
        let source = lines.joined(separator: "\n")
        var result = AttributedString(source)
        result.foregroundColor = Palette.ink
        guard let language else { return result }

        let keywordColor = Color(platform: dark ? PlatformColor(hex: 0xC99BD4) : PlatformColor(hex: 0x8A3F98))
        let stringColor = Color(platform: dark ? PlatformColor(hex: 0x7DD3B4) : PlatformColor(hex: 0x17795F))
        let commentColor = Palette.inkTertiary
        let numberColor = Color(platform: dark ? PlatformColor(hex: 0xE2B45D) : PlatformColor(hex: 0x95641C))

        func apply(_ pattern: String, _ color: Color, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let r = Range(match.range, in: source), let ar = Range(r, in: result) else { continue }
                result[ar].foregroundColor = color
            }
        }
        if language != "JSON", let words = keywords[language] {
            let alternation = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            apply("\\b(" + alternation + ")\\b", keywordColor, options: language == "SQL" ? [.caseInsensitive] : [])
        }
        apply(#"\b\d+(\.\d+)?\b"#, numberColor)
        apply(#""(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*'"#, stringColor)
        let comment = ["Python", "Shell", "YAML"].contains(language) ? #"#[^\n]*"# : (language == "SQL" ? #"--[^\n]*"# : #"//[^\n]*|/\*[\s\S]*?\*/"#)
        apply(comment, commentColor)
        return result
    }
}

