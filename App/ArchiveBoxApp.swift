import SwiftUI

@main
struct ArchiveBoxApp: App {
    @State private var settings = SettingsModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup { MainView(settings: settings) }
        .defaultSize(width: 800, height: 760)
        .windowResizability(.contentMinSize)
        Settings { MainView(settings: settings).frame(width: 800, height: 760) }
        #else
        WindowGroup { MainView(settings: settings) }
        #endif
    }
}
