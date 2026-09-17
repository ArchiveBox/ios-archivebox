import SwiftUI
import UserNotifications
#if os(macOS)
import ArchiveBoxCore
#endif

@main
struct ArchiveBoxApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ArchiveBoxServices.self) private var services
    #endif
    @State private var settings = SettingsModel()
    @State private var settingsNavigationID = UUID()

    var body: some Scene {
        #if os(macOS)
        // A Window scene has one identity; openWindow focuses it instead of creating another.
        Window("ArchiveBox", id: "main") {
            MainView(settings: settings, settingsNavigationID: settingsNavigationID)
                .task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
        }
        .defaultSize(width: 800, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                OpenConnectionSettings(navigationID: $settingsNavigationID)
            }
        }
        #else
        WindowGroup {
            MainView(settings: settings)
                // Share extensions use the containing app’s notification permission.
                .task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
        }
        #endif
    }
}

#if os(macOS)
private struct OpenConnectionSettings: View {
    @Environment(\.openWindow) private var openWindow
    @Binding var navigationID: UUID

    var body: some View {
        Button("Settings…") {
            navigationID = UUID()
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
#endif

#if os(macOS)
@MainActor
final class ArchiveBoxServices: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    @objc func addURLToArchiveBox(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL]) ?? []
        if let text = pasteboard.string(forType: .string) { urls += SharedLinks.extract(from: text) }
        // Selected rich-text links may expose only a label as plain text.
        if let data = pasteboard.data(forType: .rtf),
           let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let url = value as? URL { urls.append(url) }
                else if let value = value as? String { urls += SharedLinks.extract(from: value) }
            }
        }
        let links = SharedLinks.unique(urls.filter(SharedLinks.isWebURL))
        guard !links.isEmpty else {
            error.pointee = "Select an http:// or https:// URL, then choose Add URL to ArchiveBox."
            return
        }
        // Return to the host immediately; neither networking nor feedback should
        // activate ArchiveBox or interrupt the app where the URL was selected.
        Task {
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(options: [.alert])) ?? false
            let content = UNMutableNotificationContent()
            do {
                guard let configuration = try AppEnvironment.store.load() else {
                    throw ArchiveBoxError.message("Open ArchiveBox Connection Settings and configure a server and API key first.")
                }
                _ = try await ArchiveBoxClient().submit(urls: links, configuration: configuration)
                content.title = "Added to ArchiveBox"
                content.body = links.count == 1 ? links[0].absoluteString : "Submitted \(links.count) URLs."
            } catch {
                content.title = "Couldn’t confirm submission"
                content.body = error.localizedDescription + " Check your server before retrying."
            }
            // Respect disabled notifications; never fall back to a modal dialog.
            if allowed {
                do {
                    try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                } catch {
                    NSLog("ArchiveBox Service notification failed: %@", error.localizedDescription)
                }
            }
        }
    }
}
#endif
