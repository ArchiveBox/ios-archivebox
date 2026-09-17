import XCTest

/// Run against a real, disposable ArchiveBox 0.9+ server. No intercepted requests or seeded app state.
@MainActor
final class ArchiveBoxUITests: XCTestCase {
    func testSafariButtonOpensExtensionSettings() throws {
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        let app = XCUIApplication()
        app.launch()
        openScreen("Add URLs", app: app)
        let safari = app.buttons["Safari"]
        for _ in 0..<8 where !safari.isHittable { app.swipeUp() }
        XCTAssertTrue(safari.isHittable, app.debugDescription)
        safari.tap()
        let instructions = app.alerts["Enable ArchiveBox in Safari"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        XCTAssertTrue(instructions.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Settings → Apps → Safari → Extensions → ArchiveBox")).firstMatch.exists)
        instructions.buttons["OK"].tap()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10), app.debugDescription)
        XCTAssertTrue(settings.navigationBars["ArchiveBox"].waitForExistence(timeout: 10), settings.debugDescription)
        XCTAssertTrue(settings.switches.firstMatch.exists, settings.debugDescription)
        attach("ArchiveBox Safari extension settings", app: settings)
    }

    func testVerifiedKeyPersistsWithoutSave() throws {
        continueAfterFailure = false
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_TOKEN"])
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["serverURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replace(field, with: server)
        XCTAssertTrue(app.staticTexts["Server connected"].waitForExistence(timeout: 20))
        replace(app.secureTextFields["apiKey"], with: token)
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        // Never tap Save: verification itself must durably store the key.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.secureTextFields["apiKey"].waitForExistence(timeout: 10))
        let restored = app.secureTextFields["apiKey"].value as? String ?? ""
        XCTAssertFalse(restored.isEmpty || restored == "••••••••••••••••")
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
    }

    func testAutomaticConnectionAndScreens() throws {
        continueAfterFailure = false
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["serverURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replace(field, with: "http://127.0.0.1:1")
        XCTAssertTrue(app.staticTexts["Server unreachable"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["openAdmin"].isEnabled)
        XCTAssertFalse(app.buttons["getAPIKey"].isEnabled)
        replace(field, with: server + "/admin/")
        XCTAssertTrue(app.staticTexts["Server connected"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["openAdmin"].isEnabled)
        XCTAssertTrue(app.buttons["getAPIKey"].isEnabled)
        replace(app.secureTextFields["apiKey"], with: "invalid-test-key")
        XCTAssertTrue(app.staticTexts["API key rejected"].waitForExistence(timeout: 20))
        app.secureTextFields["apiKey"].typeText("\n")
        app.buttons["getAPIKey"].tap()
        XCTAssertTrue(app.navigationBars["Admin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        openScreen("Add URLs", app: app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["More ways to add"].waitForExistence(timeout: 5))
        attach("Add URLs guide", app: app)
        openScreen("Snapshots", app: app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        openScreen("Admin", app: app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
    }

    func testShareSheetGuide() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let address = safari.textFields["Address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("https://example.com\n")
        let share = safari.buttons["Share"]
        if !share.exists { safari.buttons["Page Menu"].tap() }
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let more = safari.cells["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        XCTAssertTrue(safari.tables.staticTexts["ArchiveBox"].waitForExistence(timeout: 10))
        attach("Share sheet guide", app: safari)
    }

    func testConfigureAndShareFromSafari() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let server = try XCTUnwrap(environment["ARCHIVEBOX_TEST_SERVER"])
        let token = try XCTUnwrap(environment["ARCHIVEBOX_TEST_TOKEN"])
        XCTAssertFalse(server.isEmpty)
        XCTAssertFalse(token.isEmpty)
        let app = XCUIApplication()
        app.launch()
        let serverField = app.textFields["serverURL"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        replace(serverField, with: server + "/admin/api/apitoken/")
        let key = app.secureTextFields["apiKey"]
        replace(key, with: "invalid-test-key")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "invalid or expired")).firstMatch.waitForExistence(timeout: 20))
        replace(key, with: token)
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["saveConnection"].tap()
        openScreen("Add URLs", app: app)
        let picker = app.buttons["defaultPersona"]
        app.swipeUp()
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        picker.tap()
        app.buttons["AppleAcceptance"].tap()
        openScreen("Connection Settings", app: app)
        XCTAssertTrue(app.buttons["saveConnection"].isEnabled, app.debugDescription)
        app.buttons["saveConnection"].tap()
        app.swipeUp()
        XCTAssertTrue(app.otherElements["savedConnection"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ready to share.")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        attach("Configured", app: app)
        app.terminate()
        app.launch()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.launch()
        // Safari's own address field and system sharing UI exercise the real extension host.
        let address = safari.textFields["Address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), safari.debugDescription)
        address.tap()
        address.typeText("https://example.com/?archivebox-ios-acceptance=\(UUID().uuidString)\n")
        let share = safari.buttons["Share"]
        if !share.exists {
            let pageMenu = safari.buttons["Page Menu"]
            XCTAssertTrue(pageMenu.waitForExistence(timeout: 10), safari.debugDescription)
            pageMenu.tap()
        }
        XCTAssertTrue(share.waitForExistence(timeout: 15), safari.debugDescription)
        share.tap()
        // The Apps list avoids an off-screen horizontal share cell and makes the
        // extension selection unambiguous while the system sheet is animating.
        let more = safari.cells["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), safari.debugDescription)
        more.tap()
        XCTAssertTrue(safari.navigationBars["Apps"].waitForExistence(timeout: 5), safari.debugDescription)
        let archiveBox = safari.tables.staticTexts["ArchiveBox"]
        XCTAssertTrue(archiveBox.waitForExistence(timeout: 5), safari.debugDescription)
        archiveBox.tap()
        let tags = safari.textFields["shareTagInput"]
        XCTAssertTrue(tags.waitForExistence(timeout: 10), safari.debugDescription)
        XCTAssertTrue(safari.staticTexts["AppleAcceptance"].exists, safari.debugDescription)
        attach("Share preview", app: safari)
        // Choosing ArchiveBox starts submission, without a second Save action.
        XCTAssertTrue(safari.staticTexts["Sent to ArchiveBox"].waitForExistence(timeout: 30), safari.debugDescription)
        tags.tap()
        tags.typeText("share-ui, read later\n")
        XCTAssertTrue(safari.staticTexts["Tags saved"].waitForExistence(timeout: 15), safari.debugDescription)
        safari.buttons["Remove tag share-ui"].tap()
        XCTAssertTrue(safari.staticTexts["Tags saved"].waitForExistence(timeout: 15), safari.debugDescription)
        attach("Share accepted", app: safari)
        safari.buttons["Done"].tap()
    }

    func testArchiveRequiresConnection() throws {
        continueAfterFailure = false
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let app = XCUIApplication()
        app.launch()
        let settings = app.navigationBars["Connection Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(settings.exists)
        replace(app.textFields["serverURL"], with: "http://127.0.0.1:1")
        XCTAssertFalse(app.webViews.firstMatch.exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["sidebar.snapshots"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sidebar.snapshots"].isEnabled)
        openScreen("Connection Settings", app: app)
        XCTAssertTrue(settings.exists)
        replace(app.textFields["serverURL"], with: server)
        XCTAssertTrue(app.staticTexts["Server connected"].waitForExistence(timeout: 20))
        openScreen("Snapshots", app: app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.webViews.textFields.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let username = app.webViews.textFields.firstMatch
        username.tap()
        username.typeText("ios-test")
        username.typeText("\n")
        openScreen("Connection Settings", app: app)
        openScreen("Snapshots", app: app)
        XCTAssertEqual(username.value as? String, "ios-test")
        attach("Archive admin login", app: app)
        openScreen("Connection Settings", app: app)
        XCTAssertTrue(app.textFields["serverURL"].exists)
        replace(app.textFields["serverURL"], with: server + "/admin/")
        XCTAssertFalse(app.webViews.firstMatch.exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["sidebar.snapshots"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sidebar.snapshots"].isEnabled)
        openScreen("Connection Settings", app: app)
        XCTAssertTrue(settings.exists)
    }

    func testSidebarReselectionResetsOnlyCurrentPage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        // Run on a simulator configured through the app's normal connection UI.
        openScreen("Connection Settings", app: app)
        XCTAssertTrue(app.staticTexts["Server connected"].waitForExistence(timeout: 20), app.debugDescription)
        openScreen("Snapshots", app: app)
        let field = app.webViews.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        let initialValue = field.value as? String
        field.tap()
        field.typeText("repeat-click-probe")
        openScreen("Add URLs", app: app)
        openScreen("Snapshots", app: app)
        XCTAssertEqual(field.value as? String, "repeat-click-probe")
        // Reopen the collapsed sidebar and tap the already selected destination.
        openScreen("Snapshots", app: app)
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        let reset = NSPredicate { _, _ in (field.value as? String) == initialValue }
        expectation(for: reset, evaluatedWith: field)
        waitForExpectations(timeout: 10)
        field.tap()
        field.typeText("after-reset")
        openScreen("Add URLs", app: app)
        openScreen("Snapshots", app: app)
        XCTAssertEqual(field.value as? String, "after-reset")
    }

    func testWebviewsAuthenticateAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for _ in 0..<2 {
            app.launch()
            openScreen("Connection Settings", app: app)
            XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 25), app.debugDescription)
            openScreen("Snapshots", app: app)
            XCTAssertTrue(app.navigationBars["Snapshots"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.webViews.textFields.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
            // The compact header intentionally hides Logout. Verify a protected
            // administrator capability instead of depending on hidden chrome.
            openScreen("Users", app: app)
            XCTAssertTrue(app.webViews.links.matching(NSPredicate(format: "label ==[c] 'Add user'")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertFalse(app.webViews.secureTextFields.firstMatch.exists)
            XCTAssertLessThan(app.navigationBars.firstMatch.frame.height, 65)
            openScreen("AI Agent", app: app)
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'New session'")).firstMatch.waitForExistence(timeout: 45), app.debugDescription)
            attach("Authenticated AI Agent", app: app)
            app.terminate()
        }
    }

    private func openScreen(_ name: String, app: XCUIApplication) {
        let identifiers = ["Add URLs": "add", "AI Agent": "agent", "Snapshots": "snapshots", "Admin": "admin", "Users": "users", "Connection Settings": "settings"]
        let item = app.buttons["sidebar." + identifiers[name]!]
        if !item.isHittable {
            let back = app.navigationBars.buttons.firstMatch
            if back.exists { back.tap() }
        }
        // The connected app starts on its menu; returning from a detail keeps
        // the sidebar's scroll position. Search from the top in either case.
        for _ in 0..<5 where !item.isHittable { app.swipeDown() }
        for _ in 0..<8 where !item.isHittable { app.swipeUp() }
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(item.isHittable, app.debugDescription)
        XCTAssertTrue(item.isEnabled, app.debugDescription)
        item.tap()
    }

    private func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        // Select-all through the keyboard rather than injecting settings or Keychain state.
        field.typeKey("a", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText(value)
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
