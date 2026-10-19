import RekeepKit
import SwiftUI
import UIKit

/// The Rekeep keyboard: a small shelf of saved clips that types the one you tap.
///
/// It never records what you type, never uses the network, and inserts text only. Reading the
/// library needs "Allow Full Access" because the clips live in the app's shared container.
final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardView>?
    private let state = KeyboardState()
    private var clipboardTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        state.insert = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        state.deleteBackward = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        state.nextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        let host = UIHostingController(rootView: KeyboardView(state: state))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 268),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        state.hasFullAccess = hasFullAccess
        state.needsGlobe = needsInputModeSwitchKey
        state.load()
        state.captureClipboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Something copied while the keyboard is up (e.g. long-press › Copy) is saved within a second.
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.captureClipboard() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        state.needsGlobe = needsInputModeSwitchKey
    }
}

