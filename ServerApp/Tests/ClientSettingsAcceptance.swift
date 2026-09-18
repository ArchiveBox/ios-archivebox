import AppKit
import ArchiveBoxCore
import Foundation

// Uses the existing local connection and real shared Keychain; never prints keys.
@main struct ClientSettingsAcceptance {
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            let settings = SettingsModel()
            guard settings.connectionMode == .local else { throw ArchiveBoxError.message("Select the local profile before checking its saved connection") }
            settings.load()
            let deadline = Date().addingTimeInterval(15)
            while settings.verifiedToken == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard settings.verifiedServer == ServerAddress.localAPI, settings.verifiedToken != nil,
                  let saved = try AppEnvironment.configurationStore(account: "profile-local").load(),
                  saved.server == ServerAddress.localAPI,
                  saved.token == settings.verifiedToken else { throw ArchiveBoxError.message("Local profile did not restore and verify its saved localhost key") }
            settings.useConnectionLink(saved.server, apiKey: saved.token)
            guard settings.connectionMode == .local else { throw ArchiveBoxError.message("A local companion handoff selected the remote profile") }
            let handoffDeadline = Date().addingTimeInterval(15)
            while settings.verifiedToken == nil && Date() < handoffDeadline { try await Task.sleep(for: .milliseconds(100)) }
            guard settings.verifiedToken == saved.token else { throw ArchiveBoxError.message("Companion handoff did not verify its administrator key") }
            print("PASS: real SettingsModel restored and verified the localhost key; saved to the local profile and active connection")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
