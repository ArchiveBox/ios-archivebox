import ArchiveBoxCore
import Foundation
import Observation
import UserNotifications
import UniformTypeIdentifiers

@MainActor @Observable
final class ShareModel {
    enum State: Equatable { case loading, ready, sending, sent(Int), removed, failed(String) }
    var state: State = .loading
    var urls: [URL] = []
    var configuration: ServerConfiguration?
    var tags: [String] = []
    var tagDraft = ""
    var tagError: String?
    var isSavingTags = false
    var recentTags: [String] = []
    var isRemoving = false
    var removalError: String?
    private var savedTags: [String] = []
    private var receipt: SubmissionReceipt?
    @ObservationIgnored private var tagOperation: Task<Void, Never>?

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
            recentTags = ArchiveTags.recentlyUsed(server: configuration.server)
            state = .ready
            await submit()
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
            receipt = try await ArchiveBoxClient().submit(urls: urls, configuration: configuration)
            state = .sent(urls.count)
            if isRemoving { await removeSubmission(); return }
            saveTags()
            // Notify only after server acceptance. A notification failure must not
            // turn a successful POST into a retryable submission error.
            let center = UNUserNotificationCenter.current()
            let permission = await center.notificationSettings().authorizationStatus
            if (permission == .authorized || permission == .provisional), case .sent = state, !isRemoving {
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
            isRemoving = false
            state = .failed("\(error.localizedDescription)\n\nSubmission could not be confirmed. Check your server before sharing again.")
        }
    }

    func addTags(suggestion: String? = nil) {
        let input = suggestion.map { Array(tagDraft.components(separatedBy: CharacterSet(charactersIn: ",\n")).dropLast()) + [$0] } ?? [tagDraft]
        tags = ArchiveTags.normalize(tags + input)
        tagDraft = ""
        saveTags()
    }

    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        saveTags()
    }

    func saveTags() {
        guard let receipt, let configuration, tagOperation == nil, !isRemoving else { return }
        tagError = nil
        guard tags != savedTags else { return }
        isSavingTags = true
        // One writer coalesces edits and serializes PATCHes. Cancelling an older
        // request cannot undo its server-side write and could overwrite newer tags.
        tagOperation = Task {
            try? await Task.sleep(for: .milliseconds(350))
            while tags != savedTags && !isRemoving {
                let pending = tags
                do {
                    try await ArchiveBoxClient().updateTags(pending, for: receipt, configuration: configuration)
                    let added = pending.filter { tag in !savedTags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }
                    recentTags = ArchiveTags.recentlyUsed(server: configuration.server, adding: added)
                    savedTags = pending
                } catch {
                    tagError = error.localizedDescription
                    break
                }
            }
            isSavingTags = false
            tagOperation = nil
        }
    }

    func finish() async -> Bool {
        guard case .sent = state, !isRemoving else { return false }
        addTags()
        await tagOperation?.value
        return tagError == nil && tags == savedTags
    }

    var suggestedTags: [String] {
        let query = tagDraft.components(separatedBy: CharacterSet(charactersIn: ",\n")).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let domain = urls.first.flatMap(ArchiveTags.domainTag).map { [$0] } ?? []
        return ArchiveTags.normalize(recentTags + domain + ["⭐️"]).filter { candidate in
            !tags.contains { $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame }
                && (query.isEmpty || candidate.localizedCaseInsensitiveContains(query))
        }
    }

    func removeSubmission() async {
        isRemoving = true
        removalError = nil
        // A cancelled HTTP request can still create a crawl. Wait for its receipt
        // and then explicitly remove that crawl instead of pretending it was undone.
        guard let receipt, let configuration else { return }
        await tagOperation?.value
        do {
            try await ArchiveBoxClient().removeSubmission(receipt, configuration: configuration)
            state = .removed
        } catch {
            removalError = error.localizedDescription
        }
        isRemoving = false
    }
}
