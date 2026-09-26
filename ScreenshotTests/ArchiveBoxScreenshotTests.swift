import XCTest
#if os(iOS)
import UIKit
#endif

/// Captures the shipping app through the real system UI test runner.
@MainActor
final class ArchiveBoxScreenshotTests: XCTestCase {
    private var application: XCUIApplication {
        #if os(macOS)
        if let path = ProcessInfo.processInfo.environment["ARCHIVEBOX_MAC_APP"] {
            return XCUIApplication(url: URL(fileURLWithPath: path))
        }
        return XCUIApplication()
        #else
        return XCUIApplication(bundleIdentifier: "io.archivebox.ArchiveBox")
        #endif
    }

    func testLaunchScreenshot() throws {
        continueAfterFailure = false
        let interruption = addUIInterruptionMonitor(withDescription: "ArchiveBox system permissions") { [self] alert in
            approvePermission(alert)
        }
        defer { removeUIInterruptionMonitor(interruption) }
        let app = application
        app.launch()
        let skip = app.buttons["setup.skip"]
        if skip.waitForExistence(timeout: 2) { press(skip) }
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 20), app.debugDescription)
        // A normal app interaction lets XCTest handle a system permission interruption.
        #if os(macOS)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), app.debugDescription)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).click()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        #endif
        resolveSystemPermissions()
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.textFields["serverURL"].isHittable, app.debugDescription)
        #if os(macOS)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = "connection-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    /// Product tour using the shipping onboarding, saved connection and real backend.
    /// The exhaustive testAllScreens remains available separately.
    func testGalleryScreens() throws {
        continueAfterFailure = false
        let interruption = addUIInterruptionMonitor(withDescription: "ArchiveBox system permissions") { [self] alert in
            approvePermission(alert)
        }
        defer { removeUIInterruptionMonitor(interruption) }
        #if os(iOS)
        // Passwords can raise this sheet after a sidebar button passes the
        // normal hittability check; handle the interrupted tap as in the full tour.
        let passwordInterruption = addUIInterruptionMonitor(withDescription: "Decline saving the disposable API key") { [self] alert in
            guard alert.staticTexts["Save Password?"].exists, alert.buttons["Not Now"].exists else { return false }
            declinePasswordPrompt()
            return true
        }
        defer { removeUIInterruptionMonitor(passwordInterruption) }
        #endif
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_TOKEN"])
        let app = application
        app.launch()
        XCTAssertTrue(app.buttons["setup.choose"].waitForExistence(timeout: 20), "Use a fresh capture runner")
        capture("onboarding", app: app)
        press(app.buttons["setup.choose"])
        XCTAssertTrue(app.buttons["setup.mac"].waitForExistence(timeout: 5))
        capture("setup-choices", app: app)
        press(app.buttons["setup.mac"])
        XCTAssertTrue(app.buttons["setup.connect"].waitForExistence(timeout: 5))
        capture("setup-mac", app: app)
        press(app.buttons["setup.back"])
        press(app.buttons["setup.docker"])
        capture("setup-docker", app: app)
        press(app.buttons["setup.connect"])
        let field = app.textFields["serverURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        capture("connection-disconnected", app: app)
        replace(field, with: server)
        #if os(iOS)
        // Drag the form content down to dismiss the URL keyboard before locating the key field.
        let formStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let formEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.61))
        formStart.press(forDuration: 0.05, thenDragTo: formEnd)
        #endif
        waitForConnectionFormReady(app)
        enterAPIKey(token, after: field, in: app)
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        press(app.buttons["saveConnection"])
        XCTAssertTrue(app.staticTexts["Testing connection…"].waitForNonExistence(timeout: 20), app.debugDescription)
        capture("connection-connected", app: app)
        #if os(iOS)
        let snapshotMarkerType = XCUIElement.ElementType.link
        let pageTextType = XCUIElement.ElementType.staticText
        // The real screenshot collection creates two crawls. Check its stable
        // page heading instead of a count that changes with the collection.
        let crawlsMarker = "Crawls"
        #else
        // macOS WebKit exposes the card title through its text value, not a Link.
        let snapshotMarkerType = XCUIElement.ElementType.any
        let pageTextType = XCUIElement.ElementType.any
        let crawlsMarker = "Crawls"
        #endif
        for (id, marker, type) in [("add", "Create a new Crawl", pageTextType),
                                   ("snapshots", "Example Domain", snapshotMarkerType),
                                   ("crawls", crawlsMarker, pageTextType)] {
            openScreen(id, app: app)
            assertPage(marker, app: app, type: type)
            capture(id, app: app)
        }
        openScreen("agent", app: app)
        let start = app.webViews.buttons["Start using Agent"]
        XCTAssertTrue(start.waitForExistence(timeout: 30), app.debugDescription)
        scrollTo(start, app: app)
        Thread.sleep(forTimeInterval: 10)
        capture("agent-welcome", app: app)
        press(start)
        assertPage("New session", app: app, type: pageTextType)
        capture("agent", app: app)
        openScreen("openActivity", app: app)
        assertPage("Downloads", app: app, type: pageTextType)
        capture("activity", app: app)
        openScreen("settings", app: app)
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 20), app.debugDescription)
        #if os(macOS)
        // Saving the connection moves this real server into remembered history.
        // Wait for that row to expand the form before measuring where to scroll.
        let remembered = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.server.")).firstMatch
        XCTAssertTrue(remembered.waitForExistence(timeout: 20), app.debugDescription)
        #endif
        let guide = app.buttons["network.guide"]
        scrollTo(guide, app: app)
        press(guide)
        XCTAssertTrue(app.buttons["network.discover"].waitForExistence(timeout: 10), app.debugDescription)
        capture("tailscale", app: app)
        press(app.buttons["Done"])
        let discover = app.buttons["network.discover"]
        scrollTo(discover, app: app)
        press(discover)
        XCTAssertTrue(app.buttons["discovery.search"].waitForExistence(timeout: 10), app.debugDescription)
        capture("discovery", app: app)
    }

    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { break }
            #if os(macOS)
            if element.identifier.isEmpty {
                // The Agent page has its own scroll area below the status panel.
                // Scroll over the visible page content, not the outer WebView's
                // midpoint (which lands in the fixed status panel).
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.73))
                    .scroll(byDeltaX: 0, deltaY: -280)
            } else {
                let pane = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
                XCTAssertTrue(pane.exists, "Missing scroll pane for \(element.identifier)")
                pane.scroll(byDeltaX: 0, deltaY: -280)
            }
            #else
            app.swipeUp()
            #endif
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    func testAllScreens() throws {
        continueAfterFailure = false
        let interruption = addUIInterruptionMonitor(withDescription: "ArchiveBox system permissions") { [self] alert in
            approvePermission(alert)
        }
        defer { removeUIInterruptionMonitor(interruption) }
        #if os(iOS)
        let passwordInterruption = addUIInterruptionMonitor(withDescription: "Decline saving the disposable API key") { [self] alert in
            guard alert.staticTexts["Save Password?"].exists, alert.buttons["Not Now"].exists else { return false }
            declinePasswordPrompt()
            return true
        }
        defer { removeUIInterruptionMonitor(passwordInterruption) }
        #endif
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_TOKEN"])
        XCTAssertFalse(server.isEmpty)
        XCTAssertFalse(token.isEmpty)
        let app = application
        app.launch()
        let skip = app.buttons["setup.skip"]
        if skip.waitForExistence(timeout: 2) { press(skip) }
        let field = app.textFields["serverURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        #if os(macOS)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).click()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        #endif
        XCTAssertTrue(app.staticTexts["Server not connected"].exists, "Capture requires a fresh disposable simulator/runner")
        capture("connection-disconnected", app: app)
        replace(field, with: server)
        #if os(iOS)
        let formStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let formEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.61))
        formStart.press(forDuration: 0.05, thenDragTo: formEnd)
        #endif
        waitForConnectionFormReady(app)
        enterAPIKey(token, after: field, in: app)
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        let save = app.buttons["saveConnection"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 20)
        press(save)
        XCTAssertTrue(app.staticTexts["Testing connection…"].waitForNonExistence(timeout: 20), app.debugDescription)
        capture("connection-connected", app: app)
        showSidebar(app)
        capture("sidebar", app: app)

        let screens: [(String, String)] = [
            ("add", "Create a new Crawl"), ("agent", "New session"),
            ("crawls", "Crawls"), ("schedules", "Search Scheduled Crawls"),
            ("snapshots", "Example Domain"), ("results", "Search Archive Results"),
            ("tags", "All tags"), ("admin", "Recent Actions"),
            ("users", "Search users"), ("personas", "Search personas"),
            ("keys", "Search API Keys"), ("webhooks", "Search API Outbound Webhooks"),
            ("processes", "Search Processes"), ("machines", "Search machines"),
            ("interfaces", "Search network interfaces"), ("binaries", "Search Binaries"),
            ("plugins", "Hooks"), ("workers", "Exit Status"), ("logs", "Most Recent Lines")
        ]
        for (id, marker) in screens {
            openScreen(id, app: app)
            if id == "agent" {
                let start = app.webViews.buttons["Start using Agent"]
                XCTAssertTrue(start.waitForExistence(timeout: 30), app.debugDescription)
                scrollTo(start, app: app)
                Thread.sleep(forTimeInterval: 10)
                capture("agent-welcome", app: app)
                press(start)
            }
            assertPage(marker, app: app)

            capture(id, app: app)
        }
        openScreen("openActivity", app: app)
        assertPage("Downloads", app: app)
        capture("activity", app: app)

        openScreen("add", app: app)
        let persona = app.descendants(matching: .any)["defaultPersona"].firstMatch
        reveal(persona, named: "defaultPersona", app: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR CAST(value, 'NSString') == %@", "More ways to add", "More ways to add")).firstMatch.exists, app.debugDescription)
        capture("add-guide", app: app)
        press(persona)
        let choice = app.descendants(matching: .any)["Research Browser"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), app.debugDescription)
        capture("persona-picker", app: app)
        press(choice)
        let safari = app.buttons["Safari"]
        reveal(safari, named: "Safari", app: app)
        press(safari)
        #if os(macOS)
        let setup = app.sheets.containing(NSPredicate(format: "CAST(value, 'NSString') == %@", "Enable ArchiveBox in Safari")).firstMatch
        #else
        let setup = app.alerts["Enable ArchiveBox in Safari"]
        #endif
        XCTAssertTrue(setup.waitForExistence(timeout: 5), app.debugDescription)
        capture("safari-setup", app: app)
        press(setup.buttons["Cancel"])

        #if os(macOS)
        openScreen("settings", app: app)
        let local = app.radioButtons["Run Server Locally"]
        XCTAssertTrue(local.waitForExistence(timeout: 5), app.debugDescription)
        press(local)
        XCTAssertTrue(app.buttons["Download ArchiveBox Server.app…"].waitForExistence(timeout: 10), app.debugDescription)
        capture("connection-local", app: app)
        press(app.radioButtons["Connect to remote server"])
        press(app.menuBars.menuBarItems["ArchiveBox"])
        press(app.menuItems["About ArchiveBox"])
        let credits = NSPredicate(format: "label CONTAINS %@ OR CAST(value, 'NSString') CONTAINS %@",
            "Save URLs from your apps and browsers to ArchiveBox", "Save URLs from your apps and browsers to ArchiveBox")
        let about = app.dialogs.containing(credits).firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(about.descendants(matching: .any).matching(credits).firstMatch.exists, app.debugDescription)
        let aboutAttachment = XCTAttachment(screenshot: about.screenshot())
        aboutAttachment.name = "about"
        aboutAttachment.lifetime = .keepAlways
        add(aboutAttachment)
        press(about.buttons[XCUIIdentifierCloseWindow])
        captureMacShareScreens(app: app)
        #else
        captureShareScreens()
        #endif
    }

    #if os(macOS)
    /// Exercise Safari's standard Share menu with the connection configured above.
    private func captureMacShareScreens(app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.Safari")
        safari.launch()
        safari.typeKey("l", modifierFlags: .command)
        safari.typeText("https://example.com/?native-gallery-share=\(UUID().uuidString)\n")
        assertPage("Example Domain", app: safari)
        let share = safari.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), safari.debugDescription)
        press(share)
        let picker = share.popovers.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), safari.debugDescription)
        // Safari first presents a spinner while its remote sharing service loads.
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: picker.activityIndicators.firstMatch)
        waitForExpectations(timeout: 10)
        let sharePickerDescription = safari.debugDescription
        let sharePickerHierarchy = XCTAttachment(string: sharePickerDescription)
        sharePickerHierarchy.name = "share-picker-hierarchy"
        sharePickerHierarchy.lifetime = .keepAlways
        add(sharePickerHierarchy)
        print(sharePickerDescription)
        let shareSheet = XCUIApplication(url: URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/ShareKit.framework/Versions/A/PlugIns/ShareSheetUI.appex"))
        guard shareSheet.wait(for: .runningBackground, timeout: 5) else {
            XCTFail("Safari's sharing service did not start.\n\(safari.debugDescription)")
            return
        }
        let shareSheetDescription = shareSheet.debugDescription
        let shareSheetHierarchy = XCTAttachment(string: shareSheetDescription)
        shareSheetHierarchy.name = "share-service-hierarchy"
        shareSheetHierarchy.lifetime = .keepAlways
        add(shareSheetHierarchy)
        print(shareSheetDescription)
        let sharePickerScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sharePickerScreenshot.name = "share-picker-diagnostic"
        sharePickerScreenshot.lifetime = .keepAlways
        add(sharePickerScreenshot)
        // The remote sharing service exposes its controls in Safari's popover.
        capture("share-picker", app: safari)
        let extensionItem = picker.buttons["ArchiveBox"]
        if !extensionItem.exists {
            press(picker.buttons["Edit Extensions…"])
            let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10), safari.debugDescription)
            let description = settings.debugDescription
            let hierarchy = XCTAttachment(string: description)
            hierarchy.name = "share-extension-settings-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            print(description)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "share-extension-settings-diagnostic"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("ArchiveBox is absent from Safari's Share picker; inspect the actual extension settings UI.")
            return
        }
        XCTAssertTrue(extensionItem.waitForExistence(timeout: 5), safari.debugDescription)
        press(extensionItem)
        XCTAssertTrue(safari.staticTexts["Submitted to ArchiveBox Server"].waitForExistence(timeout: 30),
            "Safari:\n\(safari.debugDescription)\nShareSheetUI:\n\(shareSheet.debugDescription)")
        capture("share-accepted", app: safari)
        let tags = safari.textFields["shareTagInput"]
        press(tags)
        tags.typeText("read later, research\n")
        XCTAssertTrue(safari.staticTexts["Tags saved"].waitForExistence(timeout: 15), safari.debugDescription)
        XCTAssertTrue(safari.buttons["Remove tag research"].exists, safari.debugDescription)
        capture("share-tags", app: safari)
        press(safari.buttons["Remove from server"])
        XCTAssertTrue(safari.buttons["Keep it"].waitForExistence(timeout: 5), safari.debugDescription)
        capture("share-removal-confirmation", app: safari)
        let confirmation = safari.popovers.buttons["Remove from server"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), safari.debugDescription)
        press(confirmation)
        XCTAssertTrue(safari.staticTexts["Removed from server"].waitForExistence(timeout: 15), safari.debugDescription)
        capture("share-removed", app: safari)
        press(safari.buttons["Done"])
    }
    #endif

    /// The local-network prompt belongs to the system, not app.alerts. XCTest's
    /// default monitor does not recognize the macOS 27 "Allow … to find" wording.
    private func approvePermission(_ alert: XCUIElement) -> Bool {
        // debugDescription truncates AXValue, including the permission's name.
        let text = alert.staticTexts.allElementsBoundByIndex.map {
            $0.label + " " + ($0.value as? String ?? "")
        }.joined(separator: " ").lowercased()
        guard text.contains("archivebox"),
              text.contains("local network") || text.contains("notifications") else { return false }
        let allow = alert.buttons["Allow"]
        guard allow.exists else { return false }
        #if os(macOS)
        allow.click()
        #else
        allow.tap()
        #endif
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: alert)
        waitForExpectations(timeout: 5)
        return true
    }

    private func resolveSystemPermissions() {
        #if os(macOS)
        let system = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        // On a fresh runner the system process starts only when a prompt appears.
        guard system.state != .notRunning else { return }
        for dialog in system.dialogs.allElementsBoundByIndex {
            _ = approvePermission(dialog)
        }
        // Fail instead of publishing an overlay, including an unfamiliar prompt.
        XCTAssertFalse(system.dialogs.firstMatch.exists, system.debugDescription)
        #endif
    }

    private func press(_ element: XCUIElement) {
        resolveSystemPermissions()
        #if os(iOS)
        if !element.isHittable { declinePasswordPrompt() }
        #endif
        XCTAssertTrue(element.isHittable, element.debugDescription)
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func replace(_ field: XCUIElement, with value: String) {
        scrollTo(field, app: application)
        let current = field.value as? String
        let isEmpty = current == "" || (field.placeholderValue != nil && current == field.placeholderValue)
        press(field)
        if !isEmpty {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        field.typeText(value)
    }

    private func waitForConnectionFormReady(_ app: XCUIApplication) {
        // Enter the API key before waiting for an authenticated connection.
        // Without the key, the connection screen correctly shows the server as
        // disconnected even when its OpenAPI endpoint is reachable.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.secureTextFields["apiKey"].exists
                && !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
    }

    private func enterAPIKey(_ token: String, after serverField: XCUIElement, in app: XCUIApplication) {
        #if os(macOS)
        // The URL field remains focused after editing. Navigate as a keyboard
        // user: macOS 27 can expose the visible SecureField to AX yet report
        // its enclosing SwiftUI ScrollView as the hit target for every point.
        serverField.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        app.typeText(token)
        #else
        replace(app.secureTextFields["apiKey"], with: token)
        #endif
    }

    private func showSidebar(_ app: XCUIApplication) {
        #if os(iOS)
        declinePasswordPrompt()
        let sidebar = app.collectionViews["sidebar"]
        if !sidebar.isHittable {
            let back = app.buttons["navigation.sidebar"].exists ? app.buttons["navigation.sidebar"] : app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.exists, app.debugDescription)
            press(back)
            expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: sidebar)
            waitForExpectations(timeout: 5)
        }
        #endif
    }

    private func openScreen(_ id: String, app: XCUIApplication) {
        showSidebar(app)
        let item = app.buttons["sidebar." + id]
        if id == "openActivity" {
            // The activity summary is a fixed footer outside the scrollable list.
            press(item)
            return
        }
        #if os(macOS)
        let list = app.outlines.firstMatch
        for _ in 0..<6 {
            if item.isHittable { break }
            list.scroll(byDeltaX: 0, deltaY: 450)
        }
        for _ in 0..<10 {
            if item.isHittable { break }
            list.scroll(byDeltaX: 0, deltaY: -450)
        }
        #else
        let surface = app.collectionViews["sidebar"]
        let visibleTop = app.staticTexts["ArchiveBox"].frame.maxY
        let visibleBottom = app.buttons["sidebar.openActivity"].frame.minY
        let visible = {
            guard item.exists, item.isHittable else { return false }
            let frame = item.frame
            return frame.minY >= visibleTop && frame.maxY <= visibleBottom
        }
        // Scroll the actual sidebar surface in both compact and regular split views.
        for _ in 0..<6 {
            if visible() { break }
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        for _ in 0..<10 {
            if visible() { break }
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        XCTAssertTrue(visible(), "Sidebar item is outside the visible list: \(item.debugDescription)")
        #endif
        XCTAssertTrue(item.isEnabled, app.debugDescription)
        #if os(iOS)
        // The section header's accessibility frame spans the row; its clickable label does not.
        let tapTarget = id == "admin" ? item.staticTexts["Admin"] : item
        press(tapTarget)
        // The Passwords sheet can arrive while XCTest synthesizes this tap. If it
        // intercepted navigation, dismiss it and finish the same user action.
        let passwordService = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        if passwordService.state != .notRunning && passwordService.staticTexts["Save Password?"].exists {
            declinePasswordPrompt()
            if surface.isHittable {
                XCTAssertTrue(visible(), "Password sheet interrupted sidebar navigation: \(item.debugDescription)")
                press(tapTarget)
            }
        }
        #else
        press(item)
        #endif
    }

    private func reveal(_ element: XCUIElement, named name: String, app: XCUIApplication) {
        for _ in 0..<10 {
            if element.isHittable { break }
            #if os(macOS)
            // Wheel over visible native content, outside WebKit and the auto-hidden scrollbar.
            let anchor = name == "defaultPersona"
                ? app.staticTexts.matching(NSPredicate(format: "CAST(value, 'NSString') == %@", "More ways to add")).firstMatch
                : app.staticTexts.matching(NSPredicate(format: "CAST(value, 'NSString') == %@", "Default persona")).firstMatch
            XCTAssertTrue(anchor.isHittable, app.debugDescription)
            anchor.scroll(byDeltaX: 0, deltaY: -250)
            #else
            let outer = app.scrollViews.containing(.any, identifier: name).firstMatch
            // Begin below the embedded page's 80%-height viewport, in native guide content.
            outer.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.93)).press(forDuration: 0.05,
                thenDragTo: outer.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
            #endif
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func assertPage(_ marker: String, app: XCUIApplication, type: XCUIElement.ElementType = .any) {
        resolveSystemPermissions()
        // Buttons expose labels while macOS text exposes AXValue. Select a
        // visible matching element, not an offscreen accessibility group.
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR CAST(value, 'NSString') CONTAINS[c] %@", marker, marker)
        let content = app.webViews.descendants(matching: type).matching(predicate)
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        #if os(iOS)
        let passwordService = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let passwordPrompt = passwordService.staticTexts["Save Password?"]
        #endif
        let rendered = NSPredicate { _, _ in
            #if os(iOS)
            // Observe the system prompt here; XCTest UI actions must run outside
            // the expectation's predicate evaluation.
            return content.firstMatch.exists || (passwordService.state != .notRunning && passwordPrompt.exists)
            #else
            return content.firstMatch.exists
            #endif
        }
        expectation(for: rendered, evaluatedWith: app)
        waitForExpectations(timeout: 30)
        #if os(iOS)
        if passwordService.state != .notRunning && passwordPrompt.exists {
            declinePasswordPrompt(dismissalTimeout: min(5, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        #endif
        if !content.firstMatch.exists {
            expectation(for: NSPredicate { _, _ in content.firstMatch.exists }, evaluatedWith: app)
            waitForExpectations(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        }
        XCTAssertTrue(content.firstMatch.exists, "Expected rendered page: \(marker)\n\(app.debugDescription)")
        #if os(iOS)
        declinePasswordPrompt()
        #else
        // The snapshot grid can sit below the live progress panel. Scroll the
        // page a user would scroll before requiring its existing row to be visible.
        for _ in 0..<8 {
            if content.allElementsBoundByIndex.contains(where: { $0.isHittable }) { break }
            app.webViews.firstMatch.scroll(byDeltaX: 0, deltaY: -280)
        }
        #endif
        expectation(for: NSPredicate { _, _ in
            content.allElementsBoundByIndex.contains { $0.isHittable }
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.webViews.secureTextFields.firstMatch.exists, "Unexpected login page")
        // Allow the embedded page to finish painting before its gallery capture.
        Thread.sleep(forTimeInterval: 10)
    }

    #if os(iOS)
    private func declinePasswordPrompt(dismissalTimeout: TimeInterval = 5) {
        // The sheet appears in ArchiveBox's tree, but SafariViewService owns
        // its controls. Query that process while the WebView is navigating.
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let servicePrompt = service.staticTexts["Save Password?"]
        if service.state != .notRunning && servicePrompt.exists {
            let notNow = service.buttons["Not Now"]
            XCTAssertTrue(notNow.isHittable, "The Save Password prompt must offer Not Now")
            // XCTest activates SafariViewService before tapping its AX button;
            // that activation can invalidate the hit point even while the
            // system sheet remains on screen. Tap its visible screen position.
            let button = notNow.frame
            let screen = application.frame
            let center = CGPoint(x: button.midX, y: button.midY)
            XCTAssertTrue(screen.contains(center), "Not Now must be visible on the iPhone screen")
            application.coordinate(withNormalizedOffset: CGVector(
                dx: (center.x - screen.minX) / screen.width,
                dy: (center.y - screen.minY) / screen.height
            )).tap()
            XCTAssertTrue(servicePrompt.waitForNonExistence(timeout: dismissalTimeout), "The disposable API key must not be saved to Passwords")
        }
        XCTAssertTrue(service.state == .notRunning || !servicePrompt.exists, "The disposable API key must not be saved to Passwords")
    }
    #endif

    private func capture(_ name: String, app: XCUIApplication) {
        resolveSystemPermissions()
        #if os(iOS)
        declinePasswordPrompt()
        #endif
        #if os(macOS)
        XCTAssertEqual(app.state, .runningForeground, "Cannot capture \(name): another app covers the target window")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        // A full-page WKWebView can make XCUIApplication's accessibility
        // snapshot time out even though the simulator has rendered the screen.
        // Capture the visible device display directly for reliable gallery
        // images, as the share-flow captures already do below.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    #if os(iOS)
    private func captureShareScreens() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let address = safari.textFields["Address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), safari.debugDescription)
        press(address)
        address.typeText("https://example.com/?native-gallery-share=\(UUID().uuidString)\n")
        assertPage("Example Domain", app: safari)
        let share = safari.buttons["Share"]
        if !share.exists { press(safari.buttons["Page Menu"]) }
        XCTAssertTrue(share.waitForExistence(timeout: 15), safari.debugDescription)
        press(share)
        let more = safari.cells["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), safari.debugDescription)
        press(more)
        let archiveBox = safari.tables.staticTexts["ArchiveBox"]
        XCTAssertTrue(archiveBox.waitForExistence(timeout: 5), safari.debugDescription)
        press(archiveBox)
        XCTAssertTrue(safari.staticTexts["Submitted to ArchiveBox Server"].waitForExistence(timeout: 30), safari.debugDescription)
        capture("share-accepted", app: safari)
        let tags = safari.textFields["shareTagInput"]
        press(tags)
        tags.typeText("read later, research\n")
        XCTAssertTrue(safari.staticTexts["Tags saved"].waitForExistence(timeout: 15), safari.debugDescription)
        XCTAssertTrue(safari.buttons["Remove tag research"].exists, safari.debugDescription)
        capture("share-tags", app: safari)
        press(safari.buttons["Remove from server"])
        XCTAssertTrue(safari.buttons["Keep it"].waitForExistence(timeout: 5), safari.debugDescription)
        capture("share-removal-confirmation", app: safari)
        let confirmation = UIDevice.current.userInterfaceIdiom == .pad
            ? safari.popovers.buttons["Remove from server"]
            : safari.sheets.buttons["Remove from server"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), safari.debugDescription)
        press(confirmation)
        XCTAssertTrue(safari.staticTexts["Removed from server"].waitForExistence(timeout: 15), safari.debugDescription)
        capture("share-removed", app: safari)
        press(safari.buttons["Done"])
    }
    #endif
}
