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
            ("tags", "Add Tag"), ("admin", "Recent Actions"),
            ("users", "Add user"), ("personas", "Add persona"),
            ("keys", "Add API Key"), ("webhooks", "Add API Outbound Webhook"),
            ("processes", "Add process"), ("machines", "Add machine"),
            ("interfaces", "Add network interface"), ("binaries", "Add binary"),
            ("plugins", "Installed plugins"), ("workers", "worker processes"), ("logs", "Debug Log files")
        ]
        for (id, marker) in screens {
            openScreen(id, app: app)
            assertPage(marker, app: app)
            capture(id, app: app)
        }
        showSidebar(app)
        press(app.buttons["sidebar.openActivity"])
        assertPage("Recent Actions", app: app)
        capture("activity", app: app)

        openScreen("add", app: app)
        let persona = app.descendants(matching: .any)["defaultPersona"].firstMatch
        reveal(persona, app: app)
        XCTAssertTrue(app.staticTexts["More ways to add"].exists, app.debugDescription)
        capture("add-guide", app: app)
        press(persona)
        let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "AppleAcceptance")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), app.debugDescription)
        capture("persona-picker", app: app)
        press(choice)
        let safari = app.buttons["Safari"]
        reveal(safari, app: app)
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
        XCTAssertTrue(app.staticTexts["ArchiveBox"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        capture("about", app: app)
        #else
        try captureShareScreens(server: server)
        #endif
    }

    private func press(_ element: XCUIElement) {
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
        if !app.buttons["sidebar.openActivity"].isHittable {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.exists, app.debugDescription)
            press(back)
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
        let surface = app
        // Keep the gesture inside the sidebar on iPad, rather than scrolling its detail webview.
        for _ in 0..<6 where !item.isHittable {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.3)).press(forDuration: 0.05,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.8)))
        }
        for _ in 0..<10 where !item.isHittable {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.8)).press(forDuration: 0.05,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.3)))
        }
        #endif
        XCTAssertTrue(item.isEnabled, app.debugDescription)
        press(item)
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable {
            #if os(macOS)
            app.scrollViews.element(boundBy: app.scrollViews.count - 1).scroll(byDeltaX: 0, deltaY: -350)
            #else
            app.swipeUp()
            #endif
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func assertPage(_ marker: String, app: XCUIApplication) {
        let content = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "Expected rendered page: \(marker)\n\(app.debugDescription)")
        XCTAssertFalse(app.webViews.secureTextFields.firstMatch.exists, "Unexpected login page")
    }

    private func capture(_ name: String, app: XCUIApplication) {
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
