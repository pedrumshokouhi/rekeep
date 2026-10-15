#if DEBUG
import AppKit
import RekeepKit

/// End-to-end capture → store → reuse checks against a *private* pasteboard, so the user's
/// clipboard is never touched and no privacy prompt is triggered. Run with `-qa.selftest <file>`.
@MainActor
enum SelfTest {
    struct Result { var name: String; var passed: Bool; var detail: String }

    static func run(reportTo path: String) async {
        var results: [Result] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { results.append(Result(name: name, passed: ok, detail: detail)) }

        let pb = NSPasteboard(name: NSPasteboard.Name("app.rekeep.selftest.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rekeep-selftest-\(UUID().uuidString)")
        guard let store = try? ClipStore(directory: dir, deviceName: "SelfTest") else {
            check("open store", false); write(results, to: path); return
        }
        var settings = PrivacySettings()
        settings.maxItemBytes = 10 * 1024 * 1024
        let monitor = PasteboardMonitor(pasteboard: pb, policy: { PrivacyPolicy(settings: settings) })
        let writer = PasteboardWriter(pasteboard: pb)
        writer.monitor = monitor
        var events: [PasteboardMonitor.Event] = []
        monitor.onEvent = { events.append($0) }

        func lastCaptured() -> CapturedContent? {
            if case .captured(let c)? = events.last { return c }
            return nil
        }
        func lastIgnored() -> IgnoreReason? {
            if case .ignored(let r, _)? = events.last { return r }
            return nil
        }
        func ingest(_ c: CapturedContent) -> (IngestResult?, Clip?) {
            let decision = PrivacyPolicy(settings: settings).evaluate(text: c.plainText, totalBytes: c.totalBytes)
            guard case .store = decision, let (clip, reps) = ClipFactory.makeClip(from: c, deviceID: store.deviceID, deviceName: nil) else {
                if case .ignore(let r) = decision { return (.ignored(r), nil) }
                return (nil, nil)
            }
            return ((try? store.ingest(clip, representations: reps)), clip)
        }

        // 1. Plain text
        pb.clearContents(); pb.setString("Hello from the self-test", forType: .string); monitor.poll()
        let text = lastCaptured()
        check("plain text captured", text?.plainText == "Hello from the self-test")
        if let text { let (r, clip) = ingest(text); check("plain text stored as Text", clip?.kind == .text && { if case .inserted = r { return true }; return false }()) }

        // 2. Unchanged pasteboard is not re-read
        let before = events.count; monitor.poll()
        check("no change → no event", events.count == before)

        // 3. Own write is never re-captured
        if let clip = try? store.fetch(ClipQuery(limit: 1)).first {
            try? writer.write(clip, representations: store.representations(for: clip.id), plainText: false)
            let n = events.count; monitor.poll()
            check("own write ignored", events.count == n, "events after own write: \(events.count - n)")
            check("written text round-trips", pb.string(forType: .string) == "Hello from the self-test")
        }

        // 4. Concealed marker (password managers)
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType(PasteboardMarkers.concealed)], owner: nil)
        pb.setString("hunter2-password", forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarkers.concealed))
        monitor.poll()
        check("concealed marker skipped before reading", lastIgnored() == .markedConcealed)

        // 5. Secret heuristics
        pb.clearContents(); pb.setString("AKIAIOSFODNN7EXAMPLE", forType: .string); monitor.poll()
        if let c = lastCaptured() { check("cloud key not stored", { if case .ignored(.sensitive)? = ingest(c).0 { return true }; return false }()) }

        // 6. Link
        pb.clearContents(); pb.setString("https://www.apple.com/macos/", forType: .string); monitor.poll()
        if let c = lastCaptured() { let clip = ingest(c).1; check("link classified", clip?.kind == .link && clip?.title == "apple.com/macos/") }

        // 7. Rich text keeps formatting and round-trips byte-for-byte
        let attributed = NSAttributedString(string: "Bold move", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pb.clearContents(); pb.setData(rtf, forType: .rtf); pb.setString("Bold move", forType: .string); monitor.poll()
        if let c = lastCaptured(), let clip = ingest(c).1 {
            let reps = store.representations(for: clip.id)
            check("rich text representation kept", reps.contains { $0.type == PasteboardType.rtf && $0.data == rtf })
            try? writer.write(clip, representations: reps, plainText: false)
            check("rich text written back", pb.data(forType: .rtf) == rtf)
            try? writer.write(clip, representations: reps, plainText: true)
            check("plain-text copy strips formatting", pb.data(forType: .rtf) == nil && pb.string(forType: .string) == "Bold move")
        }

        // 8. TIFF screenshot becomes PNG
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
        pb.clearContents(); pb.setData(image.tiffRepresentation, forType: .tiff); monitor.poll()
        if let c = lastCaptured() {
            check("TIFF converted to PNG", c.representations.contains { $0.type == PasteboardType.png } && !c.representations.contains { $0.type == PasteboardType.tiff })
            let clip = ingest(c).1
            check("image dimensions recorded", clip?.kind == .image && clip?.imageWidth == 640 && clip?.imageHeight == 400, "\(clip?.imageWidth ?? 0)×\(clip?.imageHeight ?? 0)")
        }

        // 9. Oversized payload is refused with a reason, not silently dropped
        pb.clearContents(); pb.setData(Data(count: 12 * 1024 * 1024), forType: .png); monitor.poll()
        if let c = lastCaptured() { check("oversized refused", { if case .ignored(.tooLarge)? = ingest(c).0 { return true }; return false }()) }

        // 10. File reference
        let fileURL = dir.appendingPathComponent("Quarterly Report (final) v3.pdf")
        try? Data("pdf".utf8).write(to: fileURL)
        pb.clearContents(); pb.writeObjects([fileURL as NSURL]); monitor.poll()
        if let c = lastCaptured() { let clip = ingest(c).1; check("file reference captured", clip?.kind == .file && clip?.files.first?.name == fileURL.lastPathComponent) }

        // 11. Rapid changes: 200 writes, polling after each, all distinct and stored
        let start = ContinuousClock.now
        for i in 0..<200 {
            pb.clearContents(); pb.setString("rapid \(i)", forType: .string); monitor.poll()
            if let c = lastCaptured() { _ = ingest(c) }
        }
        let rapid = (try? store.fetch(ClipQuery(text: "rapid", limit: 500)).count) ?? 0
        check("rapid changes all stored", rapid == 200, "\(rapid)/200 in \(ContinuousClock.now - start)")

        // 12. Duplicates refresh instead of duplicating
        pb.clearContents(); pb.setString("rapid 5", forType: .string); monitor.poll()
        if let c = lastCaptured() { check("duplicate refreshed", { if case .refreshedDuplicate? = ingest(c).0 { return true }; return false }()) }
        check("duplicate moved to top", (try? store.fetch(ClipQuery(limit: 1)).first?.text) == "rapid 5")

        // 13. Pause
        settings.isCapturePaused = true
        pb.clearContents(); pb.setString("while paused", forType: .string); monitor.poll()
        check("paused → not read", lastIgnored() == .paused)
        settings.isCapturePaused = false

        // 14. Mixed-language search
        pb.clearContents(); pb.setString("Réunion à Zürich — 東京 — مرحبا", forType: .string); monitor.poll()
        if let c = lastCaptured() { _ = ingest(c) }
        check("unicode search", ((try? store.fetch(ClipQuery(text: "zürich"))) ?? []).count == 1 && ((try? store.fetch(ClipQuery(text: "東京"))) ?? []).count == 1)

        write(results, to: path)
    }

    private static func write(_ results: [Result], to path: String) {
        let passed = results.filter(\.passed).count
        var lines = ["Rekeep capture self-test — \(Date.now.formatted())", "\(passed)/\(results.count) passed", ""]
        lines += results.map { "\($0.passed ? "PASS" : "FAIL")  \($0.name)\($0.detail.isEmpty ? "" : "  (\($0.detail))")" }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
