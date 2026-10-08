import XCTest

/// Thin Device Farm / remote-Mac wrapper. The app owns scripts, repeats, page
/// commits and result uploads, so standalone and XCTest runs use the same path.
final class BenchmarkUITests: XCTestCase {
    func testBenchmarkGrid() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment = env.filter { $0.key.hasPrefix("HM_") }
        let typed = env["HM_GRID_INPUT"] == "typed"
        if typed { app.launchEnvironment["HM_GRID_URL"] = nil }
        app.launch()
        if env["HM_GRID_URL"] == nil || typed {
            // Device Farm's standard runner can supply an extra grid-url.txt
            // resource without relying on its generated xctestrun environment.
            let bundled = Bundle(for: Self.self).url(forResource: "grid-url", withExtension: "txt")
            let url: String
            if typed, let supplied = env["HM_GRID_URL"] { url = supplied }
            else if let bundled { url = try String(contentsOf: bundled).trimmingCharacters(in: .whitespacesAndNewlines) }
            else { throw XCTSkip("Set HM_GRID_URL or package grid-url.txt with the XCTest runner") }
            app.buttons["benchmark-mode"].tap()
            let field = app.textFields["benchmark-grid-url"]
            XCTAssertTrue(field.waitForExistence(timeout: 10)); app.buttons["benchmark-grid-clear"].tap(); field.tap(); field.typeText(url)
            app.buttons["benchmark-grid-start"].tap()
        }
        XCTAssertTrue(app.staticTexts["benchmark-grid-progress"].waitForExistence(timeout: 30))
        if let seconds = Double(env["HM_BACKGROUND_SECONDS"] ?? ""), seconds > 0 {
            Thread.sleep(forTimeInterval: 3)
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: seconds)
            app.activate()
        }
        let timeout = Double(env["HM_GRID_TIMEOUT"] ?? "7200") ?? 7200
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts["benchmark-grid-error"].exists { XCTFail(app.staticTexts["benchmark-grid-error"].label); return }
            if app.staticTexts["benchmark-grid-complete"].exists {
                if env["HM_REQUIRE_UPLOAD"] == "1" { XCTAssertTrue(app.staticTexts["benchmark-grid-complete"].label.contains("upload failures: 0")) }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "grid-complete"; attachment.lifetime = .keepAlways; add(attachment)
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTFail("Grid timeout: \(app.staticTexts["benchmark-grid-progress"].label)")
    }
}
