import SwiftUI
import Sparkle

// Sparkle owns checking, version comparison, signatures, download, installation
// and relaunch. This adapter only exposes its state to the Settings button.
@MainActor final class ServerUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var availableVersion: String?
    @Published var canCheck = false
    @Published var message: String?
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else {
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        do { try controller.updater.start() }
        catch { message = error.localizedDescription }
    }

    func check() {
        guard canCheck else { return }
        message = nil
        if availableVersion == nil { controller.updater.checkForUpdateInformation() }
        else { controller.checkForUpdates(nil) }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil; message = error.localizedDescription
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { message = error.localizedDescription }
}

struct ServerUpdateView: View {
    @StateObject private var updates = ServerUpdates()
    private let info = Bundle.main.infoDictionary ?? [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Link("archivebox/archivebox:dev", destination: URL(string: "https://hub.docker.com/r/archivebox/archivebox/tags?name=dev")!)
                    Text("v\(info["ArchiveBoxImageVersion"] as? String ?? "—") · Native Apple Virtualization · Linux \(info["ArchiveBoxKernelVersion"] as? String ?? "—")")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button(updates.availableVersion.map { "Install Newer Version v\($0)" } ?? "Check for Updates", systemImage: "arrow.clockwise") {
                        updates.check()
                    }.buttonStyle(.glass).disabled(!updates.canCheck)
                    if let date = info["ArchiveBoxImageCreated"] as? Date {
                        Text("Last updated \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = updates.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}
