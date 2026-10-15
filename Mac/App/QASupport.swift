import AppKit
import RekeepKit

/// Debug-only hooks for visual QA and screenshots, driven by launch arguments:
///   -qa.seed YES        ingest a realistic sample set through the real capture pipeline
///   -qa.shelf YES       open the shelf after launch
///   -qa.library YES     open the library
///   -qa.settings YES    open settings
///   -qa.onboarding YES  show onboarding even if completed
///   -qa.library-dir X   use a separate library directory (keeps QA data out of real data)
/// None of this is compiled into Release builds.
@MainActor
enum QASupport {
    static var skipsOnboarding: Bool {
        #if DEBUG
        let d = UserDefaults.standard
        return d.string(forKey: "qa.selftest") != nil || d.bool(forKey: "qa.seed") || d.bool(forKey: "qa.shelf") || d.bool(forKey: "qa.library") || d.bool(forKey: "qa.settings")
        #else
        return false
        #endif
    }

    #if DEBUG
    static func run(app: AppModel, shelf: ShelfController, delegate: AppDelegate) {
        let d = UserDefaults.standard
        if let report = d.string(forKey: "qa.selftest") {
            Task {
                await SelfTest.run(reportTo: report)
                NSApp.terminate(nil)
            }
            return
        }
        if d.bool(forKey: "qa.seed") { seed(app) }
        if let appearance = d.string(forKey: "qa.appearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if d.bool(forKey: "qa.shelf") { shelf.show() }
            if d.bool(forKey: "qa.library") { delegate.showLibrary(nil) }
            if d.bool(forKey: "qa.settings") { delegate.showSettings() }
            if d.bool(forKey: "qa.onboarding") { delegate.showOnboarding() }
            if d.bool(forKey: "qa.preview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    shelf.shelf.move(1)
                    shelf.debugTogglePreview()
                }
            }
        }
        if let dir = d.string(forKey: "qa.snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                snapshotWindows(to: URL(fileURLWithPath: dir), prefix: d.string(forKey: "qa.appearance") ?? "light")
                if d.bool(forKey: "qa.quit") { NSApp.terminate(nil) }
            }
        }
    }

    /// Renders every visible Rekeep window to PNG in-process (no screen-recording permission needed).
    /// Live Liquid Glass is composited by the window server and does not appear in these renders;
    /// glass areas show what the view itself draws.
    static func snapshotWindows(to dir: URL, prefix: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView, view.bounds.width > 10 else { continue }
            let bounds = view.bounds
            // Always 2× so App Store screenshots are Retina-sharp regardless of this display.
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            let name = (window.title.isEmpty ? (window is FloatingPanel ? "panel" : "window") : window.title)
                .replacingOccurrences(of: " ", with: "-")
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(prefix)-\(name)-\(i).png"))
            }
        }
    }

    static func seed(_ app: AppModel) {
        guard app.statistics.clipCount == 0 else { return }
        let now = Date()
        func text(_ s: String, _ app: String, _ bundle: String, _ minutesAgo: Double, sourceURL: String? = nil) -> CapturedContent {
            CapturedContent(representations: [Representation(type: PasteboardType.plainText, data: Data(s.utf8))], plainText: s, sourceBundleID: bundle, sourceAppName: app, sourceURL: sourceURL.flatMap(URL.init(string:)), capturedAt: now.addingTimeInterval(-minutesAgo * 60))
        }
        func image(_ size: CGSize, _ draw: @escaping (CGRect) -> Void, _ minutesAgo: Double, app: String, bundle: String) -> CapturedContent {
            let img = NSImage(size: size, flipped: false) { rect in draw(rect); return true }
            let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
            let png = rep.representation(using: .png, properties: [:])!
            return CapturedContent(representations: [Representation(type: PasteboardType.png, data: png)], plainText: nil, sourceBundleID: bundle, sourceAppName: app, capturedAt: now.addingTimeInterval(-minutesAgo * 60))
        }
        var items: [CapturedContent] = [
            text("https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views", "Safari", "com.apple.Safari", 2),
            text("""
            struct ShelfCard: View {
                let clip: Clip
                var body: some View {
                    ClipContentView(clip: clip, mode: .card)
                        .contentSurface()
                }
            }
            """, "Xcode", "com.apple.dt.Xcode", 4),
            text("#36B797", "Figma", "com.figma.Desktop", 6),
            text("Thanks for the thoughtful notes on the launch plan. Let’s keep Thursday for the review and move the press briefing to the following Tuesday so the team has a full week with the final build.", "Mail", "com.apple.mail", 11),
            text("Hi {{first_name}},\n\nThanks for reaching out about {{company}}. I’ve attached the deck we discussed — happy to walk through it {{date}}.\n\nBest,\nPedrum", "Notes", "com.apple.Notes", 18),
            text("SELECT name, COUNT(*) AS visits\nFROM sessions\nWHERE started_at > now() - interval '7 days'\nGROUP BY name\nORDER BY visits DESC;", "TablePlus", "com.tinyapp.TablePlus", 26),
            text("+1 (415) 555-0132", "Contacts", "com.apple.AddressBook", 40),
            text("東京の会議は午後三時から始まります。資料は前日までに共有してください。", "Messages", "com.apple.MobileSMS", 55),
            text("https://www.nytimes.com/2026/10/14/technology/personal-computing-design.html?utm_source=newsletter&utm_campaign=morning-briefing-long-query-string", "Safari", "com.apple.Safari", 70),
            text("rgb(32, 35, 41)", "Figma", "com.figma.Desktop", 95),
            text("git checkout -b feature/shelf-motion && git push -u origin feature/shelf-motion", "Terminal", "com.apple.Terminal", 120),
            text("Meeting notes — Q4 planning\n• Ship the shelf redesign\n• Ship Compose to beta testers\n• Audit privacy copy with legal\n• Decide on sync pricing", "Notes", "com.apple.Notes", 180),
        ]
        items.append(image(CGSize(width: 1600, height: 1000), { r in
            NSGradient(colors: [NSColor(hex: 0xD9C8A9), NSColor(hex: 0x7E6A55)])!.draw(in: r, angle: -70)
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.width * 0.12, y: r.height * 0.18, width: r.width * 0.5, height: r.height * 0.6), xRadius: 40, yRadius: 40).fill()
            NSColor(hex: 0x202329).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.width * 0.68, y: r.height * 0.32, width: r.height * 0.36, height: r.height * 0.36)).fill()
        }, 8, app: "Preview", bundle: "com.apple.Preview"))
        items.append(image(CGSize(width: 800, height: 1400), { r in
            NSColor(hex: 0x111318).setFill(); r.fill()
            for i in 0..<9 {
                NSColor(hex: 0x36B797, alpha: 0.12 + Double(i) * 0.08).setFill()
                NSBezierPath(roundedRect: NSRect(x: 60, y: 80 + CGFloat(i) * 140, width: r.width - 120, height: 100), xRadius: 24, yRadius: 24).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: NSColor.white]
            NSAttributedString(string: "Launch checklist", attributes: attrs).draw(at: NSPoint(x: 70, y: r.height - 100))
        }, 30, app: "Screenshot", bundle: "com.apple.screencaptureui"))

        for item in items { app.ingest(item) }
        // Organisation after ingest settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let store = app.store
            if let snippet = try? store.fetch(ClipQuery(text: "first_name", limit: 1)).first { try? store.update(snippet.id) { $0.isSnippet = true; $0.title = "Intro reply" } }
            if let color = try? store.fetch(ClipQuery(text: "#36B797", limit: 1)).first { try? store.setFavorite([color.id], true) }
            let brand = app.createCollection(name: "Brand", symbol: "paintpalette", accent: .jade)
            let dev = app.createCollection(name: "Code Snippets", symbol: "chevron.left.forwardslash.chevron.right", accent: .slate)
            _ = app.createCollection(name: "Research", symbol: "doc.text.magnifyingglass", accent: .sand)
            if let brand { let ids = (try? store.fetch(ClipQuery(kinds: [.color], limit: 10)).map(\.id)) ?? []; try? store.add(ids, to: brand.id) }
            if let dev { let ids = (try? store.fetch(ClipQuery(kinds: [.code], limit: 10)).map(\.id)) ?? []; try? store.add(ids, to: dev.id) }
        }
    }
    #endif
}
