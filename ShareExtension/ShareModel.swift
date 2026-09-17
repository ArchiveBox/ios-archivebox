import ArchiveBoxCore
import Foundation
import Observation
import UserNotifications
import UniformTypeIdentifiers

@MainActor @Observable
final class ShareModel {
    enum State: Equatable { case loading, ready, sending, sent(Int), failed(String) }
    var state: State = .loading
    var urls: [URL] = []
    var configuration: ServerConfiguration?

    func load(items: [NSExtensionItem]) async {
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
            urls = SharedLinks.unique(links.filter(SharedLinks.isWebURL))
            guard !urls.isEmpty else { throw ArchiveBoxError.message("This item doesn’t contain a web link. Share a URL from your browser or another app.") }
            guard let configuration = try AppEnvironment.store.load() else {
                throw ArchiveBoxError.message("Open the ArchiveBox app first to test and save your server and API key, then share this link again.")
            }
            self.configuration = configuration
            state = .ready
        } catch {
            if !Task.isCancelled { state = .failed(error.localizedDescription) }
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

    func submit() async {
        guard let configuration, state == .ready else { return }
        state = .sending
        do {
            _ = try await ArchiveBoxClient().submit(urls: urls, configuration: configuration)
            state = .sent(urls.count)
            // Notify only after server acceptance. A notification failure must not
            // turn a successful POST into a retryable submission error.
            let center = UNUserNotificationCenter.current()
            let permission = await center.notificationSettings().authorizationStatus
            if permission == .authorized || permission == .provisional {
                let content = UNMutableNotificationContent()
                content.title = "Added to ArchiveBox"
                content.body = urls.count == 1 ? "Your server queued \(urls[0].absoluteString)" : "Your server queued \(urls.count) URLs for archiving."
                do {
                    try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                } catch {
                    NSLog("ArchiveBox share notification failed: %@", error.localizedDescription)
                }
            }
        } catch {
            // Deliberately no automatic retry: a timed-out POST might already have been accepted.
            state = .failed("\(error.localizedDescription)\n\nSubmission could not be confirmed. Check your server before sharing again.")
        }
    }
}

