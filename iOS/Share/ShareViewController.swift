import UniformTypeIdentifiers
import RekeepKit
import SwiftUI
import UIKit

/// "Save to Rekeep" from any app's share sheet. Writes straight into the shared library.
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareView(state: state, done: { [weak self] in self?.finish() }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        save()
    }

    private func save() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task {
            guard let store = try? SharedStorage.openStore(deviceName: UIDevice.current.name) else {
                state.phase = .failed("Rekeep’s library isn’t available.")
                return
            }
            state.store = store
            state.collections = store.collections()
            let contents = await ProviderImporter.content(from: providers)
            var ids: [UUID] = []
            var lastReason: IgnoreReason?
            for content in contents {
                switch CapturePipeline.ingest(content, into: store, privacy: SharedStorage.privacy) {
                case .inserted(let id), .refreshedDuplicate(let id): ids.append(id)
                case .ignored(let reason): lastReason = reason
                }
            }
            if !ids.isEmpty {
                state.savedIDs = ids
                state.phase = .saved
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if lastReason == .sensitive {
                state.phase = .failed("Not saved — this looks like a password or key.")
            } else {
                state.phase = .failed("Rekeep can’t save this kind of item.")
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable
@MainActor
final class ShareState {
    enum Phase: Equatable { case saving, saved, failed(String) }
    var phase: Phase = .saving
    var savedIDs: [UUID] = []
    var collections: [ClipCollection] = []
    var addedTo: Set<UUID> = []
    var store: ClipStore?
}

private struct ShareView: View {
    @Bindable var state: ShareState
    var done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                BrandMarkTwoTone(size: 26)
                Text(title).font(.headline)
                Spacer()
                Button("Done", action: done).bold()
            }
            if state.phase == .saved, !state.collections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add to a collection").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(state.collections) { c in
                                let on = state.addedTo.contains(c.id)
                                Button {
                                    try? state.store?.add(state.savedIDs, to: c.id)
                                    state.addedTo.insert(c.id)
                                } label: {
                                    Label(c.name, systemImage: on ? "checkmark" : c.symbol)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(on ? Palette.jade.opacity(0.18) : Palette.chipFill, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(on)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            if case .failed(let message) = state.phase {
                Text(message).font(.subheadline).foregroundStyle(Palette.inkSecondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .task(id: state.phase) {
            // Close on its own if the user doesn't want to organise.
            if state.phase == .saved, state.collections.isEmpty {
                try? await Task.sleep(for: .seconds(1.2))
                done()
            }
        }
    }

    private var title: String {
        switch state.phase {
        case .saving: "Saving to Rekeep…"
        case .saved: state.savedIDs.count > 1 ? "Saved \(state.savedIDs.count) items" : "Saved to Rekeep"
        case .failed: "Couldn’t save"
        }
    }
}
