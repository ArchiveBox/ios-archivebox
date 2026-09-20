import AppIntents
import ArchiveBoxCore
import SwiftUI

struct ArchiveSearchView: View {
    @Bindable var settings: SettingsModel
    let initialQuery: String
    let open: (ArchiveBoxSearchResult) -> Void
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var results: [ArchiveBoxSearchResult] = []
    @State private var loading = false
    @State private var error: String?
    @State private var limit = 50
    @State private var refreshID = UUID()
    @State private var searchTask: Task<Void, Never>?

    private var configuration: ServerConfiguration? {
        guard let server = settings.verifiedServer, let token = settings.verifiedToken else { return nil }
        return ServerConfiguration(server: server, token: token, persona: settings.persona.isEmpty ? nil : settings.persona)
    }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("Try again") { refreshID = UUID() }
                }
            }
            ForEach(results) { page in
                Button { open(page) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(page.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(page.originalURL.absoluteString).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        if !page.tags.isEmpty {
                            Label(page.tags.joined(separator: ", "), systemImage: "tag")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("archive.result.\(page.snapshotID)")
                .appEntityIdentifier(EntityIdentifier(for: page))
                .draggable(page)
                .contextMenu {
                    Button("Open Archived Page", systemImage: "archivebox") { open(page) }
                    Link(destination: page.originalURL) { Label("Open Original", systemImage: "safari") }
                    ShareLink(item: page.originalURL) { Label("Share Original URL", systemImage: "square.and.arrow.up") }
                    ShareLink(item: page.archiveURL) { Label("Share Archive URL", systemImage: "archivebox") }
                    ShareLink(item: page.appURL) { Label("Share App Link", systemImage: "link") }
                }
            }
            if results.count == limit && limit < 500 {
                Button("Show more results") { limit = min(limit + 50, 500) }.disabled(loading)
            }
            if !results.isEmpty {
                Text("\(results.count) \(submittedQuery.isEmpty ? "recent" : "matching") pages\(results.count == 500 ? " · Refine your search to find more" : "")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("archive.search.results")
        .navigationTitle("Search Archive")
        .searchable(text: $query, prompt: "Title, URL, or tag")
        .onSubmit(of: .search) { submittedQuery = query; limit = 50; refreshID = UUID() }
        .onChange(of: query) { _, text in
            if text.isEmpty { submittedQuery = ""; limit = 50 }
        }
        .onChange(of: initialQuery, initial: true) { _, text in
            query = text; submittedQuery = text; limit = 50
        }
        .overlay {
            if loading && results.isEmpty { ProgressView("Searching your archive…") }
            else if configuration == nil {
                ContentUnavailableView("Connect your server", systemImage: "network", description: Text("Choose Connection Settings to search your collection."))
            } else if results.isEmpty && error == nil {
                ContentUnavailableView.search(text: submittedQuery)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .disabled(loading).accessibilityIdentifier("archive.search.refresh")
            }
        }
        .refreshable { refreshID = UUID() }
        .onChange(of: SearchRequest(configuration: configuration, query: submittedQuery, limit: limit, refreshID: refreshID), initial: true) {
            // Like PageSession, own the request across SwiftUI's transient
            // disappearances when the split view or search bar changes layout.
            searchTask?.cancel()
            searchTask = Task {
                results = []; error = nil
                guard let configuration else { loading = false; return }
                loading = true
                do {
                    let snapshots = try await ArchiveBoxClient().snapshots(query: submittedQuery, limit: limit, configuration: configuration)
                    try Task.checkCancellation()
                    results = snapshots.map { ArchiveBoxSearchResult(snapshot: $0, server: configuration.server) }
                    loading = false
                    do { try await ArchiveSystemIndex.update(results, configuration: configuration) }
                    catch { NSLog("ArchiveBox Spotlight indexing failed: %@", error.localizedDescription) }
                } catch {
                    guard !Task.isCancelled else { return }
                    loading = false
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private struct SearchRequest: Equatable {
        let configuration: ServerConfiguration?
        let query: String
        let limit: Int
        let refreshID: UUID
    }
}

struct ArchivedPageView: View {
    let page: ArchiveBoxSearchResult
    let session: PageSession
    var body: some View {
        ServerWebView(url: page.archiveURL, title: page.title, session: session)
            .navigationTitle(page.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Link(destination: page.originalURL) { Label("Open Original", systemImage: "safari") }
                    ShareLink(item: page.archiveURL) { Label("Share Archive URL", systemImage: "square.and.arrow.up") }
                }
            }
            .userActivity("io.archivebox.viewSnapshot") { activity in
                activity.title = page.title
                activity.userInfo = ["route": page.appURL.absoluteString]
                activity.requiredUserInfoKeys = ["route"]
                activity.webpageURL = page.archiveURL
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = false // IndexedEntity owns Spotlight.
                activity.isEligibleForPublicIndexing = false
                activity.targetContentIdentifier = page.id
                activity.appEntityIdentifier = EntityIdentifier(for: page)
            }
    }
}
