import XCTest

/// Drives the signed shipping companion on a fresh CI Mac. No injected app state.
@MainActor
final class ServerScreenshotTests: XCTestCase {
    func testGalleryScreens() throws {
        continueAfterFailure = false
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_SERVER_APP"])
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        capture("startup", app)
        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 300), app.debugDescription)
        capture("onboarding", app)
        username.click(); username.typeText("archivebox-gallery")
        let password = "ArchiveBox-\(UUID().uuidString)"
        app.secureTextFields["Password"].click(); app.secureTextFields["Password"].typeText(password)
        app.secureTextFields["Confirm password"].click(); app.secureTextFields["Confirm password"].typeText(password)
        capture("create-admin", app)
        app.buttons["Create superuser"].click()
        XCTAssertTrue(app.buttons["client.dismiss"].waitForExistence(timeout: 60), app.debugDescription)
        capture("client-setup", app)
        app.buttons["client.dismiss"].click()
        capture("network", app)
        let guide = app.buttons["network.guide"]
        reveal(guide, app)
        guide.click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
        capture("tailscale-guide", app)
        app.buttons["Done"].click()
        let https = app.radioButtons["HTTPS"]
        reveal(https, app); https.click()
        capture("https", app)
        // Explore the real certificate choices without applying network changes.
        let provider = app.popUpButtons["Certificate / HTTPS provider"]
        XCTAssertTrue(provider.exists, app.debugDescription)
        provider.click()
        capture("certificate-options", app)
        app.typeKey(.escape, modifierFlags: [])
        app.radioButtons["HTTP"].click()
        select("Clients", app)
        XCTAssertTrue(app.buttons["Add superuser"].waitForExistence(timeout: 10), app.debugDescription)
        capture("clients", app)
        app.buttons["Add superuser"].click()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        capture("add-user", app)
        app.buttons["Cancel"].click()
        select("Shell", app)
        let terminal = app.descendants(matching: .any)["Container terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), app.debugDescription)
        terminal.click(); app.typeText("archivebox help\n")
        // The terminal exposes its actual output through accessibility.
        let help = app.descendants(matching: .any).matching(NSPredicate(format: "CAST(value, 'NSString') CONTAINS %@", "archivebox add")).firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 30), app.debugDescription)
        capture("shell", app)
        select("Admin", app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let home = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "CAST(value, 'NSString') CONTAINS %@", "Snapshots")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 30), app.debugDescription)
        capture("admin", app)
        select("Activity", app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        capture("activity", app)
        select("Settings", app)
        let collection = app.buttons["Choose a path…"]
        reveal(collection, app)
        capture("collection", app)
        collection.click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        capture("choose-collection", app)
        app.dialogs.buttons["Cancel"].click()
        app.terminate()
    }

    private func select(_ name: String, _ app: XCUIApplication) {
        let tab = app.segmentedControls.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        tab.click()
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<10 {
            if element.isHittable { break }
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
