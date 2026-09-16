import ArchiveBoxCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private var operation: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        let host = UIHostingController(rootView: ShareView(model: model, finish: { [weak self] in
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
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        operation = Task {
            do {
                var links: [URL] = []
                for item in items {
                    for provider in item.attachments ?? [] {
                        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                            links += try await Self.loadLinks(provider, type: UTType.url.identifier)
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                            links += try await Self.loadLinks(provider, type: UTType.plainText.identifier)
                        }
                    }
                    if let text = item.attributedContentText?.string { links += SharedLinks.extract(from: text) }
                }
                try Task.checkCancellation()
                model.urls = SharedLinks.unique(links.filter(SharedLinks.isWebURL))
                guard !model.urls.isEmpty else { throw ArchiveBoxError.message("This item doesn’t contain a web link. Share a URL from your browser or another app.") }
                guard let configuration = try AppEnvironment.store.load() else {
                    throw ArchiveBoxError.message("Open the ArchiveBox app first to test and save your server and API key, then share this link again.")
                }
                model.configuration = configuration
                model.state = .ready
            } catch {
                if !Task.isCancelled { model.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// Convert provider values inside the callback, so non-Sendable NSItemProvider payloads
    /// never cross the concurrency boundary. Host apps use both URL and string representations.
    private static func loadLinks(_ provider: NSItemProvider, type: String) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = item as? URL { continuation.resume(returning: [url]); return }
                if let text = item as? String { continuation.resume(returning: SharedLinks.extract(from: text)); return }
                if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: SharedLinks.extract(from: text)); return
                }
                continuation.resume(returning: [])
            }
        }
    }
}

@MainActor @Observable
final class ShareModel {
    enum State: Equatable { case loading, ready, sending, sent(Int), failed(String) }
    var state: State = .loading
    var urls: [URL] = []
    var configuration: ServerConfiguration?

    func submit() async {
        guard let configuration, state == .ready else { return }
        state = .sending
        do {
            _ = try await ArchiveBoxClient().submit(urls: urls, configuration: configuration)
            state = .sent(urls.count)
        } catch {
            // Deliberately no automatic retry: a timed-out POST might already have been accepted.
            state = .failed("\(error.localizedDescription)\n\nSubmission could not be confirmed. Check your server before sharing again.")
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    let finish: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Reading shared link…")
                case .sent(let count):
                    ContentUnavailableView {
                        Label("Sent to ArchiveBox", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text(count == 1 ? "Your server accepted the link for archiving." : "Your server accepted \(count) links for archiving.")
                    } actions: {
                        Button("Done", action: finish).buttonStyle(.glassProminent)
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t save link", systemImage: "exclamationmark.circle")
                    } description: { Text(message) } actions: {
                        Button("Close", action: finish).buttonStyle(.glass)
                    }
                case .ready, .sending:
                    Form {
                        Section("Link\(model.urls.count == 1 ? "" : "s")") {
                            ForEach(model.urls, id: \.absoluteString) { url in
                                Text(url.absoluteString).textSelection(.enabled)
                            }
                        }
                        Section("Save to") {
                            Label(model.configuration?.server.absoluteString ?? "ArchiveBox", systemImage: "server.rack")
                        }
                        Section {
                            if model.state == .sending { ProgressView("Sending to your server…") }
                            else {
                                Button { Task { await model.submit() } } label: {
                                    Label("Save to ArchiveBox", systemImage: "archivebox")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent).controlSize(.large)
                                .accessibilityIdentifier("submitShare")
                            }
                        } footer: { Text("Keep this sheet open until your server confirms.") }
                    }
                }
            }
            .navigationTitle("ArchiveBox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.state == .ready || model.state == .loading {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: finish) }
                }
            }
            .interactiveDismissDisabled(model.state == .sending)
        }
        .tint(Color("AccentColor"))
    }
}
