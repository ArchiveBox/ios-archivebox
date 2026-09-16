import XCTest

/// Run against a real, disposable ArchiveBox 0.9+ server. No intercepted requests or seeded app state.
@MainActor
final class ArchiveBoxUITests: XCTestCase {
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
        app.buttons["testServer"].tap()
        let tokenButton = app.buttons["testAPIKey"]
        let key = app.secureTextFields["apiKey"]
        replace(key, with: "invalid-test-key")
        XCTAssertTrue(tokenButton.waitForExistence(timeout: 10))
        XCTAssertTrue(tokenButton.isEnabled)
        tokenButton.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "invalid or expired")).firstMatch.waitForExistence(timeout: 20))
        replace(key, with: token)
        tokenButton.tap()
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20))
        let picker = app.buttons["defaultPersona"]
        app.swipeUp()
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        picker.tap()
        app.buttons["AppleAcceptance"].tap()
        XCTAssertTrue(app.buttons["saveConnection"].isEnabled, app.debugDescription)
        app.buttons["saveConnection"].tap()
        app.swipeUp()
        XCTAssertTrue(app.otherElements["savedConnection"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ready to share.")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        attach("Configured", app: app)
        app.terminate()
        app.launch()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Your saved connection is ready for the share sheet."].waitForExistence(timeout: 5))

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
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
        let archiveBox = safari.cells["ArchiveBox"]
        if !archiveBox.exists {
            let more = safari.cells["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 5), safari.debugDescription)
            more.tap()
        }
        XCTAssertTrue(archiveBox.waitForExistence(timeout: 5), safari.debugDescription)
        archiveBox.tap()
        let submit = safari.buttons["submitShare"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10), safari.debugDescription)
        XCTAssertTrue(safari.staticTexts["AppleAcceptance"].exists, safari.debugDescription)
        attach("Share preview", app: safari)
        submit.tap()
        XCTAssertTrue(safari.staticTexts["Sent to ArchiveBox"].waitForExistence(timeout: 30), safari.debugDescription)
        attach("Share accepted", app: safari)
        safari.buttons["Done"].tap()
    }

    private func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        // Select-all through the keyboard rather than injecting settings or Keychain state.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String)?.count ?? 0))
        field.typeText(value)
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
