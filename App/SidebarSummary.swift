import SwiftUI
import ArchiveBoxCore

struct SidebarSummary: View {
    let settings: SettingsModel
    let authentication: BrowserAuthentication
    let sidebarVisible: Bool
    let openActivity: () -> Void
    @State private var hoveringActivity = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var appeared = false
    private var progress: SidebarProgress? { settings.sidebarStatus?.progress }
    private var latency: Int? { settings.sidebarStatus?.latency }
    private var connected: Bool? { failure != nil || !settings.serverReachable ? false : settings.sidebarStatus != nil ? true : initialConnection }
    @State private var initialConnection: Bool?
    @State private var failure: String?
    @State private var loginKey = ""
    @State private var lastRequest = Date.distantPast

    private var credentials: String {
        "\(settings.verifiedServer?.absoluteString ?? "")\n\(settings.verifiedToken ?? "")"
    }
    private var polling: Bool {
        #if os(macOS)
        appeared && sidebarVisible && scenePhase == .active && controlActiveState != .inactive
        #else
        appeared && sidebarVisible && scenePhase == .active
        #endif
    }

    var body: some View {
        Button(action: openActivity) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").frame(width: 16, alignment: .leading)
                    Text(progress.map { "\($0.crawls_active) active crawls" } ?? "Activity unavailable")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(hoveringActivity ? Color.accentColor : Color.primary)
                if let crawl = progress?.active_crawls.sorted(by: {
                    if ($0.status == "started") != ($1.status == "started") { return $0.status == "started" }
                    return ($0.started ?? "") > ($1.started ?? "")
                }).first {
                    Text(crawl.label).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).padding(.leading, 22)
                }
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").frame(width: 16, alignment: .leading)
                    Text(progress?.collection.map {
                        "\($0.snapshots) snapshots · \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))"
                    } ?? "Collection size unavailable")
                }
                HStack(spacing: 6) {
                    Circle().fill(connected == nil ? Color.secondary : connected == true ? .green : .red).frame(width: 7, height: 7).padding(.leading, 3).frame(width: 16, alignment: .leading)
                    Text(connected == nil ? "Not checked" : connected == true ? "Connected" : "Unavailable")
                    Spacer(minLength: 0)
                    if let latency { Text("\(latency) ms").foregroundStyle(.secondary) }
                }
            }
            .font(.caption).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color("SidebarStatusBackground").ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) {
                Rectangle().fill(.primary.opacity(0.12)).frame(height: 2)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityIdentifier("sidebar.summary")
        }
        .buttonStyle(.plain)
        .disabled(settings.verifiedServer == nil)
        .onHover { hoveringActivity = $0 }
        .help(failure ?? "Open live progress. Updates every five seconds while this sidebar is active. Collection size is based on stored archive files.")
        .accessibilityHint("Open live progress")
        .accessibilityIdentifier("sidebar.openActivity")
        .onAppear { appeared = true }.onDisappear { appeared = false }
        .task(id: "\(polling)-\(credentials)") {
            if loginKey != credentials {
                initialConnection = nil; failure = nil
                loginKey = credentials
            }
            guard polling, let server = settings.verifiedServer else { return }
            // A single cancellable loop avoids overlapping requests. Keep the last
            // request time across focus changes so toggling windows cannot burst-poll.
            while !Task.isCancelled {
                do {
                    let delay = max(0, 5 - Date().timeIntervalSince(lastRequest))
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    lastRequest = Date()
                    // Use the same in-memory session as the embedded pages, bound
                    // to this verified server/key pair. Credentials never follow redirects.
                    guard let token = settings.verifiedToken else {
                        throw ArchiveBoxError.message("Add an API key to see collection activity.")
                    }
                    let start = ContinuousClock.now
                    let value = try await authentication.sidebarProgress(server: server, token: token)
                    try Task.checkCancellation()
                    let elapsed = start.duration(to: .now).components
                    settings.sidebarStatus = (value, Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
                    initialConnection = true; failure = nil
                } catch {
                    // Losing focus can suspend networking before task cancellation
                    // arrives. Keep the last valid sample until an active refresh succeeds.
                    guard !Task.isCancelled, polling else { return }
                    initialConnection = false
                    failure = settings.sidebarStatus == nil ? error.localizedDescription
                        : "Showing the last successful status. Refresh failed: \(error.localizedDescription)"
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
