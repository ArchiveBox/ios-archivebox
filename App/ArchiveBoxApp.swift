import SwiftUI

@main
struct ArchiveBoxApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup { SettingsView() }
        .defaultSize(width: 560, height: 720)
        .windowResizability(.contentMinSize)
        Settings { SettingsView().frame(width: 560, height: 720) }
        #else
        WindowGroup { SettingsView() }
        #endif
    }
}
