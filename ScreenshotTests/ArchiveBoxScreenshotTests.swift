import XCTest

/// Captures the shipping app through the real system UI test runner.
@MainActor
final class ArchiveBoxScreenshotTests: XCTestCase {
    func testLaunchScreenshot() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 20), app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "connection-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
