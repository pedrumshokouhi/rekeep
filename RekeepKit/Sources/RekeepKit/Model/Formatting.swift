import Foundation

public enum ClipFormatting {
    /// Compact capture time for cards: "Now", "4m", "2h", "Yesterday", "Tue", "Oct 3", "Oct 3, 2024".
    public static func relative(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if seconds < 6 * 86_400 { return date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(Date.FormatStyle(locale: locale).month(.abbreviated).day())
        }
        return date.formatted(Date.FormatStyle(locale: locale).month(.abbreviated).day().year())
    }

    /// Secondary detail line for a card.
    public static func detail(for clip: Clip) -> String {
        switch clip.kind {
        case .text, .richText, .code:
            let text = clip.text ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            if lines > 1 { return "\(lines) lines" }
            let count = text.count
            return count == 1 ? "1 character" : "\(count.formatted()) characters"
        case .link:
            // The card already shows the domain; the footer carries provenance instead.
            return clip.sourceAppName ?? ""
        case .image:
            if let w = clip.imageWidth, let h = clip.imageHeight { return "\(w) × \(h)" }
            return ByteCountFormatter.string(fromByteCount: clip.byteSize, countStyle: .file)
        case .color:
            guard let value = clip.colorValue, let c = ColorParser.parse(value) else { return "Color" }
            return value.hasPrefix("#") ? c.rgbString : c.hex
        case .file:
            if clip.files.count > 1 { return "\(clip.files.count) items" }
            if let size = clip.files.first?.byteSize { return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
            return clip.files.first?.isImportedCopy == true ? "Imported copy" : "File reference"
        }
    }

    /// Type label for the card header; uses the code language when one was detected reliably.
    public static func typeLabel(for clip: Clip) -> String {
        if clip.kind == .code, let language = clip.codeLanguage { return language }
        if clip.isTemplate { return "Template" }
        return clip.kind.label
    }
}
