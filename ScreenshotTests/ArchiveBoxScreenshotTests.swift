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
}
