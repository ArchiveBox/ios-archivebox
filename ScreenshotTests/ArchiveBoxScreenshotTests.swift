import XCTest

/// Captures the shipping app through the real system UI test runner.
@MainActor
final class ArchiveBoxScreenshotTests: XCTestCase {
    func testLaunchScreenshot() throws {
        continueAfterFailure = false
        let interruption = addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            #if os(macOS)
            allow.click()
            #else
            allow.tap()
            #endif
            return true
        }
        defer { removeUIInterruptionMonitor(interruption) }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 20), app.debugDescription)
        // A normal app interaction lets XCTest handle a system permission interruption.
        #if os(macOS)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), app.debugDescription)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).click()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        #endif
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
    func testAllScreens() throws {
        continueAfterFailure = false
        let interruption = addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            #if os(macOS)
            allow.click()
            #else
            allow.tap()
            #endif
            return true
        }
        defer { removeUIInterruptionMonitor(interruption) }
        #if os(iOS)
        let passwordInterruption = addUIInterruptionMonitor(withDescription: "Decline saving the disposable API key") { alert in
            guard alert.staticTexts["Save Password?"].exists, alert.buttons["Not Now"].exists else { return false }
            alert.buttons["Not Now"].tap()
            return true
        }
        defer { removeUIInterruptionMonitor(passwordInterruption) }
        #endif
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_TOKEN"])
        XCTAssertFalse(server.isEmpty)
        XCTAssertFalse(token.isEmpty)
        let app = XCUIApplication()
        app.launch()
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
        XCTAssertTrue(app.staticTexts["Server connected"].waitForExistence(timeout: 20), app.debugDescription)
        replace(app.secureTextFields["apiKey"], with: token)
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        let save = app.buttons["saveConnection"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 20)
        press(save)
        capture("connection-connected", app: app)
        showSidebar(app)
        capture("sidebar", app: app)

        let screens: [(String, String)] = [
            ("add", "Create a new Crawl"), ("agent", "New session"),
            ("crawls", "Add Crawl"), ("schedules", "Add Scheduled Crawl"),
            ("snapshots", "Example Domain"), ("results", "Add Archive Result"),
            ("tags", "All tags"), ("admin", "Recent Actions"),
            ("users", "Add user"), ("personas", "Add persona"),
            ("keys", "Add API Key"), ("webhooks", "Add API Outbound Webhook"),
            ("processes", "Add process"), ("machines", "Add machine"),
            ("interfaces", "Add network interface"), ("binaries", "Add binary"),
            ("plugins", "Installed plugins"), ("workers", "worker processes"), ("logs", "Debug Log files")
        ]
        for (id, marker) in screens {
            openScreen(id, app: app)
            if id == "agent" {
                let start = app.webViews.buttons["Start using Agent"]
                XCTAssertTrue(start.waitForExistence(timeout: 30), app.debugDescription)
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
        XCTAssertTrue(app.staticTexts["More ways to add"].exists, app.debugDescription)
        capture("add-guide", app: app)
        press(persona)
        let choice = app.descendants(matching: .any)["Research Browser"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), app.debugDescription)
        capture("persona-picker", app: app)
        press(choice)
        let safari = app.buttons["Safari"]
        reveal(safari, named: "Safari", app: app)
        press(safari)
        let setup = app.alerts["Enable ArchiveBox in Safari"]
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
        let about = app.windows.containing(.any, identifier: "ArchiveBox Documentation").firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(about.descendants(matching: .any).matching(credits).firstMatch.exists, app.debugDescription)
        let aboutAttachment = XCTAttachment(screenshot: about.screenshot())
        aboutAttachment.name = "about"
        aboutAttachment.lifetime = .keepAlways
        add(aboutAttachment)
        press(about.buttons[XCUIIdentifierCloseWindow])
        #else
        try captureShareScreens(server: server)
        #endif
    }

    #if os(macOS)
    /// Run separately after testAllScreens has configured the real saved connection.
    /// Failure means the standard host UI needs inspection, never a synthetic extension host.
    func testMacShareScreens() throws {
        continueAfterFailure = false
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.Safari")
        safari.launch()
        safari.typeKey("l", modifierFlags: .command)
        safari.typeText(server + "/?native-gallery-share=\(UUID().uuidString)\n")
        let page = safari.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), safari.debugDescription)
        let share = safari.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), safari.debugDescription)
        press(share)
        let extensionItem = safari.menuItems["ArchiveBox"]
        XCTAssertTrue(extensionItem.waitForExistence(timeout: 5), safari.debugDescription)
        press(extensionItem)
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
        let confirmation = safari.popovers.buttons["Remove from server"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), safari.debugDescription)
        press(confirmation)
        XCTAssertTrue(safari.staticTexts["Removed from server"].waitForExistence(timeout: 15), safari.debugDescription)
        capture("share-removed", app: safari)
        press(safari.buttons["Done"])
    }
    #endif

    private func press(_ element: XCUIElement) {
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
        press(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText(value)
    }

    private func showSidebar(_ app: XCUIApplication) {
        #if os(iOS)
        declinePasswordPrompt()
        let sidebar = app.collectionViews.containing(.button, identifier: "sidebar.add").firstMatch
        if !sidebar.isHittable {
            let back = app.navigationBars.buttons.firstMatch
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
        #if os(macOS)
        let list = app.outlines.firstMatch
        for _ in 0..<6 where !item.isHittable { list.scroll(byDeltaX: 0, deltaY: 450) }
        for _ in 0..<10 where !item.isHittable { list.scroll(byDeltaX: 0, deltaY: -450) }
        #else
        let surface = app.collectionViews.containing(.button, identifier: "sidebar.add").firstMatch
        // Scroll the actual sidebar surface in both compact and regular split views.
        for _ in 0..<6 where !item.isHittable {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        for _ in 0..<10 where !item.isHittable {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        #endif
        XCTAssertTrue(item.isEnabled, app.debugDescription)
        press(item)
    }

    private func reveal(_ element: XCUIElement, named name: String, app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable {
            #if os(macOS)
            app.scrollViews.containing(.any, identifier: name).firstMatch.scroll(byDeltaX: 0, deltaY: -350)
            #else
            app.swipeUp()
            #endif
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func assertPage(_ marker: String, app: XCUIApplication) {
        #if os(macOS)
        // WebKit uses AXValue for text and numbers; normalize its type before string matching.
        let predicate = NSPredicate(format: "CAST(value, 'NSString') CONTAINS[c] %@", marker)
        #else
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", marker)
        #endif
        let content = app.webViews.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "Expected rendered page: \(marker)\n\(app.debugDescription)")
        XCTAssertFalse(app.webViews.secureTextFields.firstMatch.exists, "Unexpected login page")
    }

    #if os(iOS)
    private func declinePasswordPrompt() {
        let alert = XCUIApplication().alerts["Save Password?"]
        if alert.exists {
            let notNow = alert.buttons["Not Now"]
            XCTAssertTrue(notNow.isHittable, "The Save Password prompt must offer Not Now")
            notNow.tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: alert)
            waitForExpectations(timeout: 5)
        }
        XCTAssertFalse(alert.exists, "The disposable API key must not be saved to Passwords")
    }
    #endif

    private func capture(_ name: String, app: XCUIApplication) {
        #if os(iOS)
        declinePasswordPrompt()
        #endif
        #if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    #if os(iOS)
    private func captureShareScreens(server: String) throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let address = safari.textFields["Address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), safari.debugDescription)
        press(address)
        address.typeText(server + "/?native-gallery-share=\(UUID().uuidString)\n")
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
        press(safari.sheets.buttons["Remove from server"])
        XCTAssertTrue(safari.staticTexts["Removed from server"].waitForExistence(timeout: 15), safari.debugDescription)
        capture("share-removed", app: safari)
        press(safari.buttons["Done"])
    }
    #endif
}
