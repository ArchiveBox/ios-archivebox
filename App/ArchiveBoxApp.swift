import SwiftUI

@main
struct ArchiveBoxApp: App {
    @State private var settings = SettingsModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup { MainView(settings: settings) }
        .defaultSize(width: 800, height: 760)
        .windowResizability(.contentMinSize)
        Settings { SettingsView(model: settings).frame(width: 560, height: 720) }
        #else
        WindowGroup { MainView(settings: settings) }
        #endif
    }
}
