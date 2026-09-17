import AppKit
import ArchiveBoxCore

extension AppDelegate: NSMenuItemValidation {
    func configureNativeMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "ArchiveBox Server")
        appMenu.addItem(withTitle: "About ArchiveBox Server", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        // Make the shutdown consequence explicit wherever Quit appears.
        appMenu.addItem(withTitle: "Shut Down Server & Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Add New URLs…", action: #selector(addURLInBrowser), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Open Data Folder", action: #selector(openData), keyEquivalent: "").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = NSMenu(title: "View")
        for (index, screen) in Screen.allCases.enumerated() {
            let action: Selector = switch screen {
            case .archive: #selector(showArchive)
            case .activity: #selector(showActivity)
            case .shell: #selector(showShell)
            case .users: #selector(showUsers)
            case .settings: #selector(showSettings)
            }
            view.addItem(withTitle: screen.rawValue, action: action, keyEquivalent: String(index + 1)).target = self
        }
        for (title, action, key) in [("Back", #selector(goBack), "["), ("Reload", #selector(reload), "r"),
                                     ("Open Data Folder", #selector(openData), "")] {
            view.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        for link in AppInformation.links {
            let item = help.addItem(withTitle: link.title, action: #selector(openHelpLink(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = link.url
        }
        NSApp.helpMenu = help
        for submenu in [appMenu, file, edit, view, window, help] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        NSApp.mainMenu = menu
    }

    @objc func showAbout() { AppInformation.showAbout(server: true) }
    @objc func openHelpLink(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(addURLInBrowser): return settings?.ready == true && settings?.hasAdmin == true
        case #selector(showArchive), #selector(showActivity), #selector(showUsers): return settings?.hasAdmin == true
        case #selector(showShell): return screens.contains(.shell)
        case #selector(goBack): return selectedScreen == .archive && web?.canGoBack == true
        case #selector(reload): return selectedScreen == .archive || selectedScreen == .activity
        default: return true
        }
    }
}
