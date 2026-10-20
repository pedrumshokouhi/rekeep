import AppKit
import RekeepKit
import SwiftUI

/// Collects placeholder values before a template is pasted.
@MainActor
final class TemplateController {
    private let app: AppModel
    private var panel: FloatingPanel?

    init(app: AppModel) { self.app = app }

    func present(_ clip: Clip, plain: Bool, paste: Bool) {
        close()
        let panel = FloatingPanel(contentRect: .zero, level: .popUpMenu)
        let view = TemplateFillView(clip: clip, onCancel: { [weak self] in self?.close() }, onDeliver: { [weak self] text in
            self?.close()
            self?.app.store.markUsed(clip.id)
            self?.app.deliver(text: text, paste: paste)
        })
        .padding(28)
        .environment(app)
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        let size = hosting.fittingSize
        let screen = ShelfController.targetScreen().visibleFrame
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + max(380, screen.height * 0.38), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct TemplateFillView: View {
    let clip: Clip
    var onCancel: () -> Void
    var onDeliver: (String) -> Void
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    private var placeholders: [TemplateEngine.Placeholder] { TemplateEngine.placeholders(in: clip.text ?? "") }
    private var rendered: String { TemplateEngine.render(clip.text ?? "", values: values) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Image(systemName: "curlybraces").foregroundStyle(Palette.jadeInk)
                Text(clip.title).font(.headline).lineLimit(1)
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                ForEach(placeholders) { p in
                    GridRow {
                        Text(p.displayName).font(.callout).foregroundStyle(Palette.inkSecondary).gridColumnAlignment(.trailing)
                        TextField(p.displayName, text: binding(p.name))
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: p.name)
                            .onSubmit { advance(from: p) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(Palette.inkTertiary)
                ScrollView {
                    Text(rendered).font(.system(size: 12.5)).foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 110)
                .padding(Space.s)
                .background(Palette.cardSunken, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            HStack {
                Text("Placeholders left empty stay as written.").font(.caption).foregroundStyle(Palette.inkTertiary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Copy") { onDeliver(rendered) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 460)
        .contentSurface(radius: 20)
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        .onAppear {
            for p in placeholders where p.isBuiltIn { values[p.name.lowercased()] = TemplateEngine.defaultValue(for: p) }
            focused = placeholders.first { !$0.isBuiltIn }?.name ?? placeholders.first?.name
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name.lowercased()] ?? "" }, set: { values[name.lowercased()] = $0 })
    }

    private func advance(from p: TemplateEngine.Placeholder) {
        guard let i = placeholders.firstIndex(of: p) else { return }
        if i + 1 < placeholders.count { focused = placeholders[i + 1].name } else { onDeliver(rendered) }
    }
}
