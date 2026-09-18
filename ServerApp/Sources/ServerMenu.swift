import AppKit

extension AppDelegate {
    func configureServerMenu() {
        // A standard NSMenu gets the system's material, spacing and accessibility
        // behavior; SF Symbols adapt to the user's appearance and contrast settings.
        let menu = NSMenu()
        menu.autoenablesItems = false; menu.delegate = self
        menuStatus.isEnabled = false; menuMetrics.isEnabled = false
        menu.addItem(menuStatus); menu.addItem(menuMetrics); menu.addItem(.separator())
        for (title, symbol, action) in [
            ("Add URL…", "plus", #selector(addURLInBrowser)),
            ("Open ArchiveBox", "archivebox", #selector(openArchiveBoxClient)),
            ("Admin", "person.crop.circle", #selector(adminInBrowser))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        pauseItem = NSMenuItem(title: "Pause Archiving", action: #selector(toggleArchiving), keyEquivalent: "")
        pauseItem.target = self; menu.addItem(pauseItem)
        menu.addItem(.separator())
        let preferences = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        preferences.target = self
        preferences.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(preferences)
        let quit = NSMenuItem(title: "Shut Down Server & Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Shut down")
        menu.addItem(quit)
        // macOS 27 hides menu images by default. Resolve its public setter at runtime
        // so releases built with the stable macOS 26 SDK still show icons on macOS 27.
        for item in menu.items where item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
            item.setValue(1, forKey: "preferredImageVisibility") // NSMenuItem.ImageVisibility.visible
        }
        menuBarItem.menu = menu
        renderServerMenu()
    }

    func renderServerMenu() {
        let running = settings.healthy
        let reason = settings.restarting ? "Restarting…" : settings.detail.isEmpty ? settings.state : settings.detail
        menuStatus.title = settings.starting || settings.restarting ? "🟠 Starting: \(String(settings.detail.prefix(90)))" : running ? "🟢 Running: port \(runtime.address.port!)" : "🔴 Unavailable: \(String(reason.prefix(90)))"
        menuStatus.toolTip = reason
        let metrics = NSMutableAttributedString()
        for (index, entry) in [("arrow.down.circle", running ? (crawlActivity.map { String($0.downloads) } ?? "—") : "—"),
                               ("cpu", running ? settings.cpu : "—"), ("memorychip", running ? settings.ram : "—")].enumerated() {
            if index > 0 { metrics.append(NSAttributedString(string: "   –   ")) }
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: entry.0, accessibilityDescription: nil)
            attachment.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
            metrics.append(NSAttributedString(attachment: attachment))
            metrics.append(NSAttributedString(string: " \(entry.1)"))
        }
        metrics.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: metrics.length))
        menuMetrics.attributedTitle = metrics
        menuMetrics.setAccessibilityLabel("Active downloads: \(running ? crawlActivity.map { String($0.downloads) } ?? "Unavailable" : "Unavailable"); CPU: \(running ? settings.cpu : "Unavailable"); memory: \(running ? settings.ram : "Unavailable")")
        menuMetrics.toolTip = menuError ?? "Active downloads · CPU (100% = one core) · container RAM. Refreshed on opening, at most once per 30 seconds."
        let resume = (crawlActivity?.paused ?? 0) > 0
        pauseItem.title = changingArchiving ? "Updating archiving…" : resume ? "Unpause Archiving" : "Pause Archiving"
        pauseItem.image = NSImage(systemSymbolName: resume ? "play" : "pause", accessibilityDescription: nil)
        pauseItem.isEnabled = running && !changingArchiving && menuRefresh == nil && !settings.managementBusy && crawlActivity != nil && menuError == nil
        for item in menuBarItem.menu?.items ?? [] where item.action == #selector(addURLInBrowser) || item.action == #selector(adminInBrowser) {
            item.isEnabled = running && (crawlActivity != nil || settings.serverDetails != nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        renderServerMenu()
        guard menuRefresh == nil, !changingArchiving, !settings.restarting,
              Date().timeIntervalSince(lastMenuRefresh) >= 30 else { return }
        lastMenuRefresh = Date()
        pauseItem.isEnabled = false
        // No background timer and no polling while the menu is closed. Existing
        // Settings samples provide CPU deltas, avoiding a second sampling loop.
        menuRefresh = Task {
            defer { menuRefresh = nil; renderServerMenu() }
            guard runtime.ownsService else { return }
            let sample = await Task.detached { [runtime] in runtime.sample() }.value
            settings.apply(sample)
            guard sample.state == "running" else { crawlActivity = nil; return }
            do {
                crawlActivity = try await Task.detached { [runtime] in try runtime.archiving() }.value
                menuError = nil
            } catch { menuError = error.localizedDescription; crawlActivity = nil }
        }
    }

    @objc func addURLInBrowser() {
        if let admin = settings.serverDetails?.admin ?? crawlActivity?.admin,
           let url = URL(string: "/add/", relativeTo: admin)?.absoluteURL { NSWorkspace.shared.open(url) }
    }
    @objc func adminInBrowser() { openClientOrBrowser(admin: true) }
    @objc func openArchiveBoxClient() { openClientOrBrowser(admin: false) }

    private func openClientOrBrowser(admin: Bool) {
        let workspace = NSWorkspace.shared
        // Prefer the installed copy over development builds registered with Launch Services.
        let installed = [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/ArchiveBox.app"),
                         URL(fileURLWithPath: "/Applications/ArchiveBox.app")]
        let app = installed.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? workspace.urlForApplication(withBundleIdentifier: "io.archivebox.ArchiveBox")
        if let app, FileManager.default.fileExists(atPath: app.path) {
            if admin {
                workspace.open([URL(string: "archivebox://admin")!], withApplicationAt: app,
                               configuration: NSWorkspace.OpenConfiguration())
            } else { workspace.open(app) }
        } else if let url = settings.serverDetails?.admin ?? crawlActivity?.admin {
            workspace.open(url)
        } else { workspace.open(runtime.address) }
    }
    @objc func toggleArchiving() {
        guard menuRefresh == nil, !changingArchiving, !settings.managementBusy, !settings.restarting, settings.ready else { return }
        let action = (crawlActivity?.paused ?? 0) > 0 ? "resume" : "pause"
        changingArchiving = true; settings.managementBusy = true; renderServerMenu()
        menuRefresh = Task {
            defer { settings.managementBusy = false; changingArchiving = false; menuRefresh = nil; lastMenuRefresh = Date(); renderServerMenu() }
            do {
                crawlActivity = try await Task.detached { [runtime] in try runtime.archiving(action: action) }.value
                menuError = nil
            } catch {
                menuError = error.localizedDescription
                settings.managementError = error.localizedDescription
                showSettings()
            }
        }
    }
}
