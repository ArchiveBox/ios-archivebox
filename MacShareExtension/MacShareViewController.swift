import AppKit
import SwiftUI

@MainActor
final class MacShareViewController: NSViewController {
    private var operation: Task<Void, Never>?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 460))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 480, height: 460)
        let model = ShareModel()
        let host = NSHostingController(rootView: ShareView(model: model, finish: { [weak self] in
            self?.operation?.cancel()
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        operation = Task { await model.load(items: items) }
    }
}
