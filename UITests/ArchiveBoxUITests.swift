import XCTest

// Run on a fresh, disposable simulator. All preferences are changed through UI.
@MainActor
final class FirstRunUITests: XCTestCase {
    func testIntroductionChoicesAndPersistentSkip() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Keep the web that matters to you."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["serverURL"].exists)
        capture("Welcome", app: app)
        app.buttons["setup.choose"].tap()
        XCTAssertTrue(app.staticTexts["Choose a home for your archive"].waitForExistence(timeout: 5))
        capture("Server choices", app: app)
        for route in ["mac", "hosting", "docker", "python"] {
            let choice = app.buttons["setup.\(route)"]
            let content = app.scrollViews["setup.content"]
            // At accessibility sizes a card can be taller than the viewport.
            // Bring its tap point into view, clear of the navigation and footer.
            for _ in 0..<5 {
                let center = CGPoint(x: choice.frame.midX, y: choice.frame.midY)
                if content.frame.contains(center) && center.y > app.navigationBars.firstMatch.frame.maxY { break }
                if center.y > content.frame.maxY { content.swipeUp() }
                else { content.swipeDown() }
            }
            XCTAssertTrue(choice.isHittable, app.debugDescription)
            choice.tap()
            XCTAssertTrue(app.buttons["setup.connect"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.textFields["serverURL"].exists)
            capture("Setup \(route)", app: app)
            app.buttons["setup.back"].tap()
        }
        app.buttons["setup.skip"].tap()
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Keep the web that matters to you."].exists)
        let guide = app.buttons["setup.reopen"]
        for _ in 0..<5 where !guide.isHittable { app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.staticTexts["Keep the web that matters to you."].waitForExistence(timeout: 5))
        app.buttons["setup.skip"].tap()
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}

/// Run against a real, disposable ArchiveBox 0.9+ server. No intercepted requests or seeded app state.
@MainActor
final class ArchiveBoxUITests: XCTestCase {
    func testNativeArchiveSearchAndDeepLinks() async throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Password suggestion") { alert in
            if alert.buttons["Not Now"].exists { alert.buttons["Not Now"].tap(); return true }
            return false
        }
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_TOKEN"])
        var request = URLRequest(url: URL(string: server + "/api/v1/core/snapshots?limit=1")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try XCTUnwrap((json["items"] as? [[String: Any]])?.first)
        let id = try XCTUnwrap(record["id"] as? String)
        let original = try XCTUnwrap(record["url"] as? String)

        let app = XCUIApplication()
        app.launch()
        skipIntroductionIfNeeded(app)
        // Use the same public connection link that the companion's QR code
        // opens. Credentials still go through the app's real validation flow.
        var connection = URLComponents(string: "archivebox://connect")!
        connection.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "api_key", value: token)]
        app.open(connection.url!)
        if app.buttons["Use this server"].waitForExistence(timeout: 3) { app.buttons["Use this server"].tap() }
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20))
        openScreen("Search Archive", app: app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.tap()
        let passwordSuggestion = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Not Now"]
        if passwordSuggestion.waitForExistence(timeout: 3) { passwordSuggestion.tap() }
        search.tap()
        search.typeText(original + "\n")
        let result = app.buttons["archive.result." + id]
        XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(result.label.contains(original))
        attach("Native archive search", app: app)
        result.tap()
        XCTAssertTrue(app.buttons["Share Archive URL"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", original)).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Share Archive URL"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 5), app.debugDescription)
        attach("Native archive sharing", app: app)
        app.cells["Copy"].tap()
        app.buttons["Done"].tap()

        let missingQuery = "archivebox-no-match-" + UUID().uuidString
        app.open(URL(string: "archivebox://search?q=" + missingQuery)!)
        XCTAssertTrue(app.staticTexts["No Results for “\(missingQuery)”"].waitForExistence(timeout: 20), app.debugDescription)
        var link = URLComponents(string: "archivebox://snapshot")!
        link.queryItems = [URLQueryItem(name: "server", value: "https://different.example"), URLQueryItem(name: "id", value: id)]
        app.open(link.url!)
        XCTAssertTrue(app.alerts["Couldn’t open archived page"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        link.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "id", value: id)]
        app.terminate()
        app.open(link.url!)
        XCTAssertTrue(app.buttons["Share Archive URL"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", original)).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        attach("Cold launch archived page", app: app)
    }

    func testShareTagsUsingSavedConnection() throws {
        continueAfterFailure = false
        XCUIApplication().launch()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.launch()
        let address = safari.textFields["Address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), safari.debugDescription)
        address.tap()
        address.typeText("https://example.com/?archivebox-share-tags=\(UUID().uuidString)\n")
        let share = safari.buttons["Share"]
        if !share.exists { safari.buttons["Page Menu"].tap() }
        XCTAssertTrue(share.waitForExistence(timeout: 15), safari.debugDescription)
        share.tap()
        let more = safari.cells["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), safari.debugDescription)
        more.tap()
        let archiveBox = safari.tables.staticTexts["ArchiveBox"]
        XCTAssertTrue(archiveBox.waitForExistence(timeout: 5), safari.debugDescription)
        archiveBox.tap()
        let tags = safari.textFields["shareTagInput"]
        XCTAssertTrue(tags.waitForExistence(timeout: 15), safari.debugDescription)
        XCTAssertFalse(safari.buttons["submitShare"].exists)
        XCTAssertTrue(safari.staticTexts["Submitted to ArchiveBox Server"].waitForExistence(timeout: 30), safari.debugDescription)
        XCTAssertTrue(safari.buttons["Add suggested tag example"].isHittable)
        XCTAssertTrue(safari.buttons["Add suggested tag ⭐️"].isHittable)
        XCTAssertFalse(safari.staticTexts["Save to"].exists)
        XCTAssertFalse(safari.staticTexts["Your server accepted the link for archiving."].exists)
        XCTAssertTrue(safari.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Persona: ")).firstMatch.exists)
        attach("Compact share sheet", app: safari)
        safari.buttons["Add suggested tag ⭐️"].tap()
        XCTAssertTrue(safari.buttons["Remove tag ⭐️"].exists)
        tags.tap()
        tags.typeText("share-sheet-test, second-share-tag\n")
        XCTAssertTrue(safari.staticTexts["Tags saved"].waitForExistence(timeout: 15), safari.debugDescription)
        let selectedTag = safari.buttons["Remove tag share-sheet-test"]
        XCTAssertTrue(selectedTag.isHittable, safari.debugDescription)
        selectedTag.tap()
        XCTAssertFalse(selectedTag.exists, safari.debugDescription)
        safari.buttons["Remove tag second-share-tag"].tap()
        let recent = safari.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add suggested tag "))
        XCTAssertEqual(Array(recent.allElementsBoundByIndex.prefix(3)).map(\.label),
                       ["Add suggested tag second-share-tag", "Add suggested tag share-sheet-test", "Add suggested tag example"])
        tags.tap()
        tags.typeText("share-sheet")
        let suggestion = safari.buttons["Add suggested tag share-sheet-test"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15), safari.debugDescription)
        if !suggestion.isHittable { safari.swipeUp() }
        XCTAssertTrue(suggestion.isHittable, safari.debugDescription)
        attach("Share tag suggestions", app: safari)
        suggestion.tap()
        XCTAssertTrue(safari.staticTexts["Tags saved"].waitForExistence(timeout: 15), safari.debugDescription)
        safari.buttons["Remove from server"].tap()
        XCTAssertTrue(safari.buttons["Keep it"].waitForExistence(timeout: 5), safari.debugDescription)
        attach("Share removal confirmation", app: safari)
        safari.buttons["Keep it"].tap()
        attach("Share tags saved", app: safari)
        safari.buttons["Remove from server"].tap()
        safari.sheets.buttons["Remove from server"].tap()
        XCTAssertTrue(safari.staticTexts["Removed from server"].waitForExistence(timeout: 15), safari.debugDescription)
        attach("Share removed", app: safari)
        safari.buttons["Done"].tap()
    }

    func testSafariButtonOpensExtensionSettings() throws {
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        let app = XCUIApplication()
        app.launch()
        skipIntroductionIfNeeded(app)
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

    func testEnableSafariExtensionThroughSettings() throws {
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        let app = XCUIApplication()
        app.launch()
        skipIntroductionIfNeeded(app)
        openScreen("Add URLs", app: app)
        let safari = app.buttons["Safari"]
        for _ in 0..<8 where !safari.isHittable { app.swipeUp() }
        XCTAssertTrue(safari.isHittable, app.debugDescription)
        safari.tap()
        let instructions = app.alerts["Enable ArchiveBox in Safari"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5), app.debugDescription)
        instructions.buttons["OK"].tap()
        if !settings.navigationBars["ArchiveBox"].waitForExistence(timeout: 5) {
            let apps = settings.buttons["Apps"]
            for _ in 0..<12 where !apps.isHittable { settings.swipeUp() }
            XCTAssertTrue(apps.isHittable, settings.debugDescription)
            apps.tap()
            let safariSettings = settings.buttons["Safari"]
            for _ in 0..<30 where !safariSettings.isHittable { settings.swipeUp() }
            XCTAssertTrue(safariSettings.isHittable, settings.debugDescription)
            safariSettings.tap()
            let extensions = settings.cells["WEB_EXTENSIONS"]
            for _ in 0..<20 where !extensions.isHittable {
                if extensions.frame.minY < 116 { settings.swipeDown(velocity: .slow) }
                else { settings.swipeUp(velocity: .slow) }
            }
            XCTAssertTrue(extensions.isHittable, settings.debugDescription)
            extensions.tap()
            let archiveBox = settings.cells["io.archivebox.ArchiveBox.Safari"]
            XCTAssertTrue(archiveBox.waitForExistence(timeout: 5), settings.debugDescription)
            archiveBox.tap()
        }
        XCTAssertTrue(settings.navigationBars["ArchiveBox"].waitForExistence(timeout: 5), settings.debugDescription)
        let enabled = settings.switches.firstMatch
        XCTAssertTrue(enabled.exists, settings.debugDescription)
        if (enabled.value as? String) != "1" { enabled.tap() }
        XCTAssertEqual(enabled.value as? String, "1", settings.debugDescription)
    }

    // Run after enabling Safari's extension and screenshot uploads in its Configuration UI.
    func testSafariCaptureWithScreenshotUpload() throws {
        continueAfterFailure = false
        XCUIApplication().launch()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let captureURL = "https://example.com/?archivebox-safari-upload=\(UUID().uuidString)"
        print("SAFARI_CAPTURE_URL=\(captureURL)")
        let address = safari.textFields["Address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(captureURL + "\n")
        let pageMenu = safari.buttons["Page Menu"]
        XCTAssertTrue(pageMenu.waitForExistence(timeout: 10))
        pageMenu.tap()
        let extensionButton = safari.buttons.containing(NSPredicate(format: "label CONTAINS %@", "ArchiveBox")).firstMatch
        XCTAssertTrue(extensionButton.waitForExistence(timeout: 10))
        extensionButton.tap()
        let submitted = safari.staticTexts["Submitted to ArchiveBox Server at depth 0"]
        XCTAssertTrue(submitted.waitForExistence(timeout: 30))
        safari.buttons["Screenshot"].tap()
        let uploaded = safari.staticTexts["Saved local screenshot and uploaded to ArchiveBox Server"]
        XCTAssertTrue(uploaded.waitForExistence(timeout: 30), safari.debugDescription)
        let screenshotSaved = safari.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "✓ Screenshot")).firstMatch
        XCTAssertTrue(screenshotSaved.exists)
        attach("Safari screenshot submitted", app: safari)
    }

    func testVerifiedKeyPersistsWithoutSave() throws {
        continueAfterFailure = false
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_SERVER"])
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["ARCHIVEBOX_TEST_TOKEN"])
        let app = XCUIApplication()
        app.launch()
        skipIntroductionIfNeeded(app)
        let field = app.textFields["serverURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replace(field, with: server)
        XCTAssertTrue(app.staticTexts["Server connected"].waitForExistence(timeout: 20))
        replace(app.secureTextFields["apiKey"], with: token)
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        // Never tap Save: verification itself must durably store the key.
        app.terminate()
        app.launch()
        skipIntroductionIfNeeded(app)
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
        skipIntroductionIfNeeded(app)
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
        XCTAssertTrue(app.buttons["navigation.sidebar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Admin"].exists)
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
        skipIntroductionIfNeeded(app)
        let serverField = app.textFields["serverURL"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        replace(serverField, with: server + "/admin/api/apitoken/")
        let key = app.secureTextFields["apiKey"]
        replace(key, with: "invalid-test-key")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "invalid or expired")).firstMatch.waitForExistence(timeout: 20))
        replace(key, with: token)
        XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["saveConnection"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ready to share.")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        openScreen("Add URLs", app: app)
        let picker = app.buttons["defaultPersona"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        // Start below the embedded form so the gesture scrolls the native
        // share settings rather than the web page's independent viewport.
        let content = app.scrollViews["add.content"]
        for _ in 0..<10 where !picker.isHittable {
            content.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.93)).press(forDuration: 0.05,
                thenDragTo: content.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        }
        XCTAssertTrue(picker.isHittable, app.debugDescription)
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
        skipIntroductionIfNeeded(app)
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
        XCTAssertTrue(safari.staticTexts["Submitted to ArchiveBox Server"].waitForExistence(timeout: 30), safari.debugDescription)
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
        skipIntroductionIfNeeded(app)
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
        skipIntroductionIfNeeded(app)
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
            skipIntroductionIfNeeded(app)
            openScreen("Connection Settings", app: app)
            XCTAssertTrue(app.staticTexts["API key verified."].waitForExistence(timeout: 25), app.debugDescription)
            openScreen("Snapshots", app: app)
            XCTAssertTrue(app.buttons["navigation.sidebar"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.navigationBars["Snapshots"].exists)
            XCTAssertTrue(app.webViews.textFields.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
            // The compact header intentionally hides Logout. Verify a protected
            // administrator capability instead of depending on hidden chrome.
            openScreen("Users", app: app)
            XCTAssertTrue(app.webViews.links.matching(NSPredicate(format: "label ==[c] 'Add user'")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertFalse(app.webViews.secureTextFields.firstMatch.exists)
            XCTAssertTrue(app.webViews.firstMatch.frame.contains(app.buttons["navigation.sidebar"].frame))
            openScreen("AI Agent", app: app)
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'New session'")).firstMatch.waitForExistence(timeout: 45), app.debugDescription)
            attach("Authenticated AI Agent", app: app)
            app.terminate()
        }
    }

    func testAddPageLoadingAndHelpFillViewport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["sidebar.snapshots"])
        waitForExpectations(timeout: 25)
        app.buttons["sidebar.add"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews["add.content"].frame.maxY, app.frame.maxY, accuracy: 1)
        if app.staticTexts["Loading Add URLs…"].exists {
            attach("Add URLs loading", app: app)
            XCTAssertTrue(app.buttons["navigation.sidebar"].isHittable)
        }
        XCTAssertTrue(app.webViews.links["Home"].firstMatch.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Loading Add URLs…"])
        waitForExpectations(timeout: 30)
        XCTAssertEqual(app.scrollViews["add.content"].frame.maxY, app.frame.maxY, accuracy: 1)
        XCTAssertGreaterThan(app.staticTexts["More ways to add"].frame.minY, app.webViews.firstMatch.frame.maxY)
        XCTAssertTrue(app.staticTexts["More ways to add"].isHittable)
        attach("Add URLs form and inline help fill viewport", app: app)
        app.staticTexts["More ways to add"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 1)
        attach("Add URLs help on neutral background", app: app)
        let guide = app.images["iPhone share sheet with ArchiveBox available in the Apps list"]
        XCTAssertTrue(guide.exists)
        XCTAssertGreaterThan(guide.frame.height, 0)
        XCTAssertTrue(app.frame.contains(guide.frame), app.debugDescription)
    }

    func testWebviewsFillBottomSafeArea() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["sidebar.snapshots"])
        waitForExpectations(timeout: 25)
        for (screen, identifier) in [("Snapshots", "snapshots"), ("AI Agent", "agent")] {
            app.buttons["sidebar.\(identifier)"].tap()
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
            if identifier == "snapshots" {
                XCTAssertTrue(app.webViews.textFields.firstMatch.waitForExistence(timeout: 30))
            } else {
                XCTAssertTrue(app.webViews.links["Home"].firstMatch.waitForExistence(timeout: 30))
            }
            XCTAssertEqual(app.webViews.firstMatch.frame.maxY, app.frame.maxY, accuracy: 1)
            XCTAssertFalse(app.staticTexts["navigation.activity.title"].exists)
            XCTAssertTrue(app.webViews.firstMatch.frame.contains(app.buttons["navigation.sidebar"].frame))
            attach("\(screen) fills bottom safe area", app: app)
            app.buttons["navigation.sidebar"].tap()
        }
    }

    func testActivityHeaderSeparatesBackButtonFromWebContent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["sidebar.snapshots"])
        waitForExpectations(timeout: 25)
        app.buttons["sidebar.openActivity"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'CRAWLS'")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["navigation.activity.title"].waitForExistence(timeout: 5))
        let back = app.buttons["navigation.sidebar"]
        XCTAssertTrue(back.isHittable)
        XCTAssertLessThanOrEqual(back.frame.maxY, app.webViews.firstMatch.frame.minY)
        XCTAssertEqual(app.webViews.firstMatch.frame.maxY, app.frame.maxY, accuracy: 1)
        attach("Activity with native header and full height webview", app: app)
        back.tap()
        XCTAssertTrue(app.buttons["sidebar.snapshots"].isHittable)
    }

    func testWebPageBackButtonOverlaysHeader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        skipIntroductionIfNeeded(app)
        for screen in ["Snapshots", "Users"] {
            openScreen(screen, app: app)
            let back = app.buttons["navigation.sidebar"]
            XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.webViews.textFields.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(app.navigationBars[screen].exists)
            XCTAssertTrue(app.webViews.firstMatch.frame.contains(back.frame))
            attach("\(screen) with back over web header", app: app)
            let page = app.webViews.firstMatch
            // Drag from the page margin so a link/form control cannot start a drag session.
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25))
                .press(forDuration: 0.1,
                       thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.7)),
                       withVelocity: .slow, thenHoldForDuration: 2)
            attach("\(screen) after pulling down at top", app: app)
            if screen == "Snapshots" {
                page.swipeUp()
                XCTAssertTrue(back.isHittable)
                attach("Back over scrolled white content", app: app)
            }
            back.tap()
            XCTAssertTrue(app.buttons["sidebar.snapshots"].isHittable)
        }
        openScreen("Connection Settings", app: app)
        XCTAssertTrue(app.navigationBars["Connection Settings"].exists)
        XCTAssertFalse(app.buttons["navigation.sidebar"].exists)
    }

    private func skipIntroductionIfNeeded(_ app: XCUIApplication) {
        let skip = app.buttons["setup.skip"]
        if skip.waitForExistence(timeout: 2) { skip.tap() }
    }

    private func openScreen(_ name: String, app: XCUIApplication) {
        let identifiers = ["Search Archive": "search", "Add URLs": "add", "AI Agent": "agent", "Snapshots": "snapshots", "Admin": "admin", "Users": "users", "Connection Settings": "settings"]
        let item = app.buttons["sidebar." + identifiers[name]!]
        let sidebar = app.collectionViews.firstMatch
        if !sidebar.isHittable {
            let back = app.buttons["navigation.sidebar"].exists ? app.buttons["navigation.sidebar"] : app.navigationBars.buttons.firstMatch
            if back.isHittable { back.tap() }
        }
        // The connected app starts on its menu; returning from a detail keeps
        // the sidebar's scroll position. Search from the top in either case.
        XCTAssertTrue(sidebar.isHittable, app.debugDescription)
        for _ in 0..<5 where !item.isHittable { sidebar.swipeDown() }
        for _ in 0..<8 where !item.isHittable { sidebar.swipeUp() }
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

/// Run on a fresh simulator while the real companion advertises its Tailscale origin.
@MainActor
final class NetworkSetupUITests: XCTestCase {
    // Requires a real ArchiveBox Server.app advertising on this Mac's network.
    func testAutomaticDiscoveryAboveServerURL() {
        continueAfterFailure = false
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Local network access") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }
        app.launch()
        if app.buttons["setup.skip"].waitForExistence(timeout: 5) { app.buttons["setup.skip"].tap() }
        let nearby = app.staticTexts["discovery.inline.heading"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 5), app.debugDescription)
        app.tap() // Handle the real system Local Network permission prompt.
        let bonjour = app.buttons.matching(identifier: "discovery.inline.result")
            .matching(NSPredicate(format: "label CONTAINS 'Bonjour'")).firstMatch
        XCTAssertTrue(bonjour.waitForExistence(timeout: 25), app.debugDescription)
        let url = app.textFields["serverURL"]
        XCTAssertLessThan(bonjour.frame.minY, url.frame.minY)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Automatic discovery in Connection Settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        bonjour.tap()
        XCTAssertTrue(app.staticTexts["Connected to ArchiveBox."].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse((url.value as? String ?? "").isEmpty)
        let getKey = app.buttons["getAPIKey"]
        for _ in 0..<6 where !getKey.isHittable { app.swipeUp() }
        getKey.tap()
        XCTAssertTrue(app.webViews.textFields.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.webViews.secureTextFields.firstMatch.exists, app.debugDescription)
        let login = XCTAttachment(screenshot: app.screenshot())
        login.name = "Get Key opens the real server login"
        login.lifetime = .keepAlways
        add(login)
    }

    func testDiscoverPrivateServerAndReadAdvancedGuide() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        addUIInterruptionMonitor(withDescription: "Local network access") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        let find = app.buttons["setup.discover"].exists ? app.buttons["setup.discover"] : app.buttons["network.discover"]
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        find.tap()
        let server = app.buttons.matching(identifier: "discovery.result").matching(NSPredicate(format: "label CONTAINS 'http://100.'")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 35), app.debugDescription)
        capture("Discovered private ArchiveBox server", app)
        server.tap()
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Connected to ArchiveBox."].waitForExistence(timeout: 15), app.debugDescription)
        let key = app.secureTextFields["apiKey"]
        for _ in 0..<5 where !key.isHittable { app.swipeUp() }
        XCTAssertEqual(key.value as? String, "Paste your API key")
        let guide = app.buttons["network.guide"]
        for _ in 0..<5 where !guide.isHittable { app.swipeDown() }
        guide.tap()
        XCTAssertTrue(app.staticTexts["Your archive, within reach"].waitForExistence(timeout: 5))
        capture("Tailscale client guide", app)
        let setup = app.buttons["network.serverSteps"]
        for _ in 0..<6 where !setup.isHittable { app.swipeUp() }
        setup.tap()
        let worldwide = app.buttons["network.audience.internet"]
        for _ in 0..<8 where !worldwide.isHittable { app.swipeUp() }
        worldwide.tap()
        let full = app.switches["network.fullReplay"]
        for _ in 0..<4 where !full.isHittable { app.swipeUp() }
        XCTAssertTrue(full.exists)
        capture("Public access options", app)
        full.tap()
        let domain = app.textFields["network.wildcardDomain"]
        for _ in 0..<8 where !domain.isHittable { app.swipeUp() }
        XCTAssertTrue(domain.isHittable, app.debugDescription)
        capture("Wildcard DNS guide", app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 5))
        let address = app.textFields["serverURL"].value as! String
        var link = URLComponents()
        link.scheme = "archivebox"; link.host = "connect"
        link.queryItems = [URLQueryItem(name: "server", value: address)]
        app.terminate()
        app.open(link.url!)
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["serverURL"].value as? String, address)
        XCTAssertTrue(app.staticTexts["Connected to ArchiveBox."].waitForExistence(timeout: 15))
        capture("Cold launch from connection QR link", app)
    }
    private func capture(_ title: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
